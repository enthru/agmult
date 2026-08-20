import XCTest
@testable import DMMCore

/// The wire protocol, checked without a serial port in sight.
final class ProtocolTests: XCTestCase {

    // MARK: - The ratio function

    func testTheRatioIsSelectedByItsOwnNameButSetUpThroughDCVolts() {
        // The one function whose settings do not live under its own name: the
        // meter has a single VOLTage:DC node and the ratio runs on it.
        XCTAssertEqual(SCPI.configure(.dcRatio), "CONF:VOLT:DC:RAT")
        XCTAssertEqual(SCPI.selectFunction(.dcRatio), "FUNC \"VOLT:DC:RAT\"")
        XCTAssertEqual(SCPI.integrationTimeQuery(.dcRatio), "VOLT:DC:NPLC?")
        XCTAssertEqual(SCPI.rangeQuery(.dcRatio), "VOLT:DC:RANG?")
        XCTAssertEqual(SCPI.setRange(.dcRatio, 10), "VOLT:DC:RANG 10")
        XCTAssertEqual(MeasurementFunction.dcRatio.parameterFunction, .dcVoltage)
    }

    func testTheRatioIsRecognisedWhicheverWayTheMeterAbbreviatesIt() {
        // The manual says only that FUNCtion? "returns a quoted string", so each
        // plausible spelling is accepted rather than guessed at.
        for token in ["VOLT:RAT", "VOLT:DC:RAT", "\"VOLT:RAT\"", "volt:dc:ratio"] {
            XCTAssertEqual(MeasurementFunction.from(queryToken: token), .dcRatio, "token \(token)")
        }
        XCTAssertEqual(MeasurementFunction.from(queryToken: "VOLT"), .dcVoltage)
        XCTAssertEqual(MeasurementFunction.from(queryToken: "VOLT:DC"), .dcVoltage)
        XCTAssertEqual(MeasurementFunction.from(queryToken: "VOLT:AC"), .acVoltage)
    }

    func testTheRatioCarriesNoUnitButStillHasAVoltageRange() {
        XCTAssertEqual(MeasurementFunction.dcRatio.unit, "")
        XCTAssertEqual(MeasurementFunction.dcRatio.rangeUnit, "V")
        XCTAssertEqual(MeasurementFunction.dcRatio.ranges, MeasurementFunction.dcVoltage.ranges)
        XCTAssertTrue(MeasurementFunction.dcRatio.usesIntegrationTime)
    }

    // MARK: - The error queue

    func testAnErrorCodeIsReadFromTheFirstFieldNotTheWholeEntry() {
        XCTAssertEqual(SCPIParse.errorCode("+0,\"No error\""), 0)
        XCTAssertEqual(SCPIParse.errorCode("-113,\"Undefined header\""), -113)
        XCTAssertEqual(SCPIParse.errorCode("-350,\"Queue overflow\""), -350)
        // The entry as a whole is not a number, which is why `number()` is not
        // the tool for this job.
        XCTAssertNil(SCPIParse.number("-113,\"Undefined header\""))
    }

    func testOnlyTheNoErrorEntryCountsAsAnEmptyQueue() {
        XCTAssertTrue(SCPIParse.isQueueEmpty("+0,\"No error\""))
        XCTAssertFalse(SCPIParse.isQueueEmpty("-113,\"Undefined header\""))
        // A reply nobody can parse stops the drain rather than spinning it.
        XCTAssertTrue(SCPIParse.isQueueEmpty("gibberish"))
        XCTAssertTrue(SCPIParse.isQueueEmpty(nil))
    }

    func testTheBurstCeilingIsTheMetersOwnMemory() {
        XCTAssertEqual(MeterConfiguration.sampleCountChoices.last, 512)
        XCTAssertTrue(MeterConfiguration.sampleCountChoices.allSatisfy { $0 >= 1 })
        XCTAssertEqual(SCPI.setSampleCount(512), "SAMP:COUN 512")
    }

    func testCalibrationSummaryReadsAsASentenceOrNotAtAll() {
        XCTAssertEqual(CalibrationInfo(count: 42, message: "CAL 2-1-96").summary,
                       "Calibrated 42 times — \"CAL 2-1-96\"")
        XCTAssertEqual(CalibrationInfo(count: 42, message: nil).summary, "Calibrated 42 times")
        XCTAssertNil(CalibrationInfo(count: nil, message: nil).summary)
        XCTAssertTrue(CalibrationInfo(count: nil, message: nil).isEmpty)
    }

    // MARK: - Command spelling

    func testCommandsAreSpelledTheWayTheMeterExpects() {
        XCTAssertEqual(SCPI.configure(.dcVoltage), "CONF:VOLT:DC")
        XCTAssertEqual(SCPI.configure(.resistance4Wire), "CONF:FRES")
        XCTAssertEqual(SCPI.selectFunction(.acCurrent), "FUNC \"CURR:AC\"")
        XCTAssertEqual(SCPI.setRange(.dcVoltage, 10), "VOLT:DC:RANG 10")
        XCTAssertEqual(SCPI.setAutoRange(.resistance, true), "RES:RANG:AUTO ON")
        XCTAssertEqual(SCPI.setIntegrationTime(.dcVoltage, .fastest), "VOLT:DC:NPLC 0.02")
        XCTAssertEqual(SCPI.setAperture(.frequency, .s1), "FREQ:APER 1")
        XCTAssertEqual(SCPI.setBandwidth(.slow), "DET:BAND 3")
        XCTAssertEqual(SCPI.setSampleCount(50), "SAMP:COUN 50")
        XCTAssertEqual(SCPI.setTriggerSource(.bus), "TRIG:SOUR BUS")
    }

    /// The counter functions hang their range off a VOLTage node, because it
    /// describes the input rather than the reading.
    func testCounterFunctionsRangeTheirInputNotTheirReading() {
        XCTAssertEqual(SCPI.setRange(.frequency, 10), "FREQ:VOLT:RANG 10")
        XCTAssertEqual(SCPI.autoRangeQuery(.period), "PER:VOLT:RANG:AUTO?")
    }

    func testNumbersAreFormattedWithAPeriodWhateverTheLocale() {
        XCTAssertEqual(SCPI.format(0.02), "0.02")
        XCTAssertEqual(SCPI.format(1e-6), "1E-06")
        XCTAssertEqual(SCPI.format(-4.19), "-4.19")
    }

    func testDisplayTextIsQuotedAndClipped() {
        XCTAssertEqual(SCPI.displayText("Hello"), "DISP:TEXT \"Hello\"")
        XCTAssertEqual(SCPI.displayText("This is far too long"), "DISP:TEXT \"This is far \"")
        XCTAssertEqual(SCPI.displayText("say \"hi\""), "DISP:TEXT \"say  hi \"")
    }

    // MARK: - Parsing

    func testParsesTheMetersNumberFormat() {
        XCTAssertEqual(SCPIParse.number("+4.19000000E+00")!, 4.19, accuracy: 1e-9)
        XCTAssertEqual(SCPIParse.number(" -1.00000000E-03 ")!, -0.001, accuracy: 1e-12)
        XCTAssertNil(SCPIParse.number("nonsense"))
        XCTAssertNil(SCPIParse.number(nil))
        XCTAssertNil(SCPIParse.number(""))
    }

    func testSplitsABurstIntoItsReadings() {
        let response = "+1.00000000E+00,+2.00000000E+00,+3.00000000E+00"
        XCTAssertEqual(SCPIParse.numbers(response), [1, 2, 3])
        XCTAssertEqual(SCPIParse.numbers(nil), [])
    }

    func testRecognisesTheOverloadSentinel() {
        XCTAssertTrue(SCPIParse.isOverload(9.9e37))
        XCTAssertTrue(SCPIParse.isOverload(-9.9e37))
        XCTAssertFalse(SCPIParse.isOverload(1000))
    }

    func testReadsBooleansInEveryFormTheMeterUses() {
        XCTAssertEqual(SCPIParse.boolean("1"), true)
        XCTAssertEqual(SCPIParse.boolean("+1"), true)
        XCTAssertEqual(SCPIParse.boolean("ON"), true)
        XCTAssertEqual(SCPIParse.boolean("0"), false)
        XCTAssertEqual(SCPIParse.boolean("OFF"), false)
        XCTAssertNil(SCPIParse.boolean("maybe"))
    }

    func testSnapsAReadBackRangeToANominalOne() {
        XCTAssertEqual(SCPIParse.nearestRange(9.99999, in: MeasurementFunction.dcVoltage.ranges), 10)
        XCTAssertEqual(SCPIParse.nearestRange(0.1000001, in: MeasurementFunction.dcVoltage.ranges), 0.1)
        XCTAssertNil(SCPIParse.nearestRange(.nan, in: MeasurementFunction.dcVoltage.ranges))
    }

    // MARK: - Functions

    func testEveryFunctionRoundTripsThroughItsQueryToken() {
        for function in MeasurementFunction.allCases {
            XCTAssertEqual(MeasurementFunction.from(queryToken: function.queryToken), function)
            XCTAssertEqual(MeasurementFunction.from(queryToken: "\"\(function.queryToken)\""), function)
        }
    }

    /// The meter is asymmetric here and it catches people out: you select DC
    /// volts with "VOLTage:DC" but it answers "VOLT".
    func testDCFunctionsReportThemselvesWithoutTheDCSuffix() {
        XCTAssertEqual(MeasurementFunction.dcVoltage.queryToken, "VOLT")
        XCTAssertEqual(MeasurementFunction.dcVoltage.scpiRoot, "VOLT:DC")
        XCTAssertEqual(MeasurementFunction.dcCurrent.queryToken, "CURR")
        XCTAssertEqual(MeasurementFunction.acVoltage.queryToken, "VOLT:AC")
    }

    func testFunctionCapabilitiesMatchTheInstrument() {
        XCTAssertTrue(MeasurementFunction.dcVoltage.usesIntegrationTime)
        XCTAssertFalse(MeasurementFunction.acVoltage.usesIntegrationTime)
        XCTAssertTrue(MeasurementFunction.acVoltage.usesBandwidth)
        XCTAssertTrue(MeasurementFunction.frequency.usesAperture)
        XCTAssertTrue(MeasurementFunction.dcVoltage.usesInputImpedance)
        XCTAssertFalse(MeasurementFunction.resistance.usesInputImpedance)
        XCTAssertFalse(MeasurementFunction.continuity.hasSelectableRange)
        XCTAssertFalse(MeasurementFunction.diode.hasSelectableRange)
    }

    // MARK: - Status

    func testQuestionableStatusIsDecodedBitByBit() {
        XCTAssertTrue(QuestionableStatus(condition: 0).isClear)

        let overload = QuestionableStatus(condition: 0x0001)
        XCTAssertTrue(overload.voltageOverload)
        XCTAssertTrue(overload.isOverload)
        XCTAssertEqual(overload.labels, ["Voltage Overload"])

        // A combined trip must report both, not fall through to "unknown".
        let both = QuestionableStatus(condition: 0x0800 | 0x0200)
        XCTAssertTrue(both.resistanceOverload)
        XCTAssertTrue(both.limitFailedLow)
        XCTAssertEqual(both.labels, ["Ohms Overload", "Limit Failed LO"])

        let unrecognised = QuestionableStatus(condition: 0x0040)
        XCTAssertEqual(unrecognised.labels, ["Questionable (64)"])
    }

    // MARK: - Identity

    func testParsesTheIdentificationString() {
        let identity = DeviceIdentity.parse("HEWLETT-PACKARD,34401A,0,11-5-2")
        XCTAssertEqual(identity.manufacturer, "HEWLETT-PACKARD")
        XCTAssertEqual(identity.model, "HP34401A")
        XCTAssertEqual(identity.firmware, "11-5-2")
        XCTAssertTrue(identity.isMultimeter)
    }

    /// Agilent and Keysight units answer with their own name; prefixing "HP" to
    /// a model that already spells it out would read oddly.
    func testDoesNotPrefixHPOntoAnAgilentOrKeysightMeter() {
        XCTAssertEqual(DeviceIdentity.parse("Agilent Technologies,34401A,0,11-5-2").model, "34401A")
        XCTAssertEqual(DeviceIdentity.parse("Keysight Technologies,34401A,MY123,2-2-1").model, "34401A")
    }

    func testRecognisesSomethingThatIsNotAMultimeter() {
        XCTAssertFalse(DeviceIdentity.parse("HEWLETT-PACKARD,6632B,0,A.01.04").isMultimeter)
    }

    // MARK: - Configuration

    func testConfigurationProducesTheCommandsItPromises() {
        var configuration = MeterConfiguration()
        configuration.function = .dcVoltage
        configuration.autoRange = false
        configuration.range = 10
        configuration.integrationTime = .slow
        configuration.autoZero = .off
        configuration.sampleCount = 20

        let commands = configuration.commands()
        XCTAssertEqual(commands.first, "CONF:VOLT:DC", "CONFigure must come first — it resets the rest")
        XCTAssertTrue(commands.contains("VOLT:DC:RANG:AUTO OFF"))
        XCTAssertTrue(commands.contains("VOLT:DC:RANG 10"))
        XCTAssertTrue(commands.contains("VOLT:DC:NPLC 10"))
        XCTAssertTrue(commands.contains("ZERO:AUTO OFF"))
        XCTAssertTrue(commands.contains("SAMP:COUN 20"))
    }

    func testACConfigurationSendsBandwidthAndNotIntegrationTime() {
        var configuration = MeterConfiguration()
        configuration.function = .acVoltage
        configuration.bandwidth = .fast

        let commands = configuration.commands()
        XCTAssertTrue(commands.contains("DET:BAND 200"))
        XCTAssertFalse(commands.contains { $0.contains("NPLC") })
        XCTAssertFalse(commands.contains { $0.contains("ZERO:AUTO") })
    }

    func testDigitsFollowTheResolutionSetting() {
        var configuration = MeterConfiguration()
        configuration.integrationTime = .fastest
        XCTAssertEqual(configuration.digits, 4)
        configuration.integrationTime = .fast
        XCTAssertEqual(configuration.digits, 5)
        configuration.integrationTime = .normal
        XCTAssertEqual(configuration.digits, 6)

        configuration.function = .frequency
        configuration.gateTime = .ms10
        XCTAssertEqual(configuration.digits, 4)
    }

    /// A burst has to be predicted before it is waited for, or a legitimately
    /// slow acquisition looks like a dead meter.
    func testBurstDurationGrowsWithIntegrationTimeAndSampleCount() {
        var configuration = MeterConfiguration()
        configuration.integrationTime = .normal
        configuration.autoZero = .off
        configuration.sampleCount = 10
        // 10 readings × 1 PLC at 50 Hz is 200 ms of measuring.
        XCTAssertEqual(configuration.estimatedBurstDuration(lineFrequency: 50), 0.21, accuracy: 0.02)

        configuration.autoZero = .on
        XCTAssertEqual(configuration.estimatedBurstDuration(lineFrequency: 50), 0.41, accuracy: 0.02)
    }

    func testMathCommandsCarryTheirParameters() {
        var math = MathConfiguration()
        math.function = .dBm
        math.dBmReference = 50
        XCTAssertEqual(math.commands(), ["CALC:FUNC DBM", "CALC:DBM:REF 50", "CALC:STAT ON"])

        math.function = .none
        XCTAssertEqual(math.commands(), ["CALC:STAT OFF"])

        math.function = .limit
        math.lowerLimit = -1.5
        math.upperLimit = 2.5
        XCTAssertEqual(math.commands(), ["CALC:FUNC LIM", "CALC:LIM:LOW -1.5", "CALC:LIM:UPP 2.5", "CALC:STAT ON"])
    }

    func testMathChangesTheUnitOnlyWhereItShould() {
        XCTAssertEqual(MathFunction.none.unit(for: .dcVoltage), "V")
        XCTAssertEqual(MathFunction.null.unit(for: .dcVoltage), "V")
        XCTAssertEqual(MathFunction.decibel.unit(for: .dcVoltage), "dB")
        XCTAssertEqual(MathFunction.dBm.unit(for: .acVoltage), "dBm")
        XCTAssertEqual(MathFunction.statistics.unit(for: .resistance), "Ω")
    }

    // MARK: - Burst timestamps

    /// The meter does not stamp its readings and a burst arrives in one
    /// response; stacking them all on one instant would make the rate look wrong.
    func testBurstTimestampsAreSpreadAcrossTheAcquisition() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(1)

        let stamps = DMMWorker.timestamps(count: 4, from: start, to: end)
        XCTAssertEqual(stamps.count, 4)
        XCTAssertEqual(stamps[0].timeIntervalSince(start), 0.25, accuracy: 1e-9)
        XCTAssertEqual(stamps[3], end)

        XCTAssertEqual(DMMWorker.timestamps(count: 1, from: start, to: end), [end])
        XCTAssertTrue(DMMWorker.timestamps(count: 0, from: start, to: end).isEmpty)
    }
}
