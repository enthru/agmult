import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Reads measurements out loud.
///
/// Borrowed straight from the Windows original, and more useful than it sounds:
/// when both hands are holding probes onto a board, hearing the reading is the
/// only way to take it. Announcements come on a timer, on a threshold crossing,
/// or both.
@MainActor
@Observable
public final class SpeechAnnouncer {
    public var isEnabled = false
    /// Seconds between spoken readings; zero means only speak on a threshold.
    public var interval: TimeInterval = 10
    public var speaksPeriodically = true
    /// Speak once when the reading first rises above this.
    public var upperThreshold: Double?
    /// Speak once when the reading first falls below this.
    public var lowerThreshold: Double?
    /// 0…1, where AVSpeechUtterance's default sits around 0.5.
    public var rate: Float = 0.5

    private var lastSpoken: Date?
    private var wasAboveUpper = false
    private var wasBelowLower = false

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    public init() {}

    /// Called with every new reading. Decides whether to say anything, and what.
    public func consider(value: Double, unit: String, at moment: Date = Date()) {
        guard isEnabled, value.isFinite else { return }

        if let upper = upperThreshold {
            let isAbove = value > upper
            if isAbove && !wasAboveUpper {
                speak("Above limit. " + spoken(value: value, unit: unit))
                lastSpoken = moment
                wasAboveUpper = true
                return
            }
            if !isAbove { wasAboveUpper = false }
        }

        if let lower = lowerThreshold {
            let isBelow = value < lower
            if isBelow && !wasBelowLower {
                speak("Below limit. " + spoken(value: value, unit: unit))
                lastSpoken = moment
                wasBelowLower = true
                return
            }
            if !isBelow { wasBelowLower = false }
        }

        guard speaksPeriodically, interval > 0 else { return }
        if let last = lastSpoken, moment.timeIntervalSince(last) < interval { return }
        lastSpoken = moment
        speak(spoken(value: value, unit: unit))
    }

    /// Forget the threshold latches, so the next crossing speaks again.
    public func reset() {
        lastSpoken = nil
        wasAboveUpper = false
        wasBelowLower = false
    }

    public func speak(_ text: String) {
        #if canImport(AVFoundation)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        // A reading that arrives while the last one is still being read would
        // otherwise queue up and fall further and further behind.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(utterance)
        #endif
    }

    public func stop() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
    }

    /// Turns `4.19` and `V` into something a speech synthesiser reads correctly.
    /// Four significant figures: any more and the announcement outlasts its
    /// usefulness.
    public func spoken(value: Double, unit: String) -> String {
        let exponent = Format.exponent(forMagnitude: abs(value), unit: unit)
        let scaled = value / pow(10, Double(exponent))
        let number = Format.number(scaled, max(0, 4 - Int(log10(max(abs(scaled), 1))) - 1))
        return "\(number) \(Self.spokenPrefix(exponent))\(Self.spokenUnit(unit))"
    }

    static func spokenPrefix(_ exponent: Int) -> String {
        switch exponent {
        case -9: return "nano"
        case -6: return "micro"
        case -3: return "milli"
        case 3: return "kilo"
        case 6: return "mega"
        case 9: return "giga"
        default: return ""
        }
    }

    static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "V": return "volts"
        case "A": return "amps"
        case "Ω": return "ohms"
        case "Hz": return "hertz"
        case "s": return "seconds"
        case "W": return "watts"
        case "dB": return "decibels"
        case "dBm": return "dBm"
        case "ppm": return "parts per million"
        default: return unit
        }
    }
}
