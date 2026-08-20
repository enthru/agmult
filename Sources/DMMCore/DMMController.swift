import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// The application's single source of truth: connection state, the meter's
/// configuration, the reading history and everything derived from it.
///
/// All mutation happens on the main actor. Serial traffic lives in `DMMWorker`,
/// which hands finished snapshots back here.
@MainActor
@Observable
public final class DMMController {

    // MARK: Connection

    public private(set) var isConnected = false
    public private(set) var identity: DeviceIdentity?
    public private(set) var config = SerialConfig()
    public private(set) var connectionError: String?

    public var deviceTitle: String {
        identity.map { "\($0.model) Multimeter" } ?? "Multimeter"
    }

    public var portDisplayName: String {
        (config.path as NSString).lastPathComponent
    }

    /// Mains frequency where the meter is standing. Only used to predict how
    /// long a burst will take — the meter measures its own line frequency.
    public var lineFrequency: Double = 50 {
        didSet { worker?.update(lineFrequency: lineFrequency) }
    }

    // MARK: Meter configuration

    public private(set) var configuration = MeterConfiguration()
    public private(set) var math = MathConfiguration()

    public var pollPlan = DMMPollPlan() {
        didSet { worker?.update(plan: pollPlan) }
    }

    /// Seconds to wait between passes. Zero means "as fast as the meter will go",
    /// which is the interesting setting: the burst itself sets the pace.
    public var updateInterval: TimeInterval = 0 {
        didSet { worker?.update(interval: updateInterval) }
    }

    /// Fold several queries into one message, so a polling pass costs one round
    /// trip instead of six. On by default; the loop falls back on its own if a
    /// meter turns out not to understand them.
    public var usesCompoundQueries = true {
        didSet { worker?.update(usesCompoundQueries: usesCompoundQueries) }
    }

    /// The unit readings are currently in — which the maths can change.
    public var displayUnit: String {
        math.function.unit(for: configuration.function)
    }

    public var displayDigits: Int { configuration.digits }

    /// The range readings are scaled against, or nil for dB and dBm where no
    /// range applies.
    public var displayRange: Double? {
        guard math.function != .decibel, math.function != .dBm else { return nil }
        return configuration.effectiveRange
    }

    // MARK: Live readings

    public private(set) var latestReading: Double?
    public private(set) var latestReadingTime: Date?
    public private(set) var isOverloaded = false
    public private(set) var questionable = QuestionableStatus(condition: 0)
    public private(set) var questionableIsKnown = false
    public private(set) var instrumentStatistics = InstrumentStatistics()
    public private(set) var errorText = "—"
    public var message = ""

    public var readingIsValid: Bool { latestReading != nil && !isOverloaded }

    /// The big number, formatted the way the meter's own display would.
    public var formattedReading: String {
        if isOverloaded { return "OVLD" }
        guard let value = latestReading else { return "— — —" }
        return Format.reading(value, unit: displayUnit, range: displayRange, digits: displayDigits)
    }

    public func formatted(_ value: Double) -> String {
        Format.reading(value, unit: displayUnit, range: displayRange, digits: displayDigits)
    }

    // MARK: Counters

    public private(set) var readingCount = 0
    public private(set) var overloadCount = 0
    public private(set) var runtime: TimeInterval = 0
    /// Readings per second, smoothed — the number that tells you whether the
    /// integration time and sample count you picked are actually paying off.
    public private(set) var measuredRate: Double = 0

    public var statistics: Statistics { history.statistics }

    // MARK: History

    public var history = SampleBuffer()

    /// How much history to keep. Kept here rather than read straight off the
    /// buffer so that observers of this setting are not woken by every reading
    /// that lands in it.
    public var historyCapacity: Int = 100_000 {
        didSet { history.capacity = historyCapacity }
    }

    /// The most recent readings, for the table. Bounded separately from the
    /// graph history, which can hold millions.
    public private(set) var tableReadings: [Reading] = []
    public var tableCapacity = 2000 {
        didSet { trimTable() }
    }

    // MARK: Event list

    public private(set) var entries: [LogEntry] = []
    public var autoScroll = true
    public var updateList = true
    public var addReadingsToList = false
    private var entryCounter = 0
    private static let maximumEntries = 5000

    // MARK: Data logging

    public var logReadingsText = false
    public var logReadingsCSV = false
    public var logStatusText = false
    public private(set) var logDirectory = DataLogger.defaultDirectory
    public private(set) var loggedLineCount = 0

    // MARK: Alerts

    public var beeperEnabled = true
    public let speech = SpeechAnnouncer()

    // MARK: Private

    private var worker: DMMWorker?
    private var logger: DataLogger?
    private var runtimeTimer: Timer?
    private var lastRateSample: Date?

    public init() {}

    // MARK: - Connection lifecycle

    public func connect(config: SerialConfig, identity: DeviceIdentity) {
        disconnect()

        let device = DMMDevice(config: config)
        do {
            try device.open()
        } catch {
            connectionError = error.localizedDescription
            append("Connect failed: \(error.localizedDescription)")
            return
        }

        self.config = config
        self.identity = identity
        self.connectionError = nil
        self.isConnected = true
        self.runtime = 0
        self.lastRateSample = nil
        self.measuredRate = 0

        logger = DataLogger(configuration: .init(
            directory: logDirectory,
            model: identity.model,
            portName: config.path
        ))

        let worker = DMMWorker(device: device) { snapshot in
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        worker.update(plan: pollPlan)
        worker.update(configuration: configuration)
        worker.update(interval: updateInterval)
        worker.update(lineFrequency: lineFrequency)
        worker.update(usesCompoundQueries: usesCompoundQueries)
        self.worker = worker

        // Put the meter into a known state that matches the panel before the
        // first reading is taken, so nothing is measured under the previous
        // user's settings.
        worker.enqueue(.commands([SCPI.remote, SCPI.clearStatus] + configuration.commands() + math.commands(),
                                 log: nil))
        worker.invalidateConfiguration()
        worker.start()

        startRuntimeTimer()
        append("Connected to \(identity.model) on \(portDisplayName)")
    }

    public func disconnect() {
        runtimeTimer?.invalidate()
        runtimeTimer = nil

        if let worker {
            worker.stop()
            self.worker = nil
            append("Disconnected")
        }
        logger?.closeAll()
        logger = nil
        speech.stop()
        isConnected = false
    }

    private func startRuntimeTimer() {
        runtimeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                self.runtime += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        runtimeTimer = timer
    }

    // MARK: - Snapshot handling

    private func apply(_ snapshot: DMMSnapshot) {
        // A pass already under way when the user disconnected can still deliver.
        guard isConnected else { return }

        for line in snapshot.logs {
            append(line)
        }

        if let failure = snapshot.failure {
            connectionError = failure
            append("Connection lost: \(failure)")
            disconnect()
            return
        }

        if let configuration = snapshot.configuration {
            adopt(configuration)
        }

        if let offset = snapshot.capturedNullOffset {
            math.nullOffset = offset
            append("Null offset: \(Format.engineering(offset, unit: configuration.function.unit))")
        }

        if let error = snapshot.errorText {
            errorText = error
        }

        if let result = snapshot.selfTestResult {
            message = result
        }

        applyReadings(snapshot)
        applyStatus(snapshot)

        if let statistics = snapshot.instrumentStatistics {
            instrumentStatistics = statistics
        }
    }

    private func applyReadings(_ snapshot: DMMSnapshot) {
        overloadCount += snapshot.overloadCount

        guard !snapshot.readings.isEmpty else {
            // Nothing but overloads this pass still tells the panel something.
            if snapshot.overloadCount > 0 {
                isOverloaded = true
                history.recordOverload()
                appendReadingLine(nil, at: snapshot.timestamp)
            }
            updateRate(readings: 0, at: snapshot.timestamp)
            return
        }

        isOverloaded = false

        for (offset, value) in snapshot.readings.enumerated() {
            let moment = offset < snapshot.readingTimes.count ? snapshot.readingTimes[offset] : snapshot.timestamp
            history.append(value: value, at: moment)
            tableReadings.append(Reading(index: history.totalRecorded - 1, timestamp: moment, value: value))
            readingCount += 1
            appendReadingLine(value, at: moment)
        }
        trimTable()

        latestReading = snapshot.readings.last
        latestReadingTime = snapshot.readingTimes.last ?? snapshot.timestamp

        if addReadingsToList, let value = latestReading {
            append(formatted(value))
        }

        if let value = latestReading {
            speech.consider(value: value, unit: displayUnit, at: latestReadingTime ?? Date())
        }

        updateRate(readings: snapshot.readings.count, at: snapshot.timestamp)
    }

    private func applyStatus(_ snapshot: DMMSnapshot) {
        guard let condition = snapshot.questionableCondition else {
            questionableIsKnown = false
            return
        }
        let status = QuestionableStatus(condition: condition)
        let wasClear = questionable.isClear || !questionableIsKnown
        questionable = status
        questionableIsKnown = true

        // Log a trip once per event rather than on every polling pass.
        if !status.isClear && wasClear {
            for label in status.labels {
                append(label)
            }
            if status.limitFailed { beep() }
        }
    }

    /// A configuration read back from the meter wins over what this app last
    /// sent: somebody may have pressed a button on the front panel, and the
    /// panel should show what is really happening.
    ///
    /// Only the settings the meter actually reports are taken from it. Sample
    /// count, trigger source and delay, auto zero and input impedance are not
    /// read back — they are write-only as far as this loop is concerned — so
    /// accepting the whole structure would silently roll a change the user just
    /// made back to whatever the pass had started with.
    private func adopt(_ readBack: MeterConfiguration) {
        let functionChanged = readBack.function != configuration.function

        // Assigning unconditionally would fire the observation machinery on
        // every read-back pass, redrawing every view that shows a setting
        // several times a second to say nothing has changed.
        if configuration.function != readBack.function { configuration.function = readBack.function }
        if configuration.autoRange != readBack.autoRange { configuration.autoRange = readBack.autoRange }
        if configuration.range != readBack.range { configuration.range = readBack.range }
        if configuration.integrationTime != readBack.integrationTime { configuration.integrationTime = readBack.integrationTime }
        if configuration.gateTime != readBack.gateTime { configuration.gateTime = readBack.gateTime }
        if configuration.bandwidth != readBack.bandwidth { configuration.bandwidth = readBack.bandwidth }

        worker?.update(configuration: configuration)

        if functionChanged {
            append("Function changed on the meter: \(readBack.function.title)")
            resetHistory()
        }
    }

    private func updateRate(readings: Int, at moment: Date) {
        defer { lastRateSample = moment }
        guard let last = lastRateSample else { return }
        let elapsed = moment.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        let instantaneous = Double(readings) / elapsed
        // A light exponential smoothing: enough to stop the number flickering,
        // little enough that a change of settings shows up straight away.
        measuredRate = measuredRate == 0 ? instantaneous : measuredRate * 0.7 + instantaneous * 0.3
    }

    private func trimTable() {
        let overflow = tableReadings.count - tableCapacity
        if overflow > 0 {
            tableReadings.removeFirst(overflow)
        }
    }

    /// Adopts a configuration wholesale — used when settings are restored at
    /// launch, before there is a meter to send them to. Connecting sends them
    /// down; nothing is transmitted from here.
    public func restore(configuration: MeterConfiguration, math: MathConfiguration) {
        self.configuration = configuration
        self.math = math
        worker?.update(configuration: configuration)
    }

    // MARK: - Configuration commands

    private func enqueue(_ commands: [String], log: String?) {
        if let log { append(log) }
        guard let worker else { return }
        worker.enqueue(.commands(commands, log: nil))
    }

    private func requireConnection() -> DMMWorker? {
        guard let worker else {
            message = "Not connected."
            return nil
        }
        message = ""
        return worker
    }

    public func setFunction(_ function: MeasurementFunction) {
        guard function != configuration.function else { return }
        configuration.function = function
        configuration.autoRange = true
        configuration.range = function.ranges.first ?? 1
        worker?.update(configuration: configuration)
        resetHistory()
        // CONFigure resets that function's own trigger and resolution defaults,
        // so everything the panel holds is sent again behind it.
        enqueue(configuration.commands() + math.commands(), log: "Function: \(function.title)")
        worker?.invalidateConfiguration()
    }

    public func setAutoRange(_ enabled: Bool) {
        configuration.autoRange = enabled
        worker?.update(configuration: configuration)
        enqueue(SCPI.setAutoRange(configuration.function, enabled).asCommands,
                log: enabled ? "Auto range on" : "Auto range off")
        if !enabled {
            setRange(configuration.range)
        }
        worker?.invalidateConfiguration()
    }

    public func setRange(_ range: Double) {
        configuration.range = range
        configuration.autoRange = false
        worker?.update(configuration: configuration)
        enqueue([SCPI.setAutoRange(configuration.function, false),
                 SCPI.setRange(configuration.function, range)],
                log: "Range: \(Format.range(range, unit: configuration.function.rangeUnit))")
        worker?.invalidateConfiguration()
    }

    public func setIntegrationTime(_ time: IntegrationTime) {
        configuration.integrationTime = time
        worker?.update(configuration: configuration)
        enqueue(SCPI.setIntegrationTime(configuration.function, time).asCommands,
                log: "Integration: \(time.title)")
        worker?.invalidateConfiguration()
    }

    public func setGateTime(_ gate: GateTime) {
        configuration.gateTime = gate
        worker?.update(configuration: configuration)
        enqueue(SCPI.setAperture(configuration.function, gate).asCommands, log: "Gate: \(gate.title)")
        worker?.invalidateConfiguration()
    }

    public func setBandwidth(_ bandwidth: ACBandwidth) {
        configuration.bandwidth = bandwidth
        worker?.update(configuration: configuration)
        enqueue(SCPI.setBandwidth(bandwidth).asCommands, log: "AC filter: \(bandwidth.rawValue) Hz")
    }

    public func setAutoZero(_ mode: AutoZero) {
        configuration.autoZero = mode
        worker?.update(configuration: configuration)
        enqueue(SCPI.setAutoZero(mode).asCommands, log: "Auto zero: \(mode.rawValue)")
    }

    public func setHighInputImpedance(_ enabled: Bool) {
        configuration.highInputImpedance = enabled
        worker?.update(configuration: configuration)
        enqueue(SCPI.setInputImpedanceAuto(enabled).asCommands,
                log: enabled ? "Input impedance: >10 GΩ" : "Input impedance: 10 MΩ")
    }

    public func setTriggerSource(_ source: TriggerSource) {
        configuration.triggerSource = source
        worker?.update(configuration: configuration)
        enqueue(configuration.triggerCommands, log: "Trigger: \(source.title)")
    }

    public func setTriggerDelay(auto: Bool, seconds: Double) {
        configuration.triggerDelayAuto = auto
        configuration.triggerDelay = max(0, seconds)
        worker?.update(configuration: configuration)
        enqueue(configuration.triggerCommands,
                log: auto ? "Trigger delay: auto" : "Trigger delay: \(SCPI.format(seconds)) s")
    }

    public func setSampleCount(_ count: Int) {
        let clamped = min(max(count, 1), 512)
        configuration.sampleCount = clamped
        worker?.update(configuration: configuration)
        enqueue(SCPI.setSampleCount(clamped).asCommands, log: "Readings per burst: \(clamped)")
    }

    // MARK: - Maths

    public func setMathFunction(_ function: MathFunction) {
        math.function = function
        enqueue(math.commands(), log: "Math: \(function.title)")
        pollPlan.readInstrumentStatistics = (function == .statistics)
        if function != .statistics {
            instrumentStatistics = InstrumentStatistics()
        }
    }

    public func setNullOffset(_ value: Double) {
        math.nullOffset = value
        guard math.function == .null else { return }
        enqueue(SCPI.setNullOffset(value).asCommands,
                log: "Null offset: \(Format.engineering(value, unit: configuration.function.unit))")
    }

    /// The front panel's Null key: take a reading now and make it the offset.
    public func captureNull() {
        guard let worker = requireConnection() else { return }
        if math.function != .null {
            setMathFunction(.null)
        }
        worker.enqueue(.captureNull)
    }

    public func setDecibelReference(_ dBm: Double) {
        math.decibelReference = dBm
        guard math.function == .decibel else { return }
        enqueue(SCPI.setDecibelReference(dBm).asCommands, log: "dB reference: \(SCPI.format(dBm)) dBm")
    }

    public func setDBmReference(_ ohms: Double) {
        math.dBmReference = ohms
        guard math.function == .dBm else { return }
        enqueue(SCPI.setDBmReference(ohms).asCommands, log: "dBm reference: \(SCPI.format(ohms)) Ω")
    }

    public func setLimits(lower: Double, upper: Double) {
        math.lowerLimit = min(lower, upper)
        math.upperLimit = max(lower, upper)
        guard math.function == .limit else { return }
        enqueue([SCPI.setLowerLimit(math.lowerLimit), SCPI.setUpperLimit(math.upperLimit)],
                log: "Limits: \(SCPI.format(math.lowerLimit)) … \(SCPI.format(math.upperLimit))")
    }

    // MARK: - Instrument actions

    public func resetDevice() {
        guard let worker = requireConnection() else { return }
        worker.enqueue(.reset)
        // *RST leaves the meter in DC volts, auto-range, 6½ digits — and the
        // panel has to be sent back down afterwards or the two disagree.
        worker.enqueue(.commands(configuration.commands() + math.commands(), log: nil))
        resetHistory()
    }

    public func runSelfTest() {
        guard let worker = requireConnection() else { return }
        message = "Self test running…"
        worker.enqueue(.selfTest)
    }

    public func readError() {
        requireConnection()?.enqueue(.readError)
    }

    public func clearInterface() {
        requireConnection()?.enqueue(.clearInterface)
    }

    public func beepOnce() {
        guard requireConnection() != nil else { return }
        enqueue(SCPI.beep.asCommands, log: "Beep")
    }

    public func setInstrumentBeeper(_ enabled: Bool) {
        enqueue(SCPI.setBeeper(enabled).asCommands, log: enabled ? "Meter beeper on" : "Meter beeper off")
    }

    public func sendDisplayText(_ text: String) {
        enqueue(SCPI.displayText(text).asCommands, log: "Display: \(text.prefix(12))")
    }

    public func clearDisplayText() {
        enqueue(SCPI.displayTextClear.asCommands, log: "Display text cleared")
    }

    public private(set) var frontPanelIsOn = true

    /// Switching the display off is worth a menu item of its own: it is the
    /// single biggest speed-up the meter offers, and costs nothing but the
    /// ability to read it from across the bench.
    public func toggleFrontPanel() {
        frontPanelIsOn.toggle()
        enqueue((frontPanelIsOn ? SCPI.displayOn : SCPI.displayOff).asCommands,
                log: frontPanelIsOn ? "Display on" : "Display off — faster readings")
    }

    public func returnToLocal() {
        enqueue(SCPI.local.asCommands, log: "Front panel unlocked")
    }

    private func beep() {
        guard beeperEnabled else { return }
        #if canImport(AppKit)
        NSSound.beep()
        #endif
    }

    // MARK: - History

    public func resetHistory() {
        history.reset()
        tableReadings.removeAll(keepingCapacity: true)
        readingCount = 0
        overloadCount = 0
        latestReading = nil
        latestReadingTime = nil
        isOverloaded = false
        measuredRate = 0
        lastRateSample = nil
        speech.reset()
    }

    public func resetRuntime() {
        runtime = 0
    }

    // MARK: - Event list

    public func append(_ text: String) {
        let stamped = "\(text),\(DateFormatter.eventTimestamp.string(from: Date()))"

        if logStatusText {
            logger?.appendStatus(stamped)
        }

        guard updateList else { return }
        entryCounter += 1
        entries.append(LogEntry(id: entryCounter, text: stamped))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    public func clearEntries() {
        entries.removeAll()
    }

    // MARK: - Data logging

    public func setLogDirectory(_ url: URL) {
        logDirectory = url
        if let identity {
            logger?.update(configuration: .init(directory: url, model: identity.model, portName: config.path))
        }
    }

    /// One line per reading. `nil` records an overload, which is information in
    /// its own right and should not silently vanish from the log.
    private func appendReadingLine(_ value: Double?, at moment: Date) {
        guard logReadingsText || logReadingsCSV else { return }
        let unit = displayUnit
        let function = configuration.function.shortTitle

        if logReadingsText {
            let stamp = DateFormatter.textLogTimestamp.string(from: moment)
            let text = value.map { Format.reading($0, unit: unit, range: displayRange, digits: displayDigits) } ?? "OVLD"
            logger?.appendReadingText("\(stamp),\(function),\(text)")
        }
        if logReadingsCSV {
            let stamp = DateFormatter.logTimestamp.string(from: moment)
            let text = value.map { Format.scientific($0) } ?? "OVLD"
            logger?.appendReadingCSV("\(stamp),\(function),\(text),\(unit)")
        }
        loggedLineCount = logger?.writtenLineCount ?? 0
        if let failure = logger?.lastError {
            message = "Log write failed: \(failure)"
        }
    }
}

private extension String {
    /// Sugar for the many one-command enqueues above.
    var asCommands: [String] { [self] }
}
