import XCTest
@testable import DMMCore

/// The derived-series transforms. These run over captured readings rather than
/// inside the meter, so they are pure functions and can be checked exactly.
final class MathWaveformTests: XCTestCase {

    private func readings(_ values: [Double], interval: TimeInterval = 1) -> [Reading] {
        let start = Date(timeIntervalSince1970: 0)
        return values.enumerated().map {
            Reading(index: $0.offset, timestamp: start.addingTimeInterval(Double($0.offset) * interval), value: $0.element)
        }
    }

    private func values(_ operation: WaveformOperation,
                        _ input: [Double],
                        a: Double? = nil,
                        b: Double? = nil,
                        interval: TimeInterval = 1) -> [Double] {
        WaveformRecipe(operation: operation, parameterA: a, parameterB: b)
            .apply(to: readings(input, interval: interval))
            .map(\.value)
    }

    func testScaleAppliesGainThenOffset() {
        XCTAssertEqual(values(.scale, [1, 2, 3], a: 2, b: 10), [12, 14, 16])
    }

    func testAbsoluteAndSquare() {
        XCTAssertEqual(values(.absolute, [-1, 2, -3]), [1, 2, 3])
        XCTAssertEqual(values(.square, [-2, 3]), [4, 9])
    }

    /// A reading that happens to land exactly on zero has no reciprocal;
    /// dropping the point beats plotting an infinity.
    func testReciprocalDropsZeroReadings() {
        XCTAssertEqual(values(.reciprocal, [2, 0, 4]), [0.5, 0.25])
    }

    func testMovingAverageStartsOnceTheWindowIsFull() {
        // Windows of three over 1…5: no output until the third reading.
        XCTAssertEqual(values(.movingAverage, [1, 2, 3, 4, 5], a: 3), [2, 3, 4])
    }

    func testMovingAverageOfATooShortSeriesIsEmpty() {
        XCTAssertTrue(values(.movingAverage, [1, 2], a: 8).isEmpty)
    }

    func testDeltaIsTheDifferenceBetweenConsecutiveReadings() {
        XCTAssertEqual(values(.delta, [1, 4, 9, 16]), [3, 5, 7])
    }

    func testDerivativeDividesByTheTimeActuallyElapsed() {
        // Half-second spacing doubles the slope compared with one-second spacing.
        XCTAssertEqual(values(.derivative, [0, 1, 2], interval: 1), [1, 1])
        XCTAssertEqual(values(.derivative, [0, 1, 2], interval: 0.5), [2, 2])
    }

    /// Trapezoidal, so a ramp integrates exactly instead of lagging half a step.
    func testIntegralOfARampIsExact() {
        let result = values(.integral, [0, 1, 2, 3])
        XCTAssertEqual(result, [0, 0.5, 2, 4.5])
    }

    func testDeviationFromMeanCentresTheSeries() {
        let result = values(.deviationFromMean, [1, 2, 3])
        XCTAssertEqual(result, [-1, 0, 1])
    }

    func testPartsPerMillionAgainstAReference() {
        let result = values(.partsPerMillion, [1.000001], a: 1)
        XCTAssertEqual(result[0], 1, accuracy: 1e-6)
    }

    func testDecibelsAgainstAReference() {
        let result = values(.decibel, [10], a: 1)
        XCTAssertEqual(result[0], 20, accuracy: 1e-9)
    }

    func testPowerIntoALoad() {
        // 5 V across 50 Ω is half a watt.
        XCTAssertEqual(values(.power, [5], a: 50), [0.5])
    }

    /// The filter uses the interval that actually elapsed, so an uneven sample
    /// rate does not quietly move the corner frequency.
    func testLowPassApproachesTheStepAtTheRateItsTimeConstantPromises() {
        let result = values(.lowPass, [0, 1, 1, 1, 1], a: 1, interval: 1)
        XCTAssertEqual(result[0], 0)
        // One time constant of a unit step is 1 − e⁻¹.
        XCTAssertEqual(result[1], 1 - exp(-1.0), accuracy: 1e-9)
        XCTAssertGreaterThan(result[4], 0.9)
    }

    func testEveryOperationSurvivesAnEmptyOrSingleSample() {
        for operation in WaveformOperation.allCases {
            let recipe = WaveformRecipe(operation: operation)
            XCTAssertTrue(recipe.apply(to: []).isEmpty, "\(operation) on nothing")
            _ = recipe.apply(to: readings([1]))
        }
    }

    func testUnitsFollowTheTransform() {
        XCTAssertEqual(WaveformOperation.movingAverage.unit(from: "V"), "V")
        XCTAssertEqual(WaveformOperation.derivative.unit(from: "V"), "V/s")
        XCTAssertEqual(WaveformOperation.integral.unit(from: "A"), "A·s")
        XCTAssertEqual(WaveformOperation.square.unit(from: "V"), "V²")
        XCTAssertEqual(WaveformOperation.reciprocal.unit(from: "Ω"), "1/Ω")
        XCTAssertEqual(WaveformOperation.power.unit(from: "V"), "W")
        XCTAssertEqual(WaveformOperation.decibel.unit(from: "V"), "dB")
        XCTAssertEqual(WaveformOperation.partsPerMillion.unit(from: "V"), "ppm")
    }

    /// Indices and timestamps carry over from the readings that produced each
    /// point, so a derived waveform still lines up with the original.
    func testTransformsKeepTheSourceIndicesAndTimestamps() {
        let source = readings([1, 2, 3, 4])
        let result = WaveformRecipe(operation: .movingAverage, parameterA: 2).apply(to: source)
        XCTAssertEqual(result.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.map(\.timestamp), Array(source.map(\.timestamp).dropFirst()))
    }

    /// Maths on maths: a moving average of a derivative is a smoothed slope.
    func testTransformsChain() {
        let derivative = WaveformRecipe(operation: .derivative).apply(to: readings([0, 1, 4, 9, 16]))
        let smoothed = WaveformRecipe(operation: .movingAverage, parameterA: 2).apply(to: derivative)
        XCTAssertEqual(derivative.map(\.value), [1, 3, 5, 7])
        XCTAssertEqual(smoothed.map(\.value), [2, 4, 6])
    }
}
