import XCTest
@testable import DMMCore
@testable import DMMSimulator

/// End-to-end coverage: a real `termios` serial connection over a pseudo-terminal
/// to the SCPI simulator. Everything except the physical UART is exercised.
final class SimulatorIntegrationTests: XCTestCase {

    private var server: SimulatorServer!
    private var device: DMMDevice!

    override func setUpWithError() throws {
        let meter = Simulated34401A()
        // Real acquisition timing would make the suite take minutes; the serial
        // path being tested here does not care how long the meter thinks.
        meter.simulatesTiming = false
        meter.signal.modulation = .steady
        meter.signal.noiseFraction = 0

        server = try SimulatorServer(meter: meter)
        server.start()

        device = DMMDevice(config: SerialConfig(path: server.devicePath, readTimeout: 3, writeTimeout: 3))
        try device.open()
    }

    override func tearDown() {
        device?.close()
        server?.stop()
        device = nil
        server = nil
    }

    // MARK: - Identification and remote mode

    func testIdentifiesTheMeterAndClaimsRemoteMode() throws {
        let identity = try device.identify()
        XCTAssertEqual(identity.model, "HP34401A")
        XCTAssertEqual(identity.manufacturer, "HEWLETT-PACKARD")
        XCTAssertEqual(identity.firmware, "11-5-2")
        XCTAssertTrue(identity.isMultimeter)
        XCTAssertTrue(server.simulatedMeter.isRemote, "SYST:REM is not optional over RS-232")
    }

    func testDisconnectingHandsTheFrontPanelBack() throws {
        _ = try device.identify()
        XCTAssertTrue(server.simulatedMeter.isRemote)

        device.close()
        // Closing does not wait for the far end to process the SYSTem:LOCal it
        // just sent — that would mean blocking on a port that may be dead — so
        // the simulator's reader thread is given a moment to catch up.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && server.simulatedMeter.isRemote {
            usleep(5000)
        }
        XCTAssertFalse(server.simulatedMeter.isRemote, "the meter would otherwise ignore its own buttons")
    }

    func testRejectsAnInstrumentThatIsNotAMultimeter() throws {
        let other = Simulated34401A(model: .init(identification: "HEWLETT-PACKARD,6632B,0,A.01.04", scpiVersion: "1994.0"))
        other.simulatesTiming = false
        let otherServer = try SimulatorServer(meter: other)
        otherServer.start()
        defer { otherServer.stop() }

        let otherDevice = DMMDevice(config: SerialConfig(path: otherServer.devicePath, readTimeout: 2, writeTimeout: 2))
        try otherDevice.open()
        defer { otherDevice.close() }

        XCTAssertThrowsError(try otherDevice.identify()) { error in
            guard case DMMDeviceError.wrongInstrument = error else {
                return XCTFail("expected a wrong-instrument error, got \(error)")
            }
        }
    }

    // MARK: - Reading

    func testReadsDCVoltage() throws {
        _ = try device.identify()
        server.signal[.dcVoltage] = 4.19

        try device.send(SCPI.configure(.dcVoltage))
        let value = try XCTUnwrap(SCPIParse.number(device.query(SCPI.read)))
        XCTAssertEqual(value, 4.19, accuracy: 0.0001)
    }

    func testAutoRangePicksTheSmallestRangeThatFits() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setAutoRange(.dcVoltage, true))

        server.signal[.dcVoltage] = 0.05
        _ = device.query(SCPI.read)
        XCTAssertEqual(device.queryNumber(SCPI.rangeQuery(.dcVoltage))!, 0.1, accuracy: 1e-9)

        server.signal[.dcVoltage] = 7.5
        _ = device.query(SCPI.read)
        XCTAssertEqual(device.queryNumber(SCPI.rangeQuery(.dcVoltage))!, 10, accuracy: 1e-9)
    }

    func testFixedRangeOverloadsAboveFullScale() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setRange(.dcVoltage, 1))
        server.signal[.dcVoltage] = 4.19

        let reading = try XCTUnwrap(device.queryNumber(SCPI.read))
        XCTAssertTrue(SCPIParse.isOverload(reading))

        let status = QuestionableStatus(condition: try XCTUnwrap(SCPIParse.integer(device.query(SCPI.questionableCondition))))
        XCTAssertTrue(status.voltageOverload)
        XCTAssertEqual(status.labels, ["Voltage Overload"])
    }

    func testARangeRequestSnapsUpToTheNextRangeTheMeterHas() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setRange(.dcVoltage, 3))
        XCTAssertEqual(device.queryNumber(SCPI.rangeQuery(.dcVoltage))!, 10, accuracy: 1e-9)
    }

    func testEveryFunctionAnswersAndReportsItself() throws {
        _ = try device.identify()
        for function in MeasurementFunction.allCases {
            try device.send(SCPI.configure(function))
            let token = try XCTUnwrap(device.query(SCPI.functionQuery), "\(function) did not answer FUNC?")
            XCTAssertEqual(MeasurementFunction.from(queryToken: token), function)
            let reading = device.queryNumber(SCPI.read)
            XCTAssertNotNil(reading, "\(function) produced no reading")
        }
    }

    func testPeriodIsTheReciprocalOfFrequency() throws {
        _ = try device.identify()
        server.signal[.frequency] = 2000

        try device.send(SCPI.configure(.frequency))
        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.read)), 2000, accuracy: 0.01)

        try device.send(SCPI.configure(.period))
        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.read)), 0.0005, accuracy: 1e-8)
    }

    // MARK: - Bursts

    func testASampleCountBurstReturnsEveryReadingInOneResponse() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setSampleCount(20))

        let values = SCPIParse.numbers(device.query(SCPI.read))
        XCTAssertEqual(values.count, 20)
        XCTAssertTrue(values.allSatisfy { abs($0 - 4.19) < 0.001 })
    }

    func testBusTriggerNeedsInitiateThenTriggerThenFetch() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setSampleCount(4))
        try device.send(SCPI.setTriggerSource(.bus))

        try device.send(SCPI.initiate)
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.storedCountQuery)), 0, "nothing until *TRG")

        try device.send(SCPI.trigger)
        XCTAssertEqual(SCPIParse.numbers(device.query(SCPI.fetch)).count, 4)
    }

    func testAbortThrowsAwayAnArmedButUntriggeredBurst() throws {
        _ = try device.identify()
        try device.send(SCPI.setTriggerSource(.bus))
        try device.send(SCPI.initiate)
        try device.send(SCPI.abort)
        try device.send(SCPI.trigger)
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.storedCountQuery)), 0)
    }

    // MARK: - Integration time and resolution

    func testIntegrationTimeRoundTrips() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        for time in IntegrationTime.allCases {
            try device.send(SCPI.setIntegrationTime(.dcVoltage, time))
            let readBack = try XCTUnwrap(device.queryNumber(SCPI.integrationTimeQuery(.dcVoltage)))
            XCTAssertEqual(readBack, time.rawValue, accuracy: 1e-6)
        }
    }

    func testGateTimeRoundTripsOnTheCounterFunctions() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.frequency))
        for gate in GateTime.allCases {
            try device.send(SCPI.setAperture(.frequency, gate))
            XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.apertureQuery(.frequency))), gate.rawValue, accuracy: 1e-6)
        }
    }

    func testACBandwidthRoundTrips() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.acVoltage))
        try device.send(SCPI.setBandwidth(.slow))
        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.bandwidthQuery)), 3, accuracy: 1e-6)
    }

    // MARK: - Maths

    func testNullSubtractsTheOffset() throws {
        _ = try device.identify()
        server.signal[.dcVoltage] = 4.19
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setMathFunction("NULL"))
        try device.send(SCPI.setNullOffset(4.0))
        try device.send(SCPI.setMathState(true))

        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.read)), 0.19, accuracy: 0.0001)
    }

    func testDBmIsReferredToTheChosenLoad() throws {
        _ = try device.identify()
        // 0.7746 V into 600 Ω is 1 mW, which is 0 dBm by definition.
        server.signal[.dcVoltage] = (0.001 * 600).squareRoot()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setMathFunction("DBM"))
        try device.send(SCPI.setDBmReference(600))
        try device.send(SCPI.setMathState(true))

        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.read)), 0, accuracy: 0.01)
    }

    func testDecibelIsDBmMinusTheReferenceLevel() throws {
        _ = try device.identify()
        server.signal[.dcVoltage] = (0.001 * 600).squareRoot()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setDBmReference(600))
        try device.send(SCPI.setMathFunction("DB"))
        try device.send(SCPI.setDecibelReference(-10))
        try device.send(SCPI.setMathState(true))

        XCTAssertEqual(try XCTUnwrap(device.queryNumber(SCPI.read)), 10, accuracy: 0.01)
    }

    func testInstrumentStatisticsAccumulateAcrossReadings() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setMathFunction("AVER"))
        try device.send(SCPI.setMathState(true))

        server.signal[.dcVoltage] = 1
        _ = device.query(SCPI.read)
        server.signal[.dcVoltage] = 3
        _ = device.query(SCPI.read)

        let statistics = device.readInstrumentStatistics()
        XCTAssertEqual(statistics.minimum!, 1, accuracy: 0.001)
        XCTAssertEqual(statistics.maximum!, 3, accuracy: 0.001)
        XCTAssertEqual(statistics.average!, 2, accuracy: 0.001)
        XCTAssertEqual(statistics.count, 2)
    }

    func testLimitTestSetsTheQuestionableBits() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setMathFunction("LIM"))
        try device.send(SCPI.setLowerLimit(1))
        try device.send(SCPI.setUpperLimit(2))
        try device.send(SCPI.setMathState(true))

        server.signal[.dcVoltage] = 4.19
        _ = device.query(SCPI.read)
        var status = QuestionableStatus(condition: SCPIParse.integer(device.query(SCPI.questionableCondition))!)
        XCTAssertTrue(status.limitFailedHigh)
        XCTAssertFalse(status.limitFailedLow)

        server.signal[.dcVoltage] = 0.5
        _ = device.query(SCPI.read)
        status = QuestionableStatus(condition: SCPIParse.integer(device.query(SCPI.questionableCondition))!)
        XCTAssertTrue(status.limitFailedLow)
        XCTAssertFalse(status.limitFailedHigh)
    }

    // MARK: - Compound messages

    /// The whole point of the exercise: six questions, one round trip.
    func testACompoundMessageAnswersEveryQueryInOrder() throws {
        _ = try device.identify()
        server.signal[.dcVoltage] = 2.5
        try device.send(SCPI.configure(.dcVoltage))

        let answers = try XCTUnwrap(device.queryCompound([
            SCPI.read,
            SCPI.questionableCondition,
            SCPI.functionQuery,
            SCPI.rangeQuery(.dcVoltage),
        ]))

        XCTAssertEqual(answers.count, 4)
        XCTAssertEqual(SCPIParse.number(answers[0])!, 2.5, accuracy: 0.001)
        XCTAssertEqual(SCPIParse.integer(answers[1]), 0)
        XCTAssertEqual(MeasurementFunction.from(queryToken: answers[2]), .dcVoltage)
        XCTAssertEqual(SCPIParse.number(answers[3])!, 10, accuracy: 1e-9)
    }

    /// Subsequent headers are sent from the root, so a compound message does not
    /// depend on where the previous command left the subsystem path.
    func testCompoundHeadersAreRootedSoOrderDoesNotMatter() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))

        let answers = try XCTUnwrap(device.queryCompound([
            SCPI.integrationTimeQuery(.dcVoltage),
            SCPI.functionQuery,
            SCPI.bandwidthQuery,
        ]))
        XCTAssertEqual(SCPIParse.number(answers[0])!, 1, accuracy: 1e-9)
        XCTAssertEqual(MeasurementFunction.from(queryToken: answers[1]), .dcVoltage)
        XCTAssertEqual(SCPIParse.number(answers[2])!, 20, accuracy: 1e-9)
    }

    func testCompoundBurstsCarryEveryReadingAndTheStatusBehindThem() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.dcVoltage))
        try device.send(SCPI.setSampleCount(5))

        let answers = try XCTUnwrap(device.queryCompound([SCPI.read, SCPI.questionableCondition]))
        XCTAssertEqual(SCPIParse.numbers(answers[0]).count, 5,
                       "the burst's own commas must not be confused with the message's semicolons")
        XCTAssertEqual(SCPIParse.integer(answers[1]), 0)
    }

    /// A short reply means the meter did not understand; guessing which answer
    /// went missing would be worse than asking again one at a time.
    func testAMismatchedReplyIsRejectedRatherThanMisread() throws {
        _ = try device.identify()
        // SYSTem:VERSion? answers once; asking for two fields from one reply
        // must not be taken as success.
        XCTAssertNil(SCPIParse.compoundFields("1994.0", expected: 2))
        XCTAssertEqual(SCPIParse.compoundFields("a;b", expected: 2), ["a", "b"])
    }

    func testCompoundConfigurationReadBackMatchesTheSeparateOne() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.resistance))
        try device.send(SCPI.setRange(.resistance, 1e5))
        try device.send(SCPI.setIntegrationTime(.resistance, .slow))

        var combined = MeterConfiguration()
        combined.function = .resistance
        XCTAssertTrue(device.readConfiguration(into: &combined, compound: true))

        var separate = MeterConfiguration()
        separate.function = .resistance
        XCTAssertTrue(device.readConfiguration(into: &separate, compound: false))

        XCTAssertEqual(combined, separate)
        XCTAssertEqual(combined.range, 1e5)
        XCTAssertEqual(combined.integrationTime, .slow)
    }

    /// The sub-queries name a subsystem, so they are chosen before the answer to
    /// FUNCtion? is in. When the meter turns out to be on something else, the
    /// read repeats against the right subsystem rather than reporting values
    /// that were asked about the wrong one.
    func testAReadBackAimedAtTheWrongSubsystemRetriesAgainstTheRightOne() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.acVoltage))
        try device.send(SCPI.setRange(.acVoltage, 100))
        try device.send(SCPI.setBandwidth(.slow))

        var configuration = MeterConfiguration()   // still believes it is DC volts
        XCTAssertTrue(device.readConfiguration(into: &configuration, compound: true))

        XCTAssertEqual(configuration.function, .acVoltage)
        XCTAssertEqual(configuration.range, 100)
        XCTAssertEqual(configuration.bandwidth, .slow)
    }

    func testAQuotedSemicolonIsNotACommandSeparator() throws {
        _ = try device.identify()
        try device.send(SCPI.displayText("a;b"))
        _ = device.query(SCPI.errorQuery)
        XCTAssertEqual(server.simulatedMeter.displayText, "a;b")
    }

    // MARK: - Configuration read-back

    func testConfigurationIsReadBackFromTheMeter() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.resistance))
        try device.send(SCPI.setRange(.resistance, 1e5))
        try device.send(SCPI.setIntegrationTime(.resistance, .slow))

        var configuration = MeterConfiguration()
        device.readConfiguration(into: &configuration)

        XCTAssertEqual(configuration.function, .resistance)
        XCTAssertFalse(configuration.autoRange)
        XCTAssertEqual(configuration.range, 1e5)
        XCTAssertEqual(configuration.integrationTime, .slow)
    }

    func testApplyingAWholeConfigurationLandsWhereItWasAimed() throws {
        _ = try device.identify()

        var wanted = MeterConfiguration()
        wanted.function = .acVoltage
        wanted.autoRange = false
        wanted.range = 100
        wanted.bandwidth = .slow
        wanted.sampleCount = 5
        wanted.triggerSource = .bus
        try device.send(wanted.commands())

        var readBack = MeterConfiguration()
        device.readConfiguration(into: &readBack)
        XCTAssertEqual(readBack.function, .acVoltage)
        XCTAssertEqual(readBack.range, 100)
        XCTAssertEqual(readBack.bandwidth, .slow)
        XCTAssertEqual(SCPIParse.integer(device.query("SAMP:COUN?")), 5)
        XCTAssertEqual(device.query(SCPI.triggerSourceQuery), "BUS")
    }

    // MARK: - Housekeeping

    func testErrorQueueIsEmptyWhenNothingWentWrong() throws {
        _ = try device.identify()
        XCTAssertEqual(device.query(SCPI.errorQuery), "+0,\"No error\"")
    }

    func testUnknownCommandLandsInTheErrorQueue() throws {
        _ = try device.identify()
        try device.send("NOSUCH:COMMAND 1")
        XCTAssertEqual(device.query(SCPI.errorQuery), "-113,\"Undefined header\"")
    }

    func testResetReturnsTheMeterToItsPowerOnState() throws {
        _ = try device.identify()
        try device.send(SCPI.configure(.resistance))
        try device.send(SCPI.setSampleCount(10))
        try device.send(SCPI.reset)

        XCTAssertEqual(device.query(SCPI.functionQuery), "\"VOLT\"")
        XCTAssertEqual(SCPIParse.integer(device.query("SAMP:COUN?")), 1)
    }

    func testSelfTestPasses() throws {
        _ = try device.identify()
        XCTAssertEqual(SCPIParse.integer(device.query(SCPI.selfTest)), 0)
    }

    func testFrontPanelTextIsAccepted() throws {
        _ = try device.identify()
        try device.send(SCPI.displayText("Hello World!!!"))
        // A query round-trips through the simulator's reader thread, so once it
        // answers the preceding write-only command has certainly been handled.
        _ = device.query(SCPI.errorQuery)
        XCTAssertEqual(server.simulatedMeter.displayText, "Hello World!")

        try device.send(SCPI.displayTextClear)
        _ = device.query(SCPI.errorQuery)
        XCTAssertNil(server.simulatedMeter.displayText)
    }

    func testInterfaceClearDropsAnArmedBurst() throws {
        _ = try device.identify()
        try device.send(SCPI.setTriggerSource(.bus))
        try device.send(SCPI.initiate)
        try device.clearInterface()
        _ = device.query(SCPI.errorQuery)
        XCTAssertFalse(server.simulatedMeter.isInitiated)
    }

    func testReadTimesOutWhenNoAnswerIsComing() throws {
        _ = try device.identify()
        let started = Date()
        // A set command produces no response, so a bare read must give up rather
        // than block the polling worker forever.
        XCTAssertNil(device.query(SCPI.displayOn))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }
}
