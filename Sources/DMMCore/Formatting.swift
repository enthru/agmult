import Foundation

/// Reading display, in the style of the meter's own front panel: the SI prefix
/// comes from the *range* rather than the value, so a reading drifting around
/// zero does not flip between µV and mV several times a second, and the number
/// of decimals comes from the resolution, so a 6½-digit reading looks like one.
public enum Format {

    /// Half-away-from-zero rounding, so displayed values agree with what the
    /// meter's own display would show rather than with banker's rounding.
    public static func round(_ value: Double, _ digits: Int) -> Double {
        let scale = pow(10.0, Double(digits))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    public static func number(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(max(0, digits))f", locale: Locale(identifier: "en_US_POSIX"), round(value, digits))
    }

    /// `00:20:20` — the runtime counter in the status bar.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - SI prefixes

    private static let prefixes: [Int: String] = [
        -12: "p", -9: "n", -6: "µ", -3: "m", 0: "", 3: "k", 6: "M", 9: "G",
    ]

    public static func prefix(forExponent exponent: Int) -> String {
        prefixes[exponent] ?? ""
    }

    /// The prefixes the meter itself would use for a given unit. Volts stop at
    /// plain V — the 1000 V range reads `1000.000 V`, never `1.000000 kV`.
    public static func allowedExponents(for unit: String) -> ClosedRange<Int> {
        switch unit {
        case "V": return -6...0
        case "A": return -6...0
        case "Ω": return 0...6
        case "Hz": return 0...6
        case "s": return -9...0
        default: return 0...0
        }
    }

    /// Largest multiple of three whose prefix still leaves `magnitude` at or
    /// above one, clamped to what the unit allows.
    public static func exponent(forMagnitude magnitude: Double, unit: String) -> Int {
        let allowed = allowedExponents(for: unit)
        guard magnitude > 0, magnitude.isFinite else { return min(max(0, allowed.lowerBound), allowed.upperBound) }
        // The nudge keeps log10(1e-3) from landing a hair below -3 and costing a
        // whole prefix step.
        let decade = log10(magnitude) + 1e-9
        var exponent = Int((decade / 3.0).rounded(.down)) * 3
        if magnitude / pow(10, Double(exponent)) >= 1000 { exponent += 3 }
        if magnitude / pow(10, Double(exponent)) < 1 { exponent -= 3 }
        return min(max(exponent, allowed.lowerBound), allowed.upperBound)
    }

    /// Free-form engineering notation, used where there is no range to key off:
    /// statistics, histogram bin edges, axis labels.
    public static func engineering(_ value: Double, unit: String, significantDigits: Int = 6) -> String {
        guard value.isFinite else { return "—" }
        let exponent = self.exponent(forMagnitude: abs(value), unit: unit)
        let scaled = value / pow(10, Double(exponent))
        let integerPlaces = max(1, Int(log10(Swift.max(abs(scaled), 1)).rounded(.down)) + 1)
        let decimals = Swift.max(0, significantDigits - integerPlaces)
        return "\(number(scaled, decimals)) \(prefix(forExponent: exponent))\(unit)"
    }

    // MARK: - Readings

    /// How many decimal places the meter shows for `range` at `digits` full
    /// digits: enough that the display is exactly as wide as the resolution
    /// justifies, and no wider.
    public static func decimals(range: Double, exponent: Int, digits: Int) -> Int {
        let scaledRange = range / pow(10, Double(exponent))
        let integerPlaces = Swift.max(1, Int((log10(Swift.max(scaledRange, 1)) + 1e-9).rounded(.down)) + 1)
        return Swift.max(0, digits + 1 - integerPlaces)
    }

    /// The big number in the readout panel.
    ///
    /// `range` is the measurement range currently in force; pass nil when it is
    /// not known yet and the value's own magnitude will be used instead.
    public static func reading(_ value: Double,
                               unit: String,
                               range: Double?,
                               digits: Int) -> String {
        guard value.isFinite else { return "—" }
        // dB and dBm are logarithmic: there is no range to scale them against
        // and a prefix would be meaningless.
        guard allowedExponents(for: unit) != 0...0 else {
            return "\(number(value, 3)) \(unit)"
        }
        let basis = range ?? Swift.max(abs(value), .leastNormalMagnitude)
        let exponent = self.exponent(forMagnitude: basis, unit: unit)
        let places = decimals(range: basis, exponent: exponent, digits: digits)
        let scaled = value / pow(10, Double(exponent))
        return "\(number(scaled, places)) \(prefix(forExponent: exponent))\(unit)"
    }

    /// The range itself, as the panel labels it: `10 V`, `100 mV`, `1 MΩ`.
    public static func range(_ value: Double, unit: String) -> String {
        let exponent = self.exponent(forMagnitude: value, unit: unit)
        let scaled = value / pow(10, Double(exponent))
        let text = scaled == scaled.rounded() ? String(Int(scaled.rounded())) : number(scaled, 3)
        return "\(text) \(prefix(forExponent: exponent))\(unit)"
    }

    /// Full precision, no prefix — what goes into log files and CSV exports,
    /// where a machine reads the number back.
    public static func scientific(_ value: Double) -> String {
        String(format: "%+.8E", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

extension DateFormatter {
    /// `2020/09/21 06:42:29.123` — the machine readable stamp used in CSV output.
    /// Readings can arrive tens of times a second, so whole seconds are not enough.
    public static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss.SSS"
        return formatter
    }()

    /// `6:42:29 AM` — the stamp appended to every event-list entry.
    public static let eventTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    /// `2020/09/21 6:42:29.123 AM` — the stamp used in the plain-text output log.
    public static let textLogTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd h:mm:ss.SSS a"
        return formatter
    }()

    /// `14:22:31.480` — the time column in the readings table.
    public static let tableTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// `2020-09-21` — the date that goes into log file names.
    public static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
