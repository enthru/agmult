import Foundation

/// One measurement, as it came off the meter.
public struct Reading: Identifiable, Sendable, Equatable {
    public let index: Int
    public let timestamp: Date
    public let value: Double

    public var id: Int { index }

    public init(index: Int, timestamp: Date, value: Double) {
        self.index = index
        self.timestamp = timestamp
        self.value = value
    }
}

/// Summary of a set of readings. `standardDeviation` is the sample deviation
/// (divided by n−1), which is what a meter's own statistics report.
public struct Statistics: Sendable, Equatable {
    public var count: Int = 0
    public var minimum: Double = .nan
    public var maximum: Double = .nan
    public var mean: Double = .nan
    public var standardDeviation: Double = .nan

    public var peakToPeak: Double {
        guard count > 0 else { return .nan }
        return maximum - minimum
    }

    public var isEmpty: Bool { count == 0 }

    public init() {}

    public init(count: Int, minimum: Double, maximum: Double, mean: Double, standardDeviation: Double) {
        self.count = count
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.standardDeviation = standardDeviation
    }

    /// One pass over an arbitrary slice — used for a selected region of a graph,
    /// where there is no running accumulator to read.
    public static func over<S: Sequence>(_ values: S) -> Statistics where S.Element == Double {
        var accumulator = StatisticsAccumulator()
        for value in values { accumulator.add(value) }
        return accumulator.statistics
    }
}

/// Welford's online algorithm: mean and variance in one pass, without the
/// catastrophic cancellation a running sum of squares suffers when the readings
/// are large and the spread between them is tiny — which is exactly the shape of
/// six-and-a-half-digit data.
public struct StatisticsAccumulator: Sendable {
    private var count = 0
    private var mean: Double = 0
    private var sumOfSquaredDeviations: Double = 0
    private var lowest: Double = .infinity
    private var highest: Double = -.infinity

    public init() {}

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        sumOfSquaredDeviations += delta * (value - mean)
        lowest = Swift.min(lowest, value)
        highest = Swift.max(highest, value)
    }

    public mutating func reset() {
        self = StatisticsAccumulator()
    }

    public var statistics: Statistics {
        guard count > 0 else { return Statistics() }
        return Statistics(
            count: count,
            minimum: lowest,
            maximum: highest,
            mean: mean,
            standardDeviation: count > 1 ? (sumOfSquaredDeviations / Double(count - 1)).squareRoot() : 0
        )
    }
}

/// Fixed-capacity reading history.
///
/// Capacity bounds what is kept for drawing and export; the statistics keep
/// accumulating over everything recorded since the last reset, so a long run
/// still reports a true minimum and maximum after old readings have scrolled
/// out of the buffer.
public struct SampleBuffer: Sendable {
    public private(set) var samples: [Reading] = []
    public private(set) var totalRecorded: Int = 0
    public private(set) var overloadCount: Int = 0
    private var accumulator = StatisticsAccumulator()

    public var capacity: Int {
        didSet { trim() }
    }

    public static let capacityChoices = [50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000]

    public init(capacity: Int = 100_000) {
        self.capacity = capacity
        samples.reserveCapacity(min(capacity, 4096))
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var latest: Reading? { samples.last }
    public var statistics: Statistics { accumulator.statistics }
    public var minimum: Double? { statistics.isEmpty ? nil : statistics.minimum }
    public var maximum: Double? { statistics.isEmpty ? nil : statistics.maximum }

    public mutating func append(value: Double, at timestamp: Date) {
        samples.append(Reading(index: totalRecorded, timestamp: timestamp, value: value))
        totalRecorded += 1
        accumulator.add(value)
        trim()
    }

    /// An overload is recorded as a gap: it is counted, but no value is added,
    /// because 9.9E37 in a graph would flatten everything else to a line.
    public mutating func recordOverload() {
        overloadCount += 1
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        totalRecorded = 0
        overloadCount = 0
        accumulator.reset()
    }

    private mutating func trim() {
        let overflow = samples.count - capacity
        if overflow > 0 {
            samples.removeFirst(overflow)
        }
    }

    /// Statistics over the retained samples whose index falls in `range` — the
    /// "statistics for the highlighted area" of the original.
    public func statistics(indices range: ClosedRange<Int>) -> Statistics {
        Statistics.over(samples.lazy.filter { range.contains($0.index) }.map(\.value))
    }

    /// Min/max preserving decimation down to roughly `target` points, so a
    /// million-sample history still draws quickly and still shows its spikes.
    public func decimated(into target: Int = 1200) -> [Reading] {
        SampleBuffer.decimate(samples, into: target)
    }

    public static func decimate(_ samples: [Reading], into target: Int) -> [Reading] {
        guard target > 2, samples.count > target else { return samples }

        let bucketSize = Int((Double(samples.count) / Double(target / 2)).rounded(.up))
        var output: [Reading] = []
        output.reserveCapacity(target + 2)

        var start = 0
        while start < samples.count {
            let end = min(start + bucketSize, samples.count)
            let bucket = samples[start..<end]
            guard let lowest = bucket.min(by: { $0.value < $1.value }),
                  let highest = bucket.max(by: { $0.value < $1.value }) else {
                start = end
                continue
            }
            // Emit in chronological order so the line does not zig-zag backwards.
            if lowest.index <= highest.index {
                output.append(lowest)
                if highest.index != lowest.index { output.append(highest) }
            } else {
                output.append(highest)
                output.append(lowest)
            }
            start = end
        }
        return output
    }

    /// CSV body for "Save Data".
    public func csv(valueHeader: String) -> String {
        SampleBuffer.csv(samples, valueHeader: valueHeader)
    }

    public static func csv(_ samples: [Reading], valueHeader: String) -> String {
        var text = "Sample,DateTime,\(valueHeader)\n"
        let formatter = DateFormatter.logTimestamp
        for sample in samples {
            text += "\(sample.index),\(formatter.string(from: sample.timestamp)),\(sample.value)\n"
        }
        return text
    }
}

/// Distribution of a set of readings — how a six-and-a-half-digit meter's noise
/// actually looks, which a strip chart hides.
public struct Histogram: Sendable, Equatable {
    public struct Bin: Identifiable, Sendable, Equatable {
        public let index: Int
        public let lowerBound: Double
        public let upperBound: Double
        public let count: Int

        public var id: Int { index }
        public var center: Double { (lowerBound + upperBound) / 2 }
    }

    public let bins: [Bin]
    public let statistics: Statistics

    public static let binCountChoices = [16, 32, 64, 128, 256, 512]

    public var isEmpty: Bool { bins.isEmpty }
    public var peakCount: Int { bins.map(\.count).max() ?? 0 }

    public init(values: [Double], binCount: Int = 64) {
        let finite = values.filter(\.isFinite)
        let statistics = Statistics.over(finite)
        self.statistics = statistics

        guard statistics.count > 0, binCount > 0 else {
            self.bins = []
            return
        }

        var lower = statistics.minimum
        var upper = statistics.maximum
        if upper - lower <= 0 {
            // Every reading identical: give the single spike some width so the
            // bar is visible instead of infinitely thin.
            let pad = max(abs(lower) * 1e-9, .leastNormalMagnitude * 1e6)
            lower -= pad
            upper += pad
        }

        let width = (upper - lower) / Double(binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for value in finite {
            var index = Int(((value - lower) / width).rounded(.down))
            index = Swift.min(Swift.max(index, 0), binCount - 1)
            counts[index] += 1
        }

        self.bins = counts.enumerated().map { offset, count in
            Bin(index: offset,
                lowerBound: lower + Double(offset) * width,
                upperBound: lower + Double(offset + 1) * width,
                count: count)
        }
    }

    /// CSV body for exporting the distribution rather than the samples.
    public func csv(valueHeader: String) -> String {
        var text = "Bin,LowerBound (\(valueHeader)),UpperBound (\(valueHeader)),Count\n"
        for bin in bins {
            text += "\(bin.index),\(bin.lowerBound),\(bin.upperBound),\(bin.count)\n"
        }
        return text
    }
}
