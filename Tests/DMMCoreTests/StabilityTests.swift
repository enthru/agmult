import XCTest
@testable import DMMCore

/// Allan deviation and the drift fit, checked against series whose answers are
/// known in closed form rather than against a previous run of the same code.
final class StabilityTests: XCTestCase {

    private func readings(_ values: [Double], interval: TimeInterval = 1) -> [Reading] {
        let start = Date(timeIntervalSince1970: 0)
        return values.enumerated().map {
            Reading(index: $0.offset, timestamp: start.addingTimeInterval(Double($0.offset) * interval), value: $0.element)
        }
    }

    /// Deterministic white noise: no `Double.random`, so a failure means the
    /// code changed rather than the dice.
    private func whiteNoise(count: Int, amplitude: Double) -> [Double] {
        var state: UInt64 = 0x2545F4914F6CDD1D
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return (Double(state % 20_001) / 10_000.0 - 1) * amplitude
        }
    }

    // MARK: - Allan deviation

    /// A pure linear drift has a closed-form answer: σ(τ) = D·τ/√2. Both the
    /// magnitude and the slope of one in log-log fall out of it.
    func testLinearDriftGivesTheTextbookDeviation() throws {
        let rate = 1e-3                       // volts per second
        let interval = 0.5
        let values = (0..<4096).map { rate * Double($0) * interval }

        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(values, interval: interval)))

        for point in allan.points {
            let expected = rate * point.tau / 2.0.squareRoot()
            XCTAssertEqual(point.deviation, expected, accuracy: expected * 0.02,
                           "τ = \(point.tau) s")
        }
    }

    /// White noise averages down as τ^(−½): each doubling of the averaging time
    /// buys a factor of √2. This is the shape that says "keep averaging".
    ///
    /// The check is made over the well determined points only. Overlapping
    /// differences are not independent, so the longest τ of any record is built
    /// from a handful of degrees of freedom and scatters by tens of percent —
    /// which is a property of the estimator, not of the instrument, and is why
    /// the window draws those points but does not draw conclusions from them.
    func testWhiteNoiseAveragesDownAsTheSquareRoot() throws {
        let values = whiteNoise(count: 8192, amplitude: 1e-4)
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(values)))
        XCTAssertGreaterThan(allan.wellDetermined.count, 4)

        for (shorter, longer) in zip(allan.wellDetermined, allan.wellDetermined.dropFirst()) {
            let ratio = longer.deviation / shorter.deviation
            XCTAssertEqual(ratio, 1 / 2.0.squareRoot(), accuracy: 0.12,
                           "τ \(shorter.tau) s → \(longer.tau) s")
        }

        XCTAssertEqual(try XCTUnwrap(allan.logSlope), -0.5, accuracy: 0.08)
        XCTAssertEqual(allan.noiseDescription, "White noise — averaging still helps")
    }

    /// The other end of the same measurement: a drifting reference climbs as τ,
    /// and the window should say so rather than leave the user to read a slope.
    func testDriftIsNamedFromTheSlope() throws {
        let rate = 1e-3
        let values = (0..<4096).map { rate * Double($0) }
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(values)))

        XCTAssertEqual(try XCTUnwrap(allan.logSlope), 1, accuracy: 0.05)
        XCTAssertEqual(allan.noiseDescription, "Drift dominates — averaging is making it worse")
    }

    func testDegreesOfFreedomFallAsTheAveragingTimeGrows() throws {
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(whiteNoise(count: 4096, amplitude: 1))))
        let first = allan.points.first!
        let last = allan.points.last!
        XCTAssertGreaterThan(allan.degreesOfFreedom(for: first), allan.degreesOfFreedom(for: last))
        XCTAssertEqual(first.averagedReadings, 1)
        XCTAssertTrue(allan.wellDetermined.allSatisfy { allan.degreesOfFreedom(for: $0) >= 16 })
    }

    func testTausAreOctaveSpacedAndStopAtAQuarterOfTheRecord() throws {
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(whiteNoise(count: 1000, amplitude: 1))))
        XCTAssertEqual(allan.points.first?.tau, 1)
        for (shorter, longer) in zip(allan.points, allan.points.dropFirst()) {
            XCTAssertEqual(longer.tau, shorter.tau * 2, accuracy: 1e-9)
        }
        XCTAssertLessThanOrEqual(allan.points.last!.tau, 250)
        XCTAssertTrue(allan.points.allSatisfy { $0.pairs >= 5 })
    }

    func testTheSampleIntervalIsTakenFromTheTimestamps() throws {
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(whiteNoise(count: 512, amplitude: 1), interval: 0.25)))
        XCTAssertEqual(allan.sampleInterval, 0.25, accuracy: 1e-9)
        XCTAssertEqual(allan.points.first?.tau, 0.25)
        XCTAssertTrue(allan.samplingIsEvenEnough)
    }

    /// The estimator assumes evenly spaced readings. When they are not, the
    /// number is still produced but flagged, because a curve drawn from ragged
    /// sampling looks exactly as convincing as one drawn from good sampling.
    func testUnevenSamplingIsReported() throws {
        let start = Date(timeIntervalSince1970: 0)
        var moment = start
        var uneven: [Reading] = []
        for index in 0..<512 {
            moment = moment.addingTimeInterval(index % 2 == 0 ? 0.2 : 1.8)
            uneven.append(Reading(index: index, timestamp: moment, value: Double(index % 3)))
        }

        let allan = try XCTUnwrap(AllanDeviation.compute(readings: uneven))
        XCTAssertGreaterThan(allan.intervalJitter, AllanDeviation.jitterWarningThreshold)
        XCTAssertFalse(allan.samplingIsEvenEnough)
    }

    func testTooShortARecordProducesNothingRatherThanNonsense() {
        XCTAssertNil(AllanDeviation.compute(readings: readings([1, 2, 3])))
        XCTAssertNil(AllanDeviation.compute(readings: []))
    }

    /// White noise plus a drift has a minimum where the two cross — the point of
    /// the whole exercise, since it says how long averaging is worth doing.
    func testTheOptimumAveragingTimeSitsWhereDriftTakesOver() throws {
        let rate = 2e-6
        let noise = whiteNoise(count: 8192, amplitude: 1e-3)
        let values = noise.enumerated().map { $0.element + rate * Double($0.offset) }

        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(values)))
        let optimum = try XCTUnwrap(allan.optimumAveragingTime)

        XCTAssertGreaterThan(optimum.tau, allan.points.first!.tau, "the floor is not at the shortest τ")
        XCTAssertLessThan(optimum.tau, allan.points.last!.tau, "nor at the longest")
    }

    func testUncertaintyShrinksWithTheNumberOfPairs() throws {
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(whiteNoise(count: 4096, amplitude: 1e-4))))
        let first = allan.points.first!
        XCTAssertEqual(first.uncertainty, first.deviation / Double(first.pairs).squareRoot(), accuracy: 1e-15)
        XCTAssertGreaterThan(allan.points.last!.uncertainty / allan.points.last!.deviation,
                             first.uncertainty / first.deviation,
                             "the longest τ is the least trustworthy")
    }

    func testCSVCarriesEveryPoint() throws {
        let allan = try XCTUnwrap(AllanDeviation.compute(readings: readings(whiteNoise(count: 512, amplitude: 1))))
        let lines = allan.csv(unit: "V").split(separator: "\n")
        XCTAssertEqual(lines.count, allan.points.count + 1)
        XCTAssertEqual(lines[0], "Tau (s),Allan deviation (V),Pairs,Uncertainty (V)")
    }

    // MARK: - Drift

    func testFitRecoversAKnownSlope() throws {
        let rate = 1e-6                       // volts per second — 3.6 mV/hour
        let values = (0..<600).map { 4.19 + rate * Double($0) }

        let fit = try XCTUnwrap(LinearFit.over(readings(values)))
        XCTAssertEqual(fit.slope, rate, accuracy: rate * 1e-9)
        XCTAssertEqual(fit.slopePerHour, rate * 3600, accuracy: 1e-12)
        XCTAssertEqual(fit.intercept, 4.19, accuracy: 1e-9)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-12)
        XCTAssertEqual(fit.span, 599, accuracy: 1e-9)
        XCTAssertEqual(fit.totalChange, rate * 599, accuracy: 1e-12)
    }

    /// The whole point of fitting around the means: readings at 4.19 V that
    /// differ in the sixth digit are where a one-pass sum of squares gives up.
    func testFitSurvivesASlopeHiddenInTheSixthDigit() throws {
        let rate = 1e-9
        let values = (0..<5000).map { 4.19 + rate * Double($0) }

        let fit = try XCTUnwrap(LinearFit.over(readings(values)))
        XCTAssertEqual(fit.slope, rate, accuracy: rate * 1e-6)
    }

    func testAFlatSeriesHasNoSlopeAndIsNotUndefined() throws {
        let fit = try XCTUnwrap(LinearFit.over(readings(Array(repeating: 4.19, count: 100))))
        XCTAssertEqual(fit.slope, 0, accuracy: 1e-15)
        XCTAssertEqual(fit.rSquared, 1)
    }

    func testNoisyDataStillGivesTheRightSlopeWithALowerRSquared() throws {
        let rate = 1e-5
        let noise = whiteNoise(count: 2000, amplitude: 1e-3)
        let values = noise.enumerated().map { 4.19 + rate * Double($0.offset) + $0.element }

        let fit = try XCTUnwrap(LinearFit.over(readings(values)))
        XCTAssertEqual(fit.slope, rate, accuracy: rate * 0.05)
        XCTAssertLessThan(fit.rSquared, 1)
        XCTAssertGreaterThan(fit.rSquared, 0.9)
    }

    func testFitNeedsTwoPointsAndSomeSpread() {
        XCTAssertNil(LinearFit.over(readings([1])))
        XCTAssertNil(LinearFit.over([]))
    }

    // MARK: - Median filter

    func testMedianIgnoresASpikeThatAMeanWouldSmear() {
        let source = readings([1, 1, 42, 1, 1])
        let median = WaveformRecipe(operation: .medianFilter, parameterA: 3).apply(to: source).map(\.value)
        let mean = WaveformRecipe(operation: .movingAverage, parameterA: 3).apply(to: source).map(\.value)

        XCTAssertEqual(median, [1, 1, 1])
        XCTAssertEqual(mean, [44.0 / 3, 44.0 / 3, 44.0 / 3])
    }

    func testMedianOfAnEvenWindowAveragesTheMiddlePair() {
        let values = WaveformRecipe(operation: .medianFilter, parameterA: 4).apply(to: readings([1, 2, 3, 10])).map(\.value)
        XCTAssertEqual(values, [2.5])
    }

    func testMedianKeepsTheUnitAndNeedsAFullWindow() {
        XCTAssertEqual(WaveformOperation.medianFilter.unit(from: "V"), "V")
        XCTAssertTrue(WaveformRecipe(operation: .medianFilter, parameterA: 9).apply(to: readings([1, 2])).isEmpty)
    }
}
