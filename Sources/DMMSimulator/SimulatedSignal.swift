import Foundation
import DMMCore

/// What the simulated meter's probes are sitting on.
///
/// One value per function, plus an optional modulation so a graph has something
/// to show. The modulation is deterministic — it comes from elapsed time and a
/// fixed-seed generator, never from `Double.random` — so a test that asserts on
/// a shape gets the same shape every run.
public final class SimulatedSignal: @unchecked Sendable {

    public enum Modulation: String, CaseIterable, Sendable {
        case steady
        case drift
        case sine
        case ramp
        case square
        case noise

        public var title: String {
            switch self {
            case .steady: return "Steady"
            case .drift: return "Slow drift"
            case .sine: return "Sine"
            case .ramp: return "Ramp"
            case .square: return "Square"
            case .noise: return "Noise"
            }
        }
    }

    private let lock = NSLock()
    private var storage: [MeasurementFunction: Double] = [
        .dcVoltage: 4.19,
        .acVoltage: 0.5,
        .dcCurrent: 0.0752,
        .acCurrent: 0.012,
        .resistance: 55.5,
        .resistance4Wire: 55.5,
        .frequency: 1000,
        .period: 1000,
        .continuity: 12.5,
        .diode: 0.653,
    ]

    /// The dc reference on the Sense terminals, which the ratio function
    /// divides the Input signal by. It is not a measurement in its own right —
    /// no function reads it — so it lives beside the storage rather than in it.
    public var referenceVoltage: Double = 5

    /// Shape laid over the base value.
    public var modulation: Modulation = .drift
    /// Peak amplitude of the modulation, as a fraction of the base value.
    public var modulationDepth: Double = 0.02
    /// Seconds for one cycle of the modulation.
    public var modulationPeriod: TimeInterval = 30
    /// Peak-to-peak measurement noise at 1 PLC, as a fraction of the reading.
    /// Shorter integration times get proportionally noisier, as they do on a
    /// real meter.
    public var noiseFraction: Double = 2e-6

    private let epoch = Date()
    private var noiseState: UInt64 = 0x2545F4914F6CDD1D

    public init() {}

    public subscript(function: MeasurementFunction) -> Double {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage[function] ?? 0
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage[function] = newValue
            // Frequency and period are the same signal read two ways; keeping
            // them in step means setting one is never quietly contradicted.
            if function == .frequency { storage[.period] = newValue }
            if function == .period { storage[.frequency] = newValue }
        }
    }

    /// The undisturbed physical quantity the meter is looking at.
    public func baseValue(for function: MeasurementFunction) -> Double {
        switch function {
        case .dcRatio:
            return referenceVoltage != 0 ? self[.dcVoltage] / referenceVoltage : 0
        case .period:
            let frequency = self[.frequency]
            return frequency > 0 ? 1 / frequency : 0
        case .continuity:
            return self[.continuity]
        default:
            return self[function]
        }
    }

    /// One reading: base value, modulation, then noise scaled by the aperture.
    public func sample(function: MeasurementFunction, integrationTime: Double) -> Double {
        let base = baseValue(for: function)
        let modulated = base * (1 + shape() * modulationDepth)
        // Noise falls as the square root of the integration time, which is what
        // a longer aperture actually buys you.
        let scale = integrationTime > 0 ? (1 / integrationTime).squareRoot() : 1
        return modulated * (1 + noise() * noiseFraction * scale)
    }

    private func shape() -> Double {
        guard modulation != .steady, modulationPeriod > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(epoch)
        let phase = (elapsed / modulationPeriod).truncatingRemainder(dividingBy: 1)

        switch modulation {
        case .steady: return 0
        case .sine: return sin(2 * .pi * phase)
        case .drift: return sin(2 * .pi * phase) * 0.5 + sin(6 * .pi * phase) * 0.15
        case .ramp: return phase * 2 - 1
        case .square: return phase < 0.5 ? 1 : -1
        case .noise: return noise()
        }
    }

    /// Deterministic pseudo-noise in −1…1 — no `Double.random`, so runs repeat.
    private func noise() -> Double {
        lock.lock(); defer { lock.unlock() }
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        let unit = Double(noiseState % 10_000) / 10_000.0
        return (unit - 0.5) * 2
    }
}
