import Foundation

/// A transform applied to a captured series to produce a new one.
///
/// These run over the history this application keeps, not inside the meter, so
/// they can be added, changed and removed after the fact — and a waveform can
/// take another waveform as its source, which is how a smoothed derivative or a
/// filtered power trace gets built up a step at a time.
public enum WaveformOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case scale
    case movingAverage
    case medianFilter
    case lowPass
    case deviationFromMean
    case partsPerMillion
    case delta
    case derivative
    case integral
    case absolute
    case square
    case reciprocal
    case decibel
    case power

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scale: return "Scale — a·x + b"
        case .movingAverage: return "Moving average"
        case .medianFilter: return "Median filter"
        case .lowPass: return "Low-pass filter"
        case .deviationFromMean: return "Deviation from mean"
        case .partsPerMillion: return "Deviation from reference, ppm"
        case .delta: return "Difference between readings"
        case .derivative: return "Derivative, d/dt"
        case .integral: return "Integral, ∫ dt"
        case .absolute: return "Absolute value"
        case .square: return "Square"
        case .reciprocal: return "Reciprocal"
        case .decibel: return "Decibels vs reference"
        case .power: return "Power into a load"
        }
    }

    /// What the first parameter means, or nil when the operation takes none.
    public var parameterALabel: String? {
        switch self {
        case .scale: return "Gain a"
        case .movingAverage, .medianFilter: return "Window (readings)"
        case .lowPass: return "Time constant (s)"
        case .partsPerMillion: return "Reference"
        case .decibel: return "Reference"
        case .power: return "Load (Ω)"
        default: return nil
        }
    }

    public var parameterBLabel: String? {
        self == .scale ? "Offset b" : nil
    }

    public var defaultParameterA: Double {
        switch self {
        case .scale: return 1
        case .movingAverage: return 16
        case .medianFilter: return 9
        case .lowPass: return 1
        case .partsPerMillion: return 1
        case .decibel: return 1
        case .power: return 50
        default: return 0
        }
    }

    public var defaultParameterB: Double { 0 }

    /// The unit of the result, given the unit of the source.
    public func unit(from source: String) -> String {
        switch self {
        case .scale, .movingAverage, .medianFilter, .lowPass, .deviationFromMean, .delta, .absolute:
            return source
        case .partsPerMillion: return "ppm"
        case .derivative: return source + "/s"
        case .integral: return source + "·s"
        case .square: return source + "²"
        case .reciprocal: return "1/" + source
        case .decibel: return "dB"
        case .power: return "W"
        }
    }

    /// A short description of the result, for the window subtitle.
    public func summary(a: Double, b: Double) -> String {
        switch self {
        case .scale: return "\(SCPI.format(a))·x + \(SCPI.format(b))"
        case .movingAverage: return "mean of \(Int(a.rounded())) readings"
        case .medianFilter: return "median of \(Int(a.rounded())) readings"
        case .lowPass: return "τ = \(SCPI.format(a)) s"
        case .deviationFromMean: return "x − mean"
        case .partsPerMillion: return "(x − \(SCPI.format(a))) / \(SCPI.format(a)) × 10⁶"
        case .delta: return "x[n] − x[n−1]"
        case .derivative: return "dx/dt"
        case .integral: return "∫ x dt"
        case .absolute: return "|x|"
        case .square: return "x²"
        case .reciprocal: return "1/x"
        case .decibel: return "20·log₁₀(|x| / \(SCPI.format(a)))"
        case .power: return "x² / \(SCPI.format(a)) Ω"
        }
    }
}

/// An operation together with its parameters.
public struct WaveformRecipe: Sendable, Equatable, Codable {
    public var operation: WaveformOperation
    public var parameterA: Double
    public var parameterB: Double

    public init(operation: WaveformOperation = .movingAverage,
                parameterA: Double? = nil,
                parameterB: Double? = nil) {
        self.operation = operation
        self.parameterA = parameterA ?? operation.defaultParameterA
        self.parameterB = parameterB ?? operation.defaultParameterB
    }

    public var summary: String { operation.summary(a: parameterA, b: parameterB) }

    public func unit(from source: String) -> String { operation.unit(from: source) }

    /// Applies the transform. Indices and timestamps are carried over from the
    /// source readings that produced each output point, so a derived waveform
    /// still lines up with the original on a shared time axis.
    public func apply(to source: [Reading]) -> [Reading] {
        guard !source.isEmpty else { return [] }

        switch operation {
        case .scale:
            return map(source) { parameterA * $0 + parameterB }

        case .absolute:
            return map(source) { abs($0) }

        case .square:
            return map(source) { $0 * $0 }

        case .reciprocal:
            // A reading that happens to sit exactly on zero has no reciprocal;
            // dropping the point is better than plotting an infinity.
            return compactMap(source) { $0 == 0 ? nil : 1 / $0 }

        case .decibel:
            let reference = abs(parameterA)
            guard reference > 0 else { return [] }
            return compactMap(source) { $0 == 0 ? nil : 20 * log10(abs($0) / reference) }

        case .power:
            let load = parameterA
            guard load != 0 else { return [] }
            return map(source) { $0 * $0 / load }

        case .partsPerMillion:
            let reference = parameterA
            guard reference != 0 else { return [] }
            return map(source) { ($0 - reference) / reference * 1e6 }

        case .deviationFromMean:
            let mean = Statistics.over(source.map(\.value)).mean
            guard mean.isFinite else { return [] }
            return map(source) { $0 - mean }

        case .delta:
            var output: [Reading] = []
            output.reserveCapacity(source.count)
            for index in 1..<source.count {
                output.append(Reading(index: source[index].index,
                                      timestamp: source[index].timestamp,
                                      value: source[index].value - source[index - 1].value))
            }
            return output

        case .derivative:
            var output: [Reading] = []
            output.reserveCapacity(source.count)
            for index in 1..<source.count {
                let interval = source[index].timestamp.timeIntervalSince(source[index - 1].timestamp)
                guard interval > 0 else { continue }
                output.append(Reading(index: source[index].index,
                                      timestamp: source[index].timestamp,
                                      value: (source[index].value - source[index - 1].value) / interval))
            }
            return output

        case .integral:
            var total = 0.0
            var output: [Reading] = [Reading(index: source[0].index, timestamp: source[0].timestamp, value: 0)]
            output.reserveCapacity(source.count)
            for index in 1..<source.count {
                let interval = source[index].timestamp.timeIntervalSince(source[index - 1].timestamp)
                // Trapezoidal, so a ramp integrates exactly rather than lagging.
                total += (source[index].value + source[index - 1].value) / 2 * max(interval, 0)
                output.append(Reading(index: source[index].index, timestamp: source[index].timestamp, value: total))
            }
            return output

        case .movingAverage:
            let window = Swift.max(Int(parameterA.rounded()), 2)
            // Quietly averaging four readings when sixteen were asked for would
            // be a different measurement wearing the same label.
            guard source.count >= window else { return [] }
            var output: [Reading] = []
            output.reserveCapacity(source.count - window + 1)
            var running = 0.0
            for index in 0..<source.count {
                running += source[index].value
                if index >= window { running -= source[index - window].value }
                if index >= window - 1 {
                    output.append(Reading(index: source[index].index,
                                          timestamp: source[index].timestamp,
                                          value: running / Double(window)))
                }
            }
            return output

        case .medianFilter:
            // An outlier is dragged into the answer by a mean and ignored by a
            // median. For a meter that occasionally throws a single wild reading
            // — a relay settling, a probe bouncing — this is the right filter and
            // the moving average is the wrong one.
            let window = Swift.max(Int(parameterA.rounded()), 3)
            guard source.count >= window else { return [] }
            var output: [Reading] = []
            output.reserveCapacity(source.count - window + 1)
            let middle = window / 2
            for index in (window - 1)..<source.count {
                var slice = source[(index - window + 1)...index].map(\.value)
                slice.sort()
                let median = window % 2 == 1
                    ? slice[middle]
                    : (slice[middle - 1] + slice[middle]) / 2
                output.append(Reading(index: source[index].index,
                                      timestamp: source[index].timestamp,
                                      value: median))
            }
            return output

        case .lowPass:
            let tau = parameterA
            guard tau > 0 else { return source }
            var output: [Reading] = []
            output.reserveCapacity(source.count)
            var state = source[0].value
            output.append(source[0])
            for index in 1..<source.count {
                let interval = source[index].timestamp.timeIntervalSince(source[index - 1].timestamp)
                // Exact single-pole response for the interval actually elapsed,
                // so an uneven sample rate does not change the corner frequency.
                let alpha = 1 - exp(-max(interval, 0) / tau)
                state += (source[index].value - state) * alpha
                output.append(Reading(index: source[index].index,
                                      timestamp: source[index].timestamp,
                                      value: state))
            }
            return output
        }
    }

    private func map(_ source: [Reading], _ transform: (Double) -> Double) -> [Reading] {
        source.map { Reading(index: $0.index, timestamp: $0.timestamp, value: transform($0.value)) }
    }

    private func compactMap(_ source: [Reading], _ transform: (Double) -> Double?) -> [Reading] {
        source.compactMap { sample in
            transform(sample.value).map { Reading(index: sample.index, timestamp: sample.timestamp, value: $0) }
        }
    }
}
