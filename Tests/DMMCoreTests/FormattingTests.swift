import XCTest
@testable import DMMCore

/// Display formatting, which is where a meter application either looks like an
/// instrument or looks like a spreadsheet.
final class FormattingTests: XCTestCase {

    /// The prefix comes from the range, not the value, so a reading drifting
    /// around zero does not flip between µV and mV several times a second.
    func testTheRangeChoosesThePrefix() {
        XCTAssertEqual(Format.reading(0.0419, unit: "V", range: 0.1, digits: 6), "41.9000 mV")
        XCTAssertEqual(Format.reading(0.0419, unit: "V", range: 1, digits: 6), "0.041900 V")
    }

    func testDecimalsComeFromTheResolution() {
        XCTAssertEqual(Format.reading(4.19, unit: "V", range: 10, digits: 6), "4.19000 V")
        XCTAssertEqual(Format.reading(4.19, unit: "V", range: 10, digits: 5), "4.1900 V")
        XCTAssertEqual(Format.reading(4.19, unit: "V", range: 10, digits: 4), "4.190 V")
    }

    /// The 1000 V range reads 1000.000 V on the meter's own display, never
    /// 1.000000 kV — volts stop at plain V.
    func testVoltsNeverBecomeKilovolts() {
        XCTAssertEqual(Format.reading(1000.5, unit: "V", range: 1000, digits: 6), "1000.500 V")
        XCTAssertEqual(Format.range(1000, unit: "V"), "1000 V")
    }

    func testResistanceUsesKiloAndMega() {
        XCTAssertEqual(Format.reading(1234.5, unit: "Ω", range: 1e4, digits: 6), "1.23450 kΩ")
        XCTAssertEqual(Format.reading(55.5, unit: "Ω", range: 100, digits: 6), "55.5000 Ω")
        XCTAssertEqual(Format.range(1e8, unit: "Ω"), "100 MΩ")
        XCTAssertEqual(Format.range(1e3, unit: "Ω"), "1 kΩ")
    }

    /// dB and dBm are logarithmic: no range to scale against, and a prefix would
    /// be meaningless.
    func testDecibelsGetNoPrefix() {
        XCTAssertEqual(Format.reading(-13.456, unit: "dBm", range: nil, digits: 6), "-13.456 dBm")
        XCTAssertEqual(Format.reading(0.001, unit: "dB", range: nil, digits: 6), "0.001 dB")
    }

    /// With no range to key off, the value's own magnitude sets the prefix and
    /// the reading gets the full six and a half digits.
    func testFallsBackToTheValueWhenTheRangeIsUnknown() {
        XCTAssertEqual(Format.reading(0.0419, unit: "V", range: nil, digits: 6), "41.90000 mV")
    }

    func testEngineeringNotationForStatisticsAndAxes() {
        XCTAssertEqual(Format.engineering(0.0000123, unit: "V"), "12.3000 µV")
        XCTAssertEqual(Format.engineering(1500, unit: "Hz"), "1.50000 kHz")
        XCTAssertEqual(Format.engineering(0, unit: "V"), "0.00000 V")
        XCTAssertEqual(Format.engineering(.nan, unit: "V"), "—")
    }

    func testExponentSelectionSurvivesTheAwkwardPowersOfTen() {
        XCTAssertEqual(Format.exponent(forMagnitude: 0.1, unit: "V"), -3)
        XCTAssertEqual(Format.exponent(forMagnitude: 0.001, unit: "V"), -3)
        XCTAssertEqual(Format.exponent(forMagnitude: 1, unit: "V"), 0)
        XCTAssertEqual(Format.exponent(forMagnitude: 1000, unit: "V"), 0, "clamped: volts have no kilo")
        XCTAssertEqual(Format.exponent(forMagnitude: 1000, unit: "Ω"), 3)
        XCTAssertEqual(Format.exponent(forMagnitude: 1e8, unit: "Ω"), 6)
    }

    func testRoundingIsHalfAwayFromZero() {
        XCTAssertEqual(Format.number(2.5, 0), "3")
        XCTAssertEqual(Format.number(-2.5, 0), "-3")
        XCTAssertEqual(Format.number(0.12345, 3), "0.123")
    }

    func testDurationForTheStatusBar() {
        XCTAssertEqual(Format.duration(0), "00:00:00")
        XCTAssertEqual(Format.duration(3661), "01:01:01")
        XCTAssertEqual(Format.duration(86_399), "23:59:59")
    }

    func testScientificOutputForLogFiles() {
        XCTAssertEqual(Format.scientific(4.19), "+4.19000000E+00")
        XCTAssertEqual(Format.scientific(-0.001), "-1.00000000E-03")
    }

    @MainActor
    func testSpokenReadingsSayUnitsInWords() {
        let announcer = SpeechAnnouncer()
        XCTAssertEqual(announcer.spoken(value: 4.19, unit: "V"), "4.190 volts")
        XCTAssertEqual(announcer.spoken(value: 0.0752, unit: "A"), "75.20 milliamps")
        XCTAssertEqual(announcer.spoken(value: 1500, unit: "Hz"), "1.500 kilohertz")
        XCTAssertEqual(announcer.spoken(value: 55.5, unit: "Ω"), "55.50 ohms")
    }
}
