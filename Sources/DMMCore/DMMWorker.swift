import Foundation

/// A single action queued from the UI for the worker to perform on its next
/// pass. Queries that belong to the polling plan are not queued — they happen
/// every pass by definition.
public enum DMMJob: Sendable {
    /// Send one or more commands, optionally logging a line once they are out.
    case commands([String], log: String?)
    /// `*RST` followed by a forced re-read of the whole configuration.
    case reset
    /// Read one entry from the meter's error queue.
    case readError
    /// `*TST?` — the meter's own self test. Takes several seconds.
    case selfTest
    /// Take one reading and make it the null offset, the way the front panel's
    /// Null key works.
    case captureNull
    /// Ctrl-C, then re-assert remote mode. The way out of a wedged interface.
    case clearInterface
}

/// Which queries the worker performs each pass.
public struct DMMPollPlan: Sendable, Equatable, Codable {
    public var takeReadings = true
    public var readQuestionableStatus = true
    /// Read the function, range and resolution back, so the panel follows the
    /// front panel. Not every pass — see `configurationInterval`.
    public var readConfiguration = true
    public var readInstrumentStatistics = false
    /// Passes between configuration read-backs.
    public var configurationInterval = 10

    public init() {}
}

/// Everything one polling pass learned, handed to the main actor in one piece.
public struct DMMSnapshot: Sendable {
    public var timestamp = Date()
    /// Readings from the burst, oldest first, overloads already removed.
    public var readings: [Double] = []
    /// Timestamp for each entry of `readings`, spread across the acquisition.
    public var readingTimes: [Date] = []
    public var overloadCount = 0
    public var acquisitionDuration: TimeInterval = 0

    public var configuration: MeterConfiguration?
    public var questionableCondition: Int?
    public var instrumentStatistics: InstrumentStatistics?
    public var capturedNullOffset: Double?
    public var errorText: String?
    public var selfTestResult: String?
    public var logs: [String] = []
    public var failure: String?

    public init() {}
}

/// Owns the serial device and does all blocking I/O on a private queue.
///
/// The UI only ever receives finished snapshots, so a meter that has been
/// unplugged mid-burst costs a timeout, not a beachball.
public final class DMMWorker: @unchecked Sendable {
    private let device: DMMDevice
    private let queue = DispatchQueue(label: "com.agmult.serial", qos: .userInitiated)
    private let lock = NSLock()

    private var jobs: [DMMJob] = []
    private var plan = DMMPollPlan()
    private var configuration = MeterConfiguration()
    private var interval: TimeInterval = 0.2
    private var lineFrequency: Double = 50
    private var running = false
    private var passCount = 0
    private var configurationIsStale = true
    private var silentPasses = 0
    private var lastHeardFrom = Date()
    private var compoundIsWanted = true
    /// Cleared for good the first time a compound message comes back malformed.
    /// One meter in a rack that does not like them should cost one pass, not a
    /// retry on every pass for the rest of the session.
    private var compoundIsWorking = true

    /// A meter that has been unplugged, switched to HP-IB or claimed by another
    /// program does not close the port — it simply stops answering, and every
    /// query quietly times out. Without this the loop would spin forever
    /// producing nothing while the app still called itself connected.
    private static let silentPassLimit = 2
    private static let silenceTimeout: TimeInterval = 10

    private let onSnapshot: @Sendable (DMMSnapshot) -> Void

    public init(device: DMMDevice, onSnapshot: @escaping @Sendable (DMMSnapshot) -> Void) {
        self.device = device
        self.onSnapshot = onSnapshot
    }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        silentPasses = 0
        lastHeardFrom = Date()
        lock.unlock()
        queue.async { [weak self] in self?.cycle() }
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        // Closing is queued rather than waited on: a pass already blocked on a
        // burst could take a while to time out, and the UI must not freeze with
        // it. The in-flight pass finishes first, then the port closes.
        queue.async { [device] in
            device.close()
        }
    }

    public func enqueue(_ job: DMMJob) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    public func update(plan newPlan: DMMPollPlan) {
        lock.lock()
        plan = newPlan
        lock.unlock()
    }

    public func update(configuration newConfiguration: MeterConfiguration) {
        lock.lock()
        configuration = newConfiguration
        lock.unlock()
    }

    public func update(interval newInterval: TimeInterval) {
        lock.lock()
        interval = max(0, newInterval)
        lock.unlock()
    }

    public func update(lineFrequency hertz: Double) {
        lock.lock()
        lineFrequency = hertz
        lock.unlock()
    }

    /// Whether to fold several queries into one message. On by default; the
    /// preference exists because it is the one thing here that a stubborn
    /// interface converter might not forward correctly.
    public func update(usesCompoundQueries enabled: Bool) {
        lock.lock()
        compoundIsWanted = enabled
        if enabled { compoundIsWorking = true }
        lock.unlock()
    }

    /// Ask for a configuration read-back on the next pass regardless of where
    /// the interval counter stands — used right after the app changes something.
    public func invalidateConfiguration() {
        lock.lock()
        configurationIsStale = true
        lock.unlock()
    }

    private struct Settings {
        var running: Bool
        var plan: DMMPollPlan
        var configuration: MeterConfiguration
        var interval: TimeInterval
        var lineFrequency: Double
        var jobs: [DMMJob]
        var readConfiguration: Bool
        var compound: Bool
    }

    private func takeSettings() -> Settings {
        lock.lock()
        defer { lock.unlock() }

        let pending = jobs
        jobs.removeAll(keepingCapacity: true)

        let due = plan.readConfiguration
            && (configurationIsStale || passCount % max(1, plan.configurationInterval) == 0)
        if due { configurationIsStale = false }
        passCount &+= 1

        return Settings(running: running,
                        plan: plan,
                        configuration: configuration,
                        interval: interval,
                        lineFrequency: lineFrequency,
                        jobs: pending,
                        readConfiguration: due,
                        compound: compoundIsWanted && compoundIsWorking)
    }

    /// Called when a compound reply comes back with the wrong number of fields.
    private func compoundFailed(into snapshot: inout DMMSnapshot) {
        lock.lock()
        let wasWorking = compoundIsWorking
        compoundIsWorking = false
        lock.unlock()
        if wasWorking {
            snapshot.logs.append("Combined queries not understood — asking one at a time")
        }
    }

    private func cycle() {
        let started = Date()
        let settings = takeSettings()
        guard settings.running else { return }

        var snapshot = DMMSnapshot()
        snapshot.timestamp = started

        do {
            try run(jobs: settings.jobs, into: &snapshot)
            try poll(settings, into: &snapshot)
        } catch {
            snapshot.failure = error.localizedDescription
        }

        onSnapshot(snapshot)

        if snapshot.failure != nil {
            lock.lock(); running = false; lock.unlock()
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        let delay = max(0, settings.interval - elapsed)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let stillRunning = { self.lock.lock(); defer { self.lock.unlock() }; return self.running }()
            if stillRunning { self.cycle() }
        }
    }

    // MARK: - Jobs

    private func run(jobs: [DMMJob], into snapshot: inout DMMSnapshot) throws {
        for job in jobs {
            switch job {
            case .commands(let commands, let log):
                try device.send(commands)
                if let log { snapshot.logs.append(log) }

            case .reset:
                try device.send(SCPI.reset)
                try device.send(SCPI.clearStatus)
                try device.send(SCPI.remote)
                snapshot.logs.append("Reset sent")
                invalidateConfiguration()

            case .readError:
                let response = device.query(SCPI.errorQuery) ?? "?"
                snapshot.errorText = response
                snapshot.logs.append("Error queue: \(response)")

            case .selfTest:
                // The self test takes several seconds and answers 0 for pass.
                device.setReadTimeout(30)
                let response = device.query(SCPI.selfTest)
                let passed = SCPIParse.integer(response) == 0
                snapshot.selfTestResult = passed ? "Self test passed" : "Self test failed (\(response ?? "no reply"))"
                snapshot.logs.append(snapshot.selfTestResult!)
                invalidateConfiguration()

            case .captureNull:
                device.setReadTimeout(30)
                if let value = SCPIParse.number(device.query(SCPI.read)), !SCPIParse.isOverload(value) {
                    try device.send(SCPI.setNullOffset(value))
                    snapshot.capturedNullOffset = value
                    snapshot.logs.append("Null offset captured")
                } else {
                    snapshot.logs.append("Null capture failed — no usable reading")
                }

            case .clearInterface:
                try device.clearInterface()
                try device.send(SCPI.remote)
                snapshot.logs.append("Interface cleared")
                invalidateConfiguration()
            }
        }
    }

    // MARK: - Polling

    private func poll(_ settings: Settings, into snapshot: inout DMMSnapshot) throws {
        var heardAnything = false
        var statusHandled = false

        if settings.plan.takeReadings {
            // The status register can ride along with the readings: one message,
            // one reply, one round trip instead of two on the pass that runs
            // most often.
            let withStatus = settings.plan.readQuestionableStatus
                && settings.compound
                && settings.configuration.triggerSource == .immediate
            let result = try acquire(settings, into: &snapshot, includingStatus: withStatus)
            heardAnything = result.heard
            statusHandled = result.statusHandled
        }

        if settings.plan.readQuestionableStatus && !statusHandled {
            device.setReadTimeout(device.baseReadTimeout)
            snapshot.questionableCondition = SCPIParse.integer(device.query(SCPI.questionableCondition))
            heardAnything = heardAnything || snapshot.questionableCondition != nil
        }

        if settings.plan.readInstrumentStatistics {
            device.setReadTimeout(device.baseReadTimeout)
            let statistics = device.readInstrumentStatistics(compound: settings.compound)
            snapshot.instrumentStatistics = statistics
            heardAnything = heardAnything || !statistics.isEmpty
        }

        if settings.readConfiguration {
            device.setReadTimeout(device.baseReadTimeout)
            var configuration = settings.configuration
            let answered = device.readConfiguration(into: &configuration, compound: settings.compound)
            snapshot.configuration = configuration
            heardAnything = heardAnything || answered
        }

        checkForSilence(settings, heard: heardAnything, into: &snapshot)
    }

    /// An externally triggered burst that nobody triggers is silent on purpose,
    /// so that case is left alone. Everywhere else, a run of passes in which
    /// nothing at all answered means the meter has gone.
    private func checkForSilence(_ settings: Settings, heard: Bool, into snapshot: inout DMMSnapshot) {
        guard settings.plan.takeReadings || settings.plan.readQuestionableStatus else { return }
        guard settings.configuration.triggerSource != .external else { return }

        if heard {
            silentPasses = 0
            lastHeardFrom = Date()
            return
        }

        silentPasses += 1
        guard silentPasses >= Self.silentPassLimit,
              Date().timeIntervalSince(lastHeardFrom) >= Self.silenceTimeout else { return }

        snapshot.failure = "The meter stopped answering. Check the cable, that the I/O menu is still set to RS-232, and that nothing else has claimed the port."
    }

    /// What one acquisition managed: whether the meter answered at all — silence
    /// is what tells the loop the instrument has gone away — and whether the
    /// status register came back with the readings, so `poll` knows not to ask
    /// for it again.
    private struct Acquisition {
        var heard = false
        var statusHandled = false
    }

    @discardableResult
    private func acquire(_ settings: Settings,
                         into snapshot: inout DMMSnapshot,
                         includingStatus: Bool) throws -> Acquisition {
        let configuration = settings.configuration
        let expected = max(1, configuration.sampleCount)
        let burst = configuration.estimatedBurstDuration(lineFrequency: settings.lineFrequency)
        // Twice as long as the maths says the burst needs, plus the configured
        // response deadline as slack for the serial line and for auto-ranging,
        // which can add several range changes to the first reading of a burst.
        device.setReadTimeout(burst * 2 + device.baseReadTimeout)

        let started = Date()
        var response: String?
        var result = Acquisition()

        switch configuration.triggerSource {
        case .immediate:
            if includingStatus {
                if let fields = device.queryCompound([SCPI.read, SCPI.questionableCondition]) {
                    response = fields[0]
                    snapshot.questionableCondition = SCPIParse.integer(fields[1])
                    result.statusHandled = true
                } else {
                    // Either the meter did not understand the combined message or
                    // it stayed quiet altogether. Ask plainly this pass; the
                    // difference between the two shows up as silence or not.
                    compoundFailed(into: &snapshot)
                    response = device.query(SCPI.read)
                }
            } else {
                response = device.query(SCPI.read)
            }

        case .bus:
            // INIT arms the meter, *TRG fires it, FETCh collects — the three-step
            // form, because READ? would sit waiting for a trigger it never sends.
            try device.send(SCPI.initiate)
            try device.send(SCPI.trigger)
            response = device.query(SCPI.fetch)

        case .external:
            try device.send(SCPI.initiate)
            response = try waitForExternalTrigger(expected: expected, deadline: started.addingTimeInterval(max(2, settings.interval)))
        }

        let finished = Date()
        snapshot.acquisitionDuration = finished.timeIntervalSince(started)

        let values = SCPIParse.numbers(response)
        var readings: [Double] = []
        readings.reserveCapacity(values.count)
        for value in values {
            if SCPIParse.isOverload(value) {
                snapshot.overloadCount += 1
            } else {
                readings.append(value)
            }
        }

        snapshot.readings = readings
        snapshot.readingTimes = Self.timestamps(count: readings.count, from: started, to: finished)
        result.heard = response != nil
        return result
    }

    /// Waits for an externally triggered burst to fill the meter's reading
    /// memory, giving up when the interval runs out so a trigger that never
    /// arrives costs one idle pass rather than the whole session.
    private func waitForExternalTrigger(expected: Int, deadline: Date) throws -> String? {
        device.setReadTimeout(2)
        while Date() < deadline {
            if let stored = SCPIParse.integer(device.query(SCPI.storedCountQuery)), stored >= expected {
                return device.query(SCPI.fetch)
            }
            usleep(20_000)
        }
        try device.send(SCPI.abort)
        return nil
    }

    /// Spreads timestamps evenly across the window the burst was acquired in.
    ///
    /// The meter does not stamp its readings, and a burst of fifty arrives in one
    /// response — giving them all the same instant would put fifty points on top
    /// of each other on a time axis and make the rate look wrong.
    static func timestamps(count: Int, from start: Date, to end: Date) -> [Date] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [end] }
        let span = max(0, end.timeIntervalSince(start))
        let step = span / Double(count)
        return (0..<count).map { start.addingTimeInterval(step * Double($0 + 1)) }
    }
}
