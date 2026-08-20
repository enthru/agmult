import XCTest
@testable import DMMCore
@testable import DMMSimulator

/// The polling loop end to end: a real serial connection to the simulator, with
/// the controller on the main actor exactly as the application runs it.
@MainActor
final class ControllerTests: XCTestCase {

    private var server: SimulatorServer!
    private var controller: DMMController!
    private var logDirectory: URL!

    override func setUp() async throws {
        let meter = Simulated34401A()
        // Real acquisition timing would make every test take its integration
        // time; the loop being tested here does not care how long the meter
        // thinks about a reading.
        meter.simulatesTiming = false
        meter.signal.modulation = .steady
        meter.signal.noiseFraction = 0
        meter.signal[.dcVoltage] = 4.19

        server = try SimulatorServer(meter: meter)
        server.start()

        logDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agmult-tests-\(UUID().uuidString)", isDirectory: true)

        controller = DMMController()
        controller.beeperEnabled = false
        controller.updateInterval = 0.02
        controller.pollPlan.configurationInterval = 1
        controller.setLogDirectory(logDirectory)
    }

    override func tearDown() async throws {
        controller?.disconnect()
        server?.stop()
        if let logDirectory {
            try? FileManager.default.removeItem(at: logDirectory)
        }
        controller = nil
        server = nil
        logDirectory = nil
    }

    private func connect() throws {
        // A short deadline keeps the "meter went away" test from spending
        // half a minute waiting for reads that will never be answered.
        let config = SerialConfig(path: server.devicePath, readTimeout: 1, writeTimeout: 1)
        let identity = try ConnectionProbe.identify(config: config)
        controller.connect(config: config, identity: identity)
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 8,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Let several passes go by, so anything queued has certainly been applied.
    private func settle(_ seconds: TimeInterval = 0.4) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The loop

    func testReadingsArriveAndLandInEveryPlaceTheyShould() async throws {
        try connect()
        try await waitUntil("the first readings") { self.controller.readingCount >= 5 }

        XCTAssertTrue(controller.isConnected)
        XCTAssertEqual(controller.latestReading!, 4.19, accuracy: 0.001)
        XCTAssertTrue(controller.readingIsValid)
        XCTAssertFalse(controller.history.isEmpty)
        XCTAssertFalse(controller.tableReadings.isEmpty)
        XCTAssertEqual(controller.statistics.mean, 4.19, accuracy: 0.001)
        XCTAssertGreaterThan(controller.measuredRate, 0)
        XCTAssertEqual(controller.formattedReading, "4.19000 V")
    }

    func testConnectingPutsTheMeterIntoTheStateThePanelShows() async throws {
        controller.pollPlan.readConfiguration = true
        try connect()
        try await settle()

        XCTAssertTrue(server.simulatedMeter.isRemote)
        XCTAssertEqual(server.simulatedMeter.function, .dcVoltage)
    }

    func testDisconnectingStopsTheLoopAndReleasesTheMeter() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.disconnect()
        let countAtDisconnect = controller.readingCount
        try await settle()

        XCTAssertFalse(controller.isConnected)
        XCTAssertEqual(controller.readingCount, countAtDisconnect, "no readings after disconnect")
        XCTAssertFalse(server.simulatedMeter.isRemote, "the front panel must work again")
    }

    // MARK: - Configuration

    func testChangingFunctionReachesTheMeterAndStartsTheHistoryOver() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount >= 3 }

        server.signal[.resistance] = 1234
        controller.setFunction(.resistance)
        try await waitUntil("resistance readings") {
            self.controller.readingCount >= 3 && self.controller.configuration.function == .resistance
        }

        XCTAssertEqual(server.simulatedMeter.function, .resistance)
        XCTAssertEqual(controller.latestReading!, 1234, accuracy: 0.1)
        XCTAssertEqual(controller.displayUnit, "Ω")
        // The history was cleared when the unit changed, so nothing from the
        // voltage run is mixed into the resistance statistics.
        XCTAssertEqual(controller.statistics.minimum, 1234, accuracy: 0.1)
    }

    func testRangeAndResolutionReachTheMeter() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setRange(100)
        controller.setIntegrationTime(.fast)
        try await settle()

        XCTAssertEqual(server.simulatedMeter.range(for: .dcVoltage), 100)
        XCTAssertFalse(server.simulatedMeter.isAutoRanging(.dcVoltage))
        XCTAssertEqual(server.simulatedMeter.integrationTime(for: .dcVoltage), 0.2, accuracy: 1e-9)
        XCTAssertEqual(controller.displayDigits, 5)
        // Five and a half digits on the 100 V range leaves three decimals —
        // the wider range costs the resolution the shorter aperture already did.
        XCTAssertEqual(controller.formattedReading, "4.190 V")
    }

    /// Somebody presses a button on the meter. The panel should follow it rather
    /// than keep asserting what the app last sent.
    func testAFrontPanelChangeIsAdopted() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        _ = server.simulatedMeter.respond(to: "CONF:FRES")
        try await waitUntil("the read-back to notice") {
            self.controller.configuration.function == .resistance4Wire
        }

        XCTAssertEqual(controller.displayUnit, "Ω")
        XCTAssertTrue(controller.entries.contains { $0.text.contains("Function changed on the meter") })
    }

    func testABurstDeliversEveryReadingOfThePass() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setSampleCount(10)
        try await settle()          // let anything already in flight land
        controller.resetHistory()
        try await waitUntil("a burst") { self.controller.readingCount >= 20 }

        XCTAssertEqual(controller.readingCount % 10, 0, "readings arrive ten at a time")
        XCTAssertEqual(server.simulatedMeter.sampleCount, 10)

        // Readings inside a burst are stamped across the acquisition, not piled
        // onto one instant.
        let stamps = controller.history.samples.prefix(10).map(\.timestamp)
        XCTAssertGreaterThan(stamps.last!.timeIntervalSince(stamps.first!), 0)
    }

    /// The configuration read-back only covers what the meter reports. Anything
    /// it does not — the burst size, the trigger, auto zero — has to survive a
    /// pass that started before the change was made.
    func testAReadBackDoesNotRollBackSettingsTheMeterNeverReports() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setSampleCount(10)
        controller.setAutoZero(.off)
        controller.setTriggerSource(.bus)

        // Many read-back passes go by; none of them may undo the above.
        try await settle(1.0)

        XCTAssertEqual(controller.configuration.sampleCount, 10)
        XCTAssertEqual(controller.configuration.autoZero, .off)
        XCTAssertEqual(controller.configuration.triggerSource, .bus)
        XCTAssertEqual(server.simulatedMeter.sampleCount, 10)
        XCTAssertEqual(server.simulatedMeter.triggerSource, "BUS")
    }

    // MARK: - Compound queries

    /// Counts what the simulator was actually asked, from its own thread.
    private final class TrafficCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock(); count += 1; lock.unlock()
        }

        func take() -> Int {
            lock.lock(); defer { count = 0; lock.unlock() }; return count
        }
    }

    /// The claim is that folding queries into one message costs fewer round
    /// trips, so the test counts round trips rather than timing a simulator that
    /// answers instantly.
    func testCompoundQueriesCostFewerRoundTrips() async throws {
        let counter = TrafficCounter()
        server.onTraffic = { _, _ in counter.record() }

        controller.updateInterval = 0.01
        controller.usesCompoundQueries = true
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 5 }

        _ = counter.take()
        let start = controller.readingCount
        try await waitUntil("a run of readings") { self.controller.readingCount >= start + 40 }
        let combined = Double(counter.take()) / Double(controller.readingCount - start)

        controller.usesCompoundQueries = false
        try await settle(0.3)
        _ = counter.take()
        let restart = controller.readingCount
        try await waitUntil("another run") { self.controller.readingCount >= restart + 40 }
        let separate = Double(counter.take()) / Double(controller.readingCount - restart)

        XCTAssertLessThan(combined, separate * 0.75,
                          "combined \(combined) vs separate \(separate) messages per reading")
    }

    /// Both paths have to produce the same information — the saving is in the
    /// number of messages, not in what comes back.
    func testTurningCompoundQueriesOffChangesNothingButTheMessageCount() async throws {
        controller.usesCompoundQueries = false
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 5 }

        XCTAssertEqual(controller.latestReading!, 4.19, accuracy: 0.001)
        XCTAssertTrue(controller.questionableIsKnown)
        XCTAssertEqual(controller.configuration.function, .dcVoltage)
    }

    // MARK: - Overload and limits

    func testAnOverloadIsCountedAndShownButNotPlotted() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setRange(1)      // 4.19 V will not fit
        try await waitUntil("an overload") { self.controller.isOverloaded }

        let plotted = controller.history.samples.count
        try await settle()
        XCTAssertEqual(controller.formattedReading, "OVLD")
        XCTAssertFalse(controller.readingIsValid)
        XCTAssertGreaterThan(controller.overloadCount, 0)
        XCTAssertEqual(controller.history.samples.count, plotted, "9.9E37 must not reach the graph")
        XCTAssertTrue(controller.questionable.voltageOverload)
    }

    func testAFailedLimitTestIsReportedOnce() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setLimits(lower: 0, upper: 1)
        controller.setMathFunction(.limit)
        try await waitUntil("the limit to fail") {
            self.controller.questionableIsKnown && self.controller.questionable.limitFailedHigh
        }
        try await settle()

        let failures = controller.entries.filter { $0.text.hasPrefix("Limit Failed HI") }
        XCTAssertEqual(failures.count, 1, "a trip is logged once, not on every pass")
    }

    // MARK: - Maths

    func testCaptureNullTakesAReadingAndUsesItAsTheOffset() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.captureNull()
        try await waitUntil("the captured offset") { abs(self.controller.math.nullOffset - 4.19) < 0.001 }
        try await waitUntil("nulled readings") {
            guard let value = self.controller.latestReading else { return false }
            return abs(value) < 0.001
        }

        XCTAssertEqual(controller.math.function, .null)
    }

    func testTheMetersOwnStatisticsAreReadBackSeparately() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.setMathFunction(.statistics)
        try await waitUntil("the meter's tally") {
            (self.controller.instrumentStatistics.count ?? 0) > 3
        }

        XCTAssertEqual(controller.instrumentStatistics.average!, 4.19, accuracy: 0.001)
        XCTAssertTrue(controller.pollPlan.readInstrumentStatistics)
    }

    // MARK: - Housekeeping

    func testSelfTestAndErrorQueueReportBack() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        controller.runSelfTest()
        try await waitUntil("the self test") { self.controller.message.contains("Self test passed") }

        controller.readError()
        try await waitUntil("the error queue") { self.controller.errorText.contains("No error") }
    }

    func testDataLoggerWritesReadingsToDisk() async throws {
        controller.logReadingsCSV = true
        controller.logStatusText = true
        try connect()
        try await waitUntil("readings") { self.controller.readingCount >= 10 }
        try await waitUntil("the log to be written") { self.controller.loggedLineCount > 0 }
        controller.disconnect()

        let files = try FileManager.default.contentsOfDirectory(atPath: logDirectory.path)
        let readings = try XCTUnwrap(files.first { $0.hasSuffix("Readings.csv") },
                                     "expected a readings CSV, found \(files)")
        XCTAssertTrue(readings.contains("HP34401A"), "the file name carries the model")

        let text = try String(contentsOf: logDirectory.appendingPathComponent(readings), encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "DateTime,Function,Value,Unit")
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.contains("DCV") && $0.contains("V") })
        XCTAssertTrue(files.contains { $0.hasSuffix("Status.txt") })
    }

    func testTheEventListIsBoundedAndClearable() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        XCTAssertTrue(controller.entries.contains { $0.text.contains("Connected to HP34401A") })
        controller.clearEntries()
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testLosingTheMeterEndsTheSessionRatherThanHanging() async throws {
        try connect()
        try await waitUntil("readings") { self.controller.readingCount > 0 }

        // Pull the plug: the line is still there, the meter simply stops
        // answering. Nothing fails outright — every query just times out.
        server.isMute = true
        try await waitUntil("the loop to give up", timeout: 45) { !self.controller.isConnected }

        XCTAssertNotNil(controller.connectionError)
        XCTAssertTrue(controller.entries.contains { $0.text.contains("Connection lost") })
    }
}
