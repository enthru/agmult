import XCTest
@testable import DMMCore

final class SampleBufferTests: XCTestCase {

    private func buffer(capacity: Int, values: [Double]) -> SampleBuffer {
        var buffer = SampleBuffer(capacity: capacity)
        let start = Date(timeIntervalSince1970: 0)
        for (offset, value) in values.enumerated() {
            buffer.append(value: value, at: start.addingTimeInterval(Double(offset)))
        }
        return buffer
    }

    func testKeepsAtMostItsCapacityButKeepsCountingEverything() {
        let buffer = self.buffer(capacity: 3, values: [1, 2, 3, 4, 5])
        XCTAssertEqual(buffer.samples.count, 3)
        XCTAssertEqual(buffer.samples.map(\.value), [3, 4, 5])
        XCTAssertEqual(buffer.totalRecorded, 5)
        XCTAssertEqual(buffer.samples.first?.index, 2, "indices survive the trim")
    }

    /// The statistics run over everything recorded, not over what happens to be
    /// left in the buffer — otherwise a long run would forget its own extremes.
    func testStatisticsSurviveReadingsScrollingOutOfTheBuffer() {
        let buffer = self.buffer(capacity: 2, values: [1, 100, 3, 4])
        XCTAssertEqual(buffer.statistics.count, 4)
        XCTAssertEqual(buffer.minimum, 1)
        XCTAssertEqual(buffer.maximum, 100)
    }

    func testShrinkingTheCapacityTrimsImmediately() {
        var buffer = self.buffer(capacity: 100, values: Array(repeating: 1, count: 50))
        buffer.capacity = 10
        XCTAssertEqual(buffer.samples.count, 10)
    }

    func testResetClearsEverything() {
        var buffer = self.buffer(capacity: 10, values: [1, 2, 3])
        buffer.recordOverload()
        buffer.reset()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.totalRecorded, 0)
        XCTAssertEqual(buffer.overloadCount, 0)
        XCTAssertNil(buffer.minimum)
    }

    /// An overload is counted but not stored: 9.9E37 in a graph would flatten
    /// everything else to a line.
    func testOverloadsAreCountedNotPlotted() {
        var buffer = self.buffer(capacity: 10, values: [1, 2])
        buffer.recordOverload()
        XCTAssertEqual(buffer.overloadCount, 1)
        XCTAssertEqual(buffer.samples.count, 2)
    }

    // MARK: - Statistics

    func testWelfordMatchesTheTextbookAnswer() {
        let statistics = Statistics.over([1, 2, 3, 4, 5])
        XCTAssertEqual(statistics.count, 5)
        XCTAssertEqual(statistics.mean, 3, accuracy: 1e-12)
        XCTAssertEqual(statistics.standardDeviation, 2.5.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(statistics.peakToPeak, 4)
    }

    /// The whole reason for Welford: a naive sum of squares loses the spread
    /// entirely when the readings are large and the differences are tiny, which
    /// is exactly the shape of six-and-a-half-digit data.
    func testStandardDeviationSurvivesLargeValuesWithATinySpread() {
        let base = 1_000_000.0
        let statistics = Statistics.over([base - 0.001, base, base + 0.001])
        XCTAssertEqual(statistics.mean, base, accuracy: 1e-6)
        XCTAssertEqual(statistics.standardDeviation, 0.001, accuracy: 1e-9)
    }

    func testEmptyStatisticsAreEmptyRatherThanZero() {
        let statistics = Statistics.over([Double]())
        XCTAssertTrue(statistics.isEmpty)
        XCTAssertEqual(statistics.count, 0)
    }

    func testStatisticsOverASelectedRangeOfIndices() {
        let buffer = self.buffer(capacity: 100, values: [1, 2, 3, 4, 5])
        let statistics = buffer.statistics(indices: 1...3)
        XCTAssertEqual(statistics.count, 3)
        XCTAssertEqual(statistics.mean, 3, accuracy: 1e-12)
    }

    // MARK: - Decimation

    func testDecimationKeepsTheSpikes() {
        var values = [Double](repeating: 0, count: 10_000)
        values[4_321] = 42          // one-reading spike
        values[6_789] = -17

        let buffer = self.buffer(capacity: 20_000, values: values)
        let drawn = buffer.decimated(into: 500)

        XCTAssertLessThanOrEqual(drawn.count, 520)
        XCTAssertEqual(drawn.map(\.value).max(), 42, "the spike must survive")
        XCTAssertEqual(drawn.map(\.value).min(), -17)
    }

    func testDecimationLeavesShortSeriesAlone() {
        let buffer = self.buffer(capacity: 100, values: [1, 2, 3])
        XCTAssertEqual(buffer.decimated(into: 500).count, 3)
    }

    func testDecimatedPointsStayInChronologicalOrder() {
        let values = (0..<1000).map { sin(Double($0) / 7) }
        let buffer = self.buffer(capacity: 2000, values: values)
        let drawn = buffer.decimated(into: 100)
        XCTAssertEqual(drawn.map(\.index), drawn.map(\.index).sorted())
    }

    func testCSVCarriesEveryRetainedSample() {
        let buffer = self.buffer(capacity: 100, values: [1, 2, 3])
        let lines = buffer.csv(valueHeader: "DCV (V)").split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "header plus three readings")
        XCTAssertEqual(lines[0], "Sample,DateTime,DCV (V)")
    }

    // MARK: - Histogram

    func testHistogramCountsEveryValueExactlyOnce() {
        let values = (1...100).map(Double.init)
        let histogram = Histogram(values: values, binCount: 10)
        XCTAssertEqual(histogram.bins.count, 10)
        XCTAssertEqual(histogram.bins.map(\.count).reduce(0, +), 100)
        XCTAssertEqual(histogram.statistics.count, 100)
    }

    func testHistogramSpansTheDataFromMinimumToMaximum() {
        let histogram = Histogram(values: [0, 5, 10], binCount: 2)
        XCTAssertEqual(histogram.bins.first!.lowerBound, 0, accuracy: 1e-12)
        XCTAssertEqual(histogram.bins.last!.upperBound, 10, accuracy: 1e-12)
    }

    /// Every reading identical is the normal case for a meter looking at a
    /// battery, and a zero-width histogram would divide by zero.
    func testHistogramOfIdenticalReadingsIsASingleSpike() {
        let histogram = Histogram(values: Array(repeating: 4.19, count: 50), binCount: 16)
        XCTAssertEqual(histogram.bins.map(\.count).reduce(0, +), 50)
        XCTAssertEqual(histogram.peakCount, 50)
    }

    func testEmptyHistogramIsEmpty() {
        XCTAssertTrue(Histogram(values: [], binCount: 16).isEmpty)
    }
}
