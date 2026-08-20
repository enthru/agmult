import Foundation
import DMMCore

/// A SCPI-speaking stand-in for a 34401A.
///
/// It models enough of the instrument to exercise the whole application: all ten
/// functions, ranges and auto-ranging with a real overrange point, integration
/// time and its effect on noise, triggering and multi-reading bursts, the CALC
/// maths, the questionable status register, the error queue, the front-panel
/// display and remote/local. Responses use the same `+4.19000000E+00` notation
/// as the real meter.
public final class Simulated34401A: @unchecked Sendable {

    public struct Model: Sendable {
        public var identification: String
        public var scpiVersion: String

        public static let hp34401A = Model(
            identification: "HEWLETT-PACKARD,34401A,0,11-5-2",
            scpiVersion: "1994.0"
        )
    }

    public let model: Model
    public let signal: SimulatedSignal

    /// Sleep for as long as a real acquisition would take. On for the standalone
    /// simulator, so measured reading rates mean something; tests turn it off.
    public var simulatesTiming = true
    public var lineFrequency: Double = 50

    // MARK: Configuration

    public private(set) var function: MeasurementFunction = .dcVoltage
    private var ranges: [MeasurementFunction: Double] = [:]
    private var autoRanges: [MeasurementFunction: Bool] = [:]
    private var integrationTimes: [MeasurementFunction: Double] = [:]
    private var apertures: [MeasurementFunction: Double] = [:]

    public private(set) var bandwidth: Int = 20
    public private(set) var autoZero = "ON"
    public private(set) var inputImpedanceAuto = false

    public private(set) var triggerSource = "IMM"
    public private(set) var triggerDelayAuto = true
    public private(set) var triggerDelay: Double = 0
    public private(set) var sampleCount = 1
    public private(set) var triggerCount = 1

    // MARK: Maths

    public private(set) var mathEnabled = false
    public private(set) var mathFunction = "NULL"
    public private(set) var nullOffset: Double = 0
    public private(set) var decibelReference: Double = 0
    public private(set) var dBmReference: Double = 600
    public private(set) var lowerLimit: Double = -1
    public private(set) var upperLimit: Double = 1
    private var statistics = StatisticsAccumulator()

    // MARK: State

    public private(set) var questionable = 0
    public private(set) var displayOn = true
    public private(set) var displayText: String?
    public private(set) var beeperEnabled = true
    public private(set) var isRemote = false
    public private(set) var isLockedOut = false
    public private(set) var readingMemory: [Double] = []
    public private(set) var isInitiated = false

    private var errorQueue: [String] = []
    private let lock = NSLock()

    /// Command header → the function it configures, built once so the parser is
    /// a lookup rather than a wall of string comparisons.
    private let configureCommands: [String: MeasurementFunction]
    private let rangeCommands: [String: MeasurementFunction]
    private let autoRangeCommands: [String: MeasurementFunction]
    private let integrationCommands: [String: MeasurementFunction]
    private let apertureCommands: [String: MeasurementFunction]
    private let resolutionCommands: [String: MeasurementFunction]

    public init(model: Model = .hp34401A, signal: SimulatedSignal = SimulatedSignal()) {
        self.model = model
        self.signal = signal

        var configure: [String: MeasurementFunction] = [:]
        var range: [String: MeasurementFunction] = [:]
        var autoRange: [String: MeasurementFunction] = [:]
        var integration: [String: MeasurementFunction] = [:]
        var aperture: [String: MeasurementFunction] = [:]
        var resolution: [String: MeasurementFunction] = [:]

        for function in MeasurementFunction.allCases {
            configure["CONF:" + function.scpiRoot] = function
            if function.hasSelectableRange {
                range[function.rangeRoot + ":RANG"] = function
                autoRange[function.rangeRoot + ":RANG:AUTO"] = function
                resolution[function.scpiRoot + ":RES"] = function
            }
            if function.usesIntegrationTime {
                integration[function.scpiRoot + ":NPLC"] = function
            }
            if function.usesAperture {
                aperture[function.scpiRoot + ":APER"] = function
            }
        }

        self.configureCommands = configure
        self.rangeCommands = range
        self.autoRangeCommands = autoRange
        self.integrationCommands = integration
        self.apertureCommands = aperture
        self.resolutionCommands = resolution

        applyPowerOnDefaults()
    }

    private func applyPowerOnDefaults() {
        for function in MeasurementFunction.allCases {
            ranges[function] = function.ranges.first ?? 1
            autoRanges[function] = true
            integrationTimes[function] = 1
            apertures[function] = 0.1
        }
        function = .dcVoltage
        ranges[.dcVoltage] = 10
    }

    // MARK: - Measuring

    public func range(for function: MeasurementFunction) -> Double {
        ranges[function] ?? function.ranges.first ?? 1
    }

    public func isAutoRanging(_ function: MeasurementFunction) -> Bool {
        autoRanges[function] ?? true
    }

    public func integrationTime(for function: MeasurementFunction) -> Double {
        integrationTimes[function] ?? 1
    }

    public func aperture(for function: MeasurementFunction) -> Double {
        apertures[function] ?? 0.1
    }

    /// Seconds one reading takes, from the settings in force.
    public var readingDuration: TimeInterval {
        if function.usesAperture {
            return aperture(for: function) + 0.005
        }
        if function.usesIntegrationTime {
            let cycles = integrationTime(for: function)
            return cycles / lineFrequency * (autoZero == "ON" ? 2 : 1) + 0.001
        }
        return 0.02
    }

    /// One measurement, complete with auto-ranging, overload and the maths.
    /// Returns the value the meter would put on the bus — which for an overload
    /// is the 9.9E37 sentinel, not a number anybody should plot.
    public func measure() -> Double {
        let effectiveIntegration = function.usesAperture ? aperture(for: function) : integrationTime(for: function) / lineFrequency
        var value = signal.sample(function: function, integrationTime: max(effectiveIntegration, 1e-4))

        // The counter functions read the input frequency, not its amplitude, so
        // their range describes the signal the front end has to cope with and
        // never overloads the reading itself.
        if function.hasSelectableRange && !function.usesAperture {
            if isAutoRanging(function) {
                ranges[function] = autoSelectedRange(for: abs(value))
            }
            let limit = range(for: function) * 1.2
            if abs(value) > limit {
                flagOverload()
                return SCPIParse.overloadSentinel
            }
        }

        // Continuity and diode report an open circuit the same way.
        if function == .continuity && value > 1200 { return SCPIParse.overloadSentinel }
        if function == .diode && value > 1.2 { return SCPIParse.overloadSentinel }

        value = applyMath(to: value)
        return value
    }

    private func autoSelectedRange(for magnitude: Double) -> Double {
        let available = function.ranges
        // Up-range at 120% of full scale, exactly as the meter does.
        for candidate in available where magnitude <= candidate * 1.2 {
            return candidate
        }
        return available.last ?? 1
    }

    private func flagOverload() {
        switch function {
        case .dcVoltage, .acVoltage, .diode: questionable |= 0x0001
        case .dcCurrent, .acCurrent: questionable |= 0x0002
        case .resistance, .resistance4Wire, .continuity: questionable |= 0x0200
        case .frequency, .period: questionable |= 0x0001
        }
    }

    private func applyMath(to reading: Double) -> Double {
        guard mathEnabled else { return reading }

        switch mathFunction {
        case "NULL":
            return reading - nullOffset

        case "DBM":
            return dBm(from: reading)

        case "DB":
            // The meter's dB is relative: the reading in dBm minus a reference
            // level, also in dBm.
            return dBm(from: reading) - decibelReference

        case "AVER":
            statistics.add(reading)
            return reading

        case "LIM":
            questionable &= ~0x1800
            if reading < lowerLimit { questionable |= 0x0800 }
            if reading > upperLimit { questionable |= 0x1000 }
            return reading

        default:
            return reading
        }
    }

    private func dBm(from reading: Double) -> Double {
        let resistance = dBmReference > 0 ? dBmReference : 600
        let milliwatts = reading * reading / resistance / 0.001
        guard milliwatts > 0 else { return -200 }
        return 10 * log10(milliwatts)
    }

    /// A burst of `sampleCount` readings, taking as long as the real thing would.
    private func acquireBurst() -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(sampleCount)
        for _ in 0..<max(1, sampleCount) {
            if simulatesTiming {
                let delay = readingDuration
                if delay > 0 { usleep(useconds_t(min(delay, 5) * 1_000_000)) }
            }
            values.append(measure())
        }
        return values
    }

    // MARK: - SCPI

    /// Handles one message. Returns the response, or nil for commands that do
    /// not produce one.
    ///
    /// A message may be compound: several commands separated by semicolons, with
    /// their replies joined by semicolons in the same order. The real meter
    /// accepts these and the application relies on them to keep its polling rate
    /// up, so the simulator has to as well.
    public func respond(to line: String) -> String? {
        let parts = Self.splitCompound(line)
        guard !parts.isEmpty else { return nil }
        guard parts.count > 1 else { return respondToSingle(parts[0]) }

        let replies = parts.compactMap { respondToSingle($0) }
        return replies.isEmpty ? nil : replies.joined(separator: ";")
    }

    /// Splits on semicolons that are not inside a quoted string, so
    /// `DISP:TEXT "a;b"` survives intact.
    static func splitCompound(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?

        for character in line {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case ";":
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)

        return parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\0")) }
            .filter { !$0.isEmpty }
    }

    private func respondToSingle(_ command: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = command

        // A bare Ctrl-C is a device clear, not a command.
        if trimmed.unicodeScalars.first?.value == 0x03 {
            isInitiated = false
            readingMemory.removeAll()
            return nil
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        var header = String(parts[0]).uppercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        let isQuery = header.hasSuffix("?")
        if isQuery { header.removeLast() }
        if header.hasPrefix(":") { header.removeFirst() }
        let canonical = Self.canonical(header)

        if let response = respondToCommon(canonical, isQuery: isQuery, argument: argument) { return response.value }
        if let response = respondToFunction(canonical, isQuery: isQuery, argument: argument) { return response.value }
        if let response = respondToAcquisition(canonical, isQuery: isQuery, argument: argument) { return response.value }
        if let response = respondToMath(canonical, isQuery: isQuery, argument: argument) { return response.value }
        if let response = respondToSystem(canonical, isQuery: isQuery, argument: argument) { return response.value }

        pushError("-113,\"Undefined header\"")
        return isQuery ? "+0" : nil
    }

    /// A handled command, with the reply it produced — `Optional<Reply>` so a
    /// handler can say "this was mine, and there is nothing to send back".
    private struct Reply { let value: String? }

    private func respondToCommon(_ header: String, isQuery: Bool, argument: String) -> Reply? {
        switch (header, isQuery) {
        case ("*IDN", true): return Reply(value: model.identification)
        case ("*RST", false):
            reset()
            return Reply(value: nil)
        case ("*CLS", false):
            questionable = 0
            errorQueue.removeAll()
            return Reply(value: nil)
        case ("*TST", true):
            if simulatesTiming { usleep(200_000) }
            return Reply(value: "+0")
        case ("*OPC", true): return Reply(value: "1")
        case ("*OPC", false): return Reply(value: nil)
        case ("*TRG", false):
            guard isInitiated else {
                pushError("-211,\"Trigger ignored\"")
                return Reply(value: nil)
            }
            readingMemory = acquireBurst()
            isInitiated = false
            return Reply(value: nil)
        default: return nil
        }
    }

    private func respondToFunction(_ header: String, isQuery: Bool, argument: String) -> Reply? {
        if header == "FUNC" {
            if isQuery { return Reply(value: "\"\(function.queryToken)\"") }
            let token = argument.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            guard let selected = MeasurementFunction.allCases.first(where: {
                Self.canonical(token.uppercased()) == $0.scpiRoot || token.uppercased() == $0.queryToken
            }) else {
                pushError("-224,\"Illegal parameter value\"")
                return Reply(value: nil)
            }
            function = selected
            return Reply(value: nil)
        }

        if let selected = configureCommands[header], !isQuery {
            // CONFigure resets that function's range, resolution and triggering.
            function = selected
            autoRanges[selected] = true
            ranges[selected] = selected.ranges.first ?? 1
            integrationTimes[selected] = 1
            apertures[selected] = 0.1
            triggerSource = "IMM"
            triggerDelayAuto = true
            sampleCount = 1
            triggerCount = 1
            return Reply(value: nil)
        }

        if let selected = rangeCommands[header] {
            if isQuery {
                let wantsMaximum = argument.uppercased().hasPrefix("MAX")
                return Reply(value: number(wantsMaximum ? (selected.ranges.last ?? 1) : range(for: selected)))
            }
            let requested = value(argument, maximum: selected.ranges.last ?? 1)
            ranges[selected] = nearestRange(atLeast: requested, in: selected.ranges)
            autoRanges[selected] = false
            return Reply(value: nil)
        }

        if let selected = autoRangeCommands[header] {
            if isQuery { return Reply(value: isAutoRanging(selected) ? "1" : "0") }
            let token = argument.uppercased()
            if token.hasPrefix("ONCE") {
                autoRanges[selected] = false
                ranges[selected] = autoSelectedRange(for: abs(signal.baseValue(for: selected)))
            } else {
                autoRanges[selected] = booleanValue(argument)
            }
            return Reply(value: nil)
        }

        if let selected = integrationCommands[header] {
            if isQuery { return Reply(value: number(integrationTime(for: selected))) }
            let requested = value(argument, maximum: 100)
            guard let snapped = SCPIParse.nearestIntegrationTime(requested) else { return Reply(value: nil) }
            integrationTimes[selected] = snapped.rawValue
            return Reply(value: nil)
        }

        if let selected = apertureCommands[header] {
            if isQuery { return Reply(value: number(aperture(for: selected))) }
            let requested = value(argument, maximum: 1)
            guard let snapped = SCPIParse.nearestGateTime(requested) else { return Reply(value: nil) }
            apertures[selected] = snapped.rawValue
            return Reply(value: nil)
        }

        if let selected = resolutionCommands[header] {
            // Resolution and NPLC are two ways of saying the same thing; the
            // meter converts between them and so does this.
            if isQuery {
                return Reply(value: number(range(for: selected) * pow(10, -6)))
            }
            return Reply(value: nil)
        }

        switch (header, isQuery) {
        case ("DET:BAND", true): return Reply(value: number(Double(bandwidth)))
        case ("DET:BAND", false):
            let requested = value(argument, maximum: 200)
            bandwidth = ACBandwidth.allCases
                .min { abs(Double($0.rawValue) - requested) < abs(Double($1.rawValue) - requested) }?
                .rawValue ?? 20
            return Reply(value: nil)

        case ("ZERO:AUTO", true):
            // The meter reports ONCE as OFF, because that is what it becomes.
            return Reply(value: autoZero == "ON" ? "1" : "0")
        case ("ZERO:AUTO", false):
            let token = argument.uppercased()
            autoZero = token.hasPrefix("ONCE") ? "OFF" : (booleanValue(argument) ? "ON" : "OFF")
            return Reply(value: nil)

        case ("INP:IMP:AUTO", true): return Reply(value: inputImpedanceAuto ? "1" : "0")
        case ("INP:IMP:AUTO", false):
            inputImpedanceAuto = booleanValue(argument)
            return Reply(value: nil)

        default: return nil
        }
    }

    private func respondToAcquisition(_ header: String, isQuery: Bool, argument: String) -> Reply? {
        switch (header, isQuery) {
        case ("TRIG:SOUR", true): return Reply(value: triggerSource)
        case ("TRIG:SOUR", false):
            let token = argument.uppercased()
            guard let source = ["IMM", "BUS", "EXT"].first(where: { token.hasPrefix($0) }) else {
                pushError("-224,\"Illegal parameter value\"")
                return Reply(value: nil)
            }
            triggerSource = source
            return Reply(value: nil)

        case ("TRIG:DEL:AUTO", true): return Reply(value: triggerDelayAuto ? "1" : "0")
        case ("TRIG:DEL:AUTO", false):
            triggerDelayAuto = booleanValue(argument)
            return Reply(value: nil)
        case ("TRIG:DEL", true): return Reply(value: number(triggerDelay))
        case ("TRIG:DEL", false):
            triggerDelay = max(0, value(argument, maximum: 3600))
            triggerDelayAuto = false
            return Reply(value: nil)

        case ("TRIG:COUN", true): return Reply(value: number(Double(triggerCount)))
        case ("TRIG:COUN", false):
            triggerCount = max(1, Int(value(argument, maximum: 50_000)))
            return Reply(value: nil)

        case ("SAMP:COUN", true): return Reply(value: number(Double(sampleCount)))
        case ("SAMP:COUN", false):
            let requested = Int(value(argument, maximum: 50_000))
            guard requested >= 1, requested <= 50_000 else {
                pushError("-222,\"Data out of range\"")
                return Reply(value: nil)
            }
            sampleCount = requested
            return Reply(value: nil)

        case ("INIT", false):
            isInitiated = true
            readingMemory.removeAll()
            // Anything but a bus or external trigger fires straight away.
            if triggerSource == "IMM" {
                readingMemory = acquireBurst()
                isInitiated = false
            }
            return Reply(value: nil)

        case ("ABOR", false):
            isInitiated = false
            readingMemory.removeAll()
            return Reply(value: nil)

        case ("READ", true):
            // READ? is INITiate followed by FETCh?, and with an immediate
            // trigger that is the whole story.
            readingMemory = acquireBurst()
            isInitiated = false
            return Reply(value: burstResponse())

        case ("FETC", true):
            guard !readingMemory.isEmpty else {
                pushError("-230,\"Data corrupt or stale\"")
                return Reply(value: "+0")
            }
            return Reply(value: burstResponse())

        case ("DATA:POIN", true):
            return Reply(value: "+\(readingMemory.count)")

        default: return nil
        }
    }

    private func burstResponse() -> String {
        readingMemory.map { number($0) }.joined(separator: ",")
    }

    private func respondToMath(_ header: String, isQuery: Bool, argument: String) -> Reply? {
        switch (header, isQuery) {
        case ("CALC:STAT", true): return Reply(value: mathEnabled ? "1" : "0")
        case ("CALC:STAT", false):
            mathEnabled = booleanValue(argument)
            if !mathEnabled { questionable &= ~0x1800 }
            return Reply(value: nil)

        case ("CALC:FUNC", true): return Reply(value: mathFunction)
        case ("CALC:FUNC", false):
            let token = argument.uppercased()
            guard let selected = ["NULL", "DB", "DBM", "AVER", "LIM"].first(where: { token.hasPrefix($0) }) else {
                pushError("-224,\"Illegal parameter value\"")
                return Reply(value: nil)
            }
            // Switching function starts the statistics over, as on the meter.
            if selected != mathFunction { statistics.reset() }
            mathFunction = selected
            return Reply(value: nil)

        case ("CALC:NULL:OFFS", true): return Reply(value: number(nullOffset))
        case ("CALC:NULL:OFFS", false):
            nullOffset = value(argument, maximum: 1e6)
            return Reply(value: nil)

        case ("CALC:DB:REF", true): return Reply(value: number(decibelReference))
        case ("CALC:DB:REF", false):
            decibelReference = value(argument, maximum: 200)
            return Reply(value: nil)

        case ("CALC:DBM:REF", true): return Reply(value: number(dBmReference))
        case ("CALC:DBM:REF", false):
            dBmReference = value(argument, maximum: 8000)
            return Reply(value: nil)

        case ("CALC:LIM:LOW", true): return Reply(value: number(lowerLimit))
        case ("CALC:LIM:LOW", false):
            lowerLimit = value(argument, maximum: 1e6)
            return Reply(value: nil)
        case ("CALC:LIM:UPP", true): return Reply(value: number(upperLimit))
        case ("CALC:LIM:UPP", false):
            upperLimit = value(argument, maximum: 1e6)
            return Reply(value: nil)

        case ("CALC:AVER:MIN", true):
            return Reply(value: number(statistics.statistics.isEmpty ? 0 : statistics.statistics.minimum))
        case ("CALC:AVER:MAX", true):
            return Reply(value: number(statistics.statistics.isEmpty ? 0 : statistics.statistics.maximum))
        case ("CALC:AVER:AVER", true):
            return Reply(value: number(statistics.statistics.isEmpty ? 0 : statistics.statistics.mean))
        case ("CALC:AVER:COUN", true):
            return Reply(value: "+\(statistics.statistics.count)")

        default: return nil
        }
    }

    private func respondToSystem(_ header: String, isQuery: Bool, argument: String) -> Reply? {
        switch (header, isQuery) {
        case ("SYST:REM", false):
            isRemote = true
            isLockedOut = false
            return Reply(value: nil)
        case ("SYST:RWL", false):
            isRemote = true
            isLockedOut = true
            return Reply(value: nil)
        case ("SYST:LOC", false):
            isRemote = false
            isLockedOut = false
            return Reply(value: nil)
        case ("SYST:ERR", true):
            return Reply(value: errorQueue.isEmpty ? "+0,\"No error\"" : errorQueue.removeFirst())
        case ("SYST:VERS", true):
            return Reply(value: model.scpiVersion)
        case ("SYST:BEEP", false):
            return Reply(value: nil)
        case ("SYST:BEEP:STAT", true):
            return Reply(value: beeperEnabled ? "1" : "0")
        case ("SYST:BEEP:STAT", false):
            beeperEnabled = booleanValue(argument)
            return Reply(value: nil)

        case ("DISP", true): return Reply(value: displayOn ? "1" : "0")
        case ("DISP", false):
            displayOn = booleanValue(argument)
            return Reply(value: nil)
        case ("DISP:TEXT", true): return Reply(value: "\"\(displayText ?? "")\"")
        case ("DISP:TEXT", false):
            displayText = String(argument.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).prefix(12))
            return Reply(value: nil)
        case ("DISP:TEXT:CLE", false):
            displayText = nil
            return Reply(value: nil)

        case ("STAT:QUES:COND", true):
            return Reply(value: "+\(questionable)")
        case ("STAT:QUES:EVEN", true):
            let value = questionable
            questionable = 0
            return Reply(value: "+\(value)")

        default: return nil
        }
    }

    public func reset() {
        applyPowerOnDefaults()
        bandwidth = 20
        autoZero = "ON"
        inputImpedanceAuto = false
        triggerSource = "IMM"
        triggerDelayAuto = true
        triggerDelay = 0
        sampleCount = 1
        triggerCount = 1
        mathEnabled = false
        mathFunction = "NULL"
        nullOffset = 0
        decibelReference = 0
        dBmReference = 600
        lowerLimit = -1
        upperLimit = 1
        statistics.reset()
        questionable = 0
        displayOn = true
        displayText = nil
        readingMemory.removeAll()
        isInitiated = false
        errorQueue.removeAll()
    }

    private func pushError(_ text: String) {
        if errorQueue.count < 20 { errorQueue.append(text) }
    }

    // MARK: - Helpers

    private func number(_ value: Double) -> String {
        String(format: "%+.8E", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func value(_ text: String, maximum: Double) -> Double {
        let upper = text.uppercased()
        if upper.hasPrefix("MAX") { return maximum }
        if upper.hasPrefix("MIN") { return 0 }
        if upper.hasPrefix("DEF") { return 0 }
        return Double(text) ?? 0
    }

    private func booleanValue(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper == "ON" || upper == "1" || upper == "TRUE"
    }

    /// The meter snaps a requested range up to the first one that can hold it.
    private func nearestRange(atLeast requested: Double, in available: [Double]) -> Double {
        for candidate in available where requested <= candidate * 1.0001 {
            return candidate
        }
        return available.last ?? requested
    }

    /// Expands SCPI short-form mnemonics so `MEAS:VOLT?` and `MEASURE:VOLTAGE?`
    /// reach the same branch.
    static func canonical(_ header: String) -> String {
        let expansions: [String: String] = [
            "VOLTAGE": "VOLT", "CURRENT": "CURR", "RESISTANCE": "RES",
            "FRESISTANCE": "FRES", "FREQUENCY": "FREQ", "PERIOD": "PER",
            "CONTINUITY": "CONT", "DIODE": "DIOD", "CONFIGURE": "CONF",
            "FUNCTION": "FUNC", "RANGE": "RANG", "RESOLUTION": "RES",
            "NPLCYCLES": "NPLC", "APERTURE": "APER", "DETECTOR": "DET",
            "BANDWIDTH": "BAND", "INPUT": "INP", "IMPEDANCE": "IMP",
            "TRIGGER": "TRIG", "SOURCE": "SOUR", "DELAY": "DEL",
            "COUNT": "COUN", "SAMPLE": "SAMP", "INITIATE": "INIT",
            "FETCH": "FETC", "ABORT": "ABOR", "CALCULATE": "CALC",
            "AVERAGE": "AVER", "MINIMUM": "MIN", "MAXIMUM": "MAX",
            "OFFSET": "OFFS", "REFERENCE": "REF", "LIMIT": "LIM",
            "LOWER": "LOW", "UPPER": "UPP", "STATE": "STAT",
            "STATUS": "STAT", "QUESTIONABLE": "QUES", "CONDITION": "COND",
            "EVENT": "EVEN", "SYSTEM": "SYST", "ERROR": "ERR",
            "VERSION": "VERS", "REMOTE": "REM", "LOCAL": "LOC",
            "BEEPER": "BEEP", "DISPLAY": "DISP", "CLEAR": "CLE",
            "POINTS": "POIN", "AUTO": "AUTO", "LEVEL": "LEV",
        ]
        return header
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { expansions[String($0)] ?? String($0) }
            .joined(separator: ":")
    }
}
