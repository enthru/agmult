import Foundation

/// Overlapping Allan deviation.
///
/// The standard deviation of a long record answers the wrong question. It tells
/// you how far the readings spread around their own mean, which for anything
/// that drifts grows without limit the longer you watch. What you actually want
/// to know about a voltage reference — or about the meter itself — is how much
/// the *average* moves when you average for one second, or ten, or a thousand.
/// That is what this measures, and it is the reason a 34401A gets left running
/// overnight in the first place.
///
/// The shape of the curve names the noise: falling as τ^(−½) is white noise and
/// averaging helps; flat is flicker and averaging has stopped helping; rising as
/// τ is drift and averaging is now actively hurting. The minimum is how long it
/// is worth averaging for.
public struct AllanDeviation: Sendable {

    public struct Point: Identifiable, Sendable, Equatable {
        /// Averaging time, in seconds.
        public let tau: TimeInterval
        /// Deviation at that averaging time, in the reading's own unit.
        public let deviation: Double
        /// Overlapping second differences that went into it.
        public let pairs: Int
        /// Readings averaged together for this τ — the m of τ = m·τ₀.
        public let averagedReadings: Int

        public var id: TimeInterval { tau }

        /// A rough 1σ error bar. The proper expression needs equivalent degrees
        /// of freedom, which depend on the noise type you have not identified
        /// yet; 1/√pairs is the usual quick approximation and is honest enough
        /// to show how little the longest taus are worth trusting.
        public var uncertainty: Double {
            pairs > 0 ? deviation / Double(pairs).squareRoot() : .nan
        }
    }

    public let points: [Point]
    /// Mean spacing between readings.
    public let sampleInterval: TimeInterval
    /// Spread of that spacing, relative to the mean. The estimator assumes
    /// evenly spaced readings; past a few percent the answer is decoration.
    public let intervalJitter: Double
    public let readingCount: Int

    public var isEmpty: Bool { points.isEmpty }

    /// Above this, the sample rate wandered enough that the curve should not be
    /// read as a stability measurement.
    public static let jitterWarningThreshold = 0.10

    public var samplingIsEvenEnough: Bool { intervalJitter <= Self.jitterWarningThreshold }

    /// Computes the overlapping Allan deviation of a captured series.
    ///
    /// Returns nil when there are too few readings for even the shortest
    /// averaging time to have a meaningful number of overlapping differences.
    public static func compute(readings: [Reading], maximumPoints: Int = 24) -> AllanDeviation? {
        let values = readings.map(\.value).filter(\.isFinite)
        let count = values.count
        guard count >= 16 else { return nil }

        let (interval, jitter) = spacing(of: readings)
        guard interval > 0 else { return nil }

        // Phase: the running integral of the readings. x has one more entry than
        // y, and x[0] is zero by definition.
        var phase = [Double](repeating: 0, count: count + 1)
        for index in 0..<count {
            phase[index + 1] = phase[index] + values[index] * interval
        }

        var points: [Point] = []
        var m = 1
        // Stop at a quarter of the record: beyond that there are so few
        // overlapping differences left that the point says more about the
        // estimator than about the instrument.
        while m <= count / 4 && points.count < maximumPoints {
            let terms = count - 2 * m + 1
            guard terms >= 5 else { break }

            var total = 0.0
            for index in 0..<terms {
                let secondDifference = phase[index + 2 * m] - 2 * phase[index + m] + phase[index]
                total += secondDifference * secondDifference
            }

            let tau = Double(m) * interval
            let variance = total / (2 * Double(terms) * tau * tau)
            points.append(Point(tau: tau,
                                deviation: variance.squareRoot(),
                                pairs: terms,
                                averagedReadings: m))
            m *= 2
        }

        guard !points.isEmpty else { return nil }
        return AllanDeviation(points: points,
                              sampleInterval: interval,
                              intervalJitter: jitter,
                              readingCount: count)
    }

    /// Mean and relative spread of the gaps between consecutive readings.
    static func spacing(of readings: [Reading]) -> (interval: TimeInterval, jitter: Double) {
        guard readings.count >= 2 else { return (0, 0) }
        var gaps = [Double]()
        gaps.reserveCapacity(readings.count - 1)
        for index in 1..<readings.count {
            gaps.append(readings[index].timestamp.timeIntervalSince(readings[index - 1].timestamp))
        }
        let statistics = Statistics.over(gaps)
        guard statistics.count > 0, statistics.mean > 0 else { return (0, 0) }
        return (statistics.mean, statistics.standardDeviation / statistics.mean)
    }

    /// The τ at which averaging stops paying — the bottom of the curve.
    public var optimumAveragingTime: Point? {
        points.min { $0.deviation < $1.deviation }
    }

    /// Overlapping differences are not independent: only about N/2m of them
    /// carry new information, so the longest τ in any record is an estimate made
    /// from a handful of degrees of freedom and scatters accordingly.
    public func degreesOfFreedom(for point: Point) -> Int {
        max(1, readingCount / (2 * point.averagedReadings))
    }

    /// The points solid enough to draw a conclusion from.
    public var wellDetermined: [Point] {
        points.filter { degreesOfFreedom(for: $0) >= 16 }
    }

    /// Slope of the curve in log-log, over the well determined points. This is
    /// the number that names the noise, which is most of why the plot is drawn
    /// on log axes in the first place.
    public var logSlope: Double? {
        let usable = wellDetermined.filter { $0.deviation > 0 && $0.tau > 0 }
        guard usable.count >= 3 else { return nil }

        let x = usable.map { log10($0.tau) }
        let y = usable.map { log10($0.deviation) }
        let meanX = x.reduce(0, +) / Double(x.count)
        let meanY = y.reduce(0, +) / Double(y.count)

        var covariance = 0.0
        var variance = 0.0
        for (a, b) in zip(x, y) {
            covariance += (a - meanX) * (b - meanY)
            variance += (a - meanX) * (a - meanX)
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }

    /// What the slope means in words. The three regimes a bench instrument
    /// actually shows: averaging helping, averaging having stopped helping, and
    /// averaging making things worse.
    public var noiseDescription: String? {
        guard let slope = logSlope else { return nil }
        switch slope {
        case ..<(-0.35): return "White noise — averaging still helps"
        case ..<0.35: return "Flicker floor — averaging has stopped helping"
        default: return "Drift dominates — averaging is making it worse"
        }
    }

    public func csv(unit: String) -> String {
        var text = "Tau (s),Allan deviation (\(unit)),Pairs,Uncertainty (\(unit))\n"
        for point in points {
            text += "\(point.tau),\(point.deviation),\(point.pairs),\(point.uncertainty)\n"
        }
        return text
    }
}

/// Least-squares straight line through a series, against time.
///
/// The number this exists to produce is the drift rate: how many microvolts an
/// hour a reference is walking, which is the other half of what a long capture
/// is for.
public struct LinearFit: Sendable, Equatable {
    /// Change in the reading per second.
    public let slope: Double
    /// Value the fit gives at the first reading's timestamp.
    public let intercept: Double
    public let rSquared: Double
    public let count: Int
    public let span: TimeInterval

    public var slopePerHour: Double { slope * 3600 }

    /// Total change the fitted line predicts across the whole record.
    public var totalChange: Double { slope * span }

    public static func over(_ readings: [Reading]) -> LinearFit? {
        guard readings.count >= 2, let origin = readings.first?.timestamp else { return nil }

        let points = readings.compactMap { reading -> (x: Double, y: Double)? in
            guard reading.value.isFinite else { return nil }
            return (reading.timestamp.timeIntervalSince(origin), reading.value)
        }
        guard points.count >= 2 else { return nil }

        // Two passes around the means rather than raw sums of squares: readings
        // sit at 4.19 V and differ in the sixth digit, and the one-pass form
        // loses exactly the part being measured.
        let meanX = points.reduce(0) { $0 + $1.x } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.y } / Double(points.count)

        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0 else { return nil }

        let slope = covariance / varianceX
        let intercept = meanY - slope * meanX

        // A flat series has no variance for the line to explain, and calling
        // that a perfect fit is more useful than calling it undefined. "Flat"
        // has to be judged against the floating-point noise floor rather than
        // against exact zero: a hundred readings of 4.19 V do not average to
        // 4.19 V, they average to 4.190000000000001, and the residue is enough
        // to produce a confident-looking r² of nothing.
        let noiseFloor = Double(points.count) * pow(Swift.max(abs(meanY), 1) * .ulpOfOne * 8, 2)
        let rSquared = varianceY > noiseFloor ? (covariance * covariance) / (varianceX * varianceY) : 1

        return LinearFit(slope: slope,
                         intercept: intercept,
                         rSquared: rSquared,
                         count: points.count,
                         span: points.last!.x - points.first!.x)
    }
}
