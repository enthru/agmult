import Foundation

/// The eleven things a 34401A can measure: the ten front-panel keys, plus the
/// dc:dc ratio, which on the meter itself lives in the Shift-Meas menu rather
/// than on a key of its own.
public enum MeasurementFunction: String, CaseIterable, Identifiable, Codable, Sendable {
    case dcVoltage
    case dcRatio
    case acVoltage
    case dcCurrent
    case acCurrent
    case resistance
    case resistance4Wire
    case frequency
    case period
    case continuity
    case diode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dcVoltage: return "DC Voltage"
        case .dcRatio: return "DC Voltage Ratio"
        case .acVoltage: return "AC Voltage"
        case .dcCurrent: return "DC Current"
        case .acCurrent: return "AC Current"
        case .resistance: return "2-Wire Resistance"
        case .resistance4Wire: return "4-Wire Resistance"
        case .frequency: return "Frequency"
        case .period: return "Period"
        case .continuity: return "Continuity"
        case .diode: return "Diode Test"
        }
    }

    /// The annunciator across the top of the readout panel.
    public var shortTitle: String {
        switch self {
        case .dcVoltage: return "DCV"
        case .dcRatio: return "RATIO"
        case .acVoltage: return "ACV"
        case .dcCurrent: return "DCI"
        case .acCurrent: return "ACI"
        case .resistance: return "2W Ω"
        case .resistance4Wire: return "4W Ω"
        case .frequency: return "FREQ"
        case .period: return "PER"
        case .continuity: return "CONT"
        case .diode: return "DIODE"
        }
    }

    /// A ratio is a quotient of two voltages and carries no unit at all, which
    /// the formatter reads as "spend every digit on the number itself".
    public var unit: String {
        switch self {
        case .dcRatio: return ""
        case .dcVoltage, .acVoltage, .diode: return "V"
        case .dcCurrent, .acCurrent: return "A"
        case .resistance, .resistance4Wire, .continuity: return "Ω"
        case .frequency: return "Hz"
        case .period: return "s"
        }
    }

    /// SCPI subsystem root that `RANGe`, `NPLC` and `RESolution` hang off.
    ///
    /// The ratio answers `VOLT:DC` here rather than a node of its own: it has no
    /// settings the meter keeps separately — it runs on the DC voltage range and
    /// integration time, and the reference on the Sense terminals is always
    /// auto-ranged, which is not something to configure either.
    public var scpiRoot: String {
        switch self {
        case .dcVoltage, .dcRatio: return "VOLT:DC"
        case .acVoltage: return "VOLT:AC"
        case .dcCurrent: return "CURR:DC"
        case .acCurrent: return "CURR:AC"
        case .resistance: return "RES"
        case .resistance4Wire: return "FRES"
        case .frequency: return "FREQ"
        case .period: return "PER"
        case .continuity: return "CONT"
        case .diode: return "DIOD"
        }
    }

    /// What `FUNCtion` and `CONFigure` call this function when selecting it.
    /// Only the ratio differs from `scpiRoot`, because only the ratio is a
    /// function whose settings live somewhere other than its own name.
    public var selectionRoot: String {
        self == .dcRatio ? "VOLT:DC:RAT" : scpiRoot
    }

    /// Whose range and integration time this function actually uses — itself,
    /// except for the ratio, which borrows DC volts'.
    public var parameterFunction: MeasurementFunction {
        self == .dcRatio ? .dcVoltage : self
    }

    /// What `FUNCtion?` answers with. Note the asymmetry the meter insists on:
    /// you select DC volts with `"VOLTage:DC"` but it reports back `"VOLT"`.
    public var queryToken: String {
        switch self {
        case .dcVoltage: return "VOLT"
        case .dcRatio: return "VOLT:RAT"
        case .dcCurrent: return "CURR"
        default: return scpiRoot
        }
    }

    /// Every spelling a read-back may legitimately use for this function.
    ///
    /// The manual lists what to *send* but says only that `FUNCtion?` "returns a
    /// quoted string", and the ratio is where that matters: the meter drops the
    /// `DC` the selection string carries. Accepting each plausible abbreviation
    /// costs nothing and stops a read-back from deciding, on a spelling, that
    /// somebody changed the function on the front panel.
    public var acceptedQueryTokens: [String] {
        switch self {
        case .dcVoltage: return ["VOLT", "VOLT:DC"]
        case .dcRatio: return ["VOLT:RAT", "VOLT:DC:RAT", "VOLT:RATIO", "VOLT:DC:RATIO"]
        case .dcCurrent: return ["CURR", "CURR:DC"]
        default: return [queryToken]
        }
    }

    public static func from(queryToken raw: String) -> MeasurementFunction? {
        let token = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
            .uppercased()
        return allCases.first { $0.acceptedQueryTokens.contains(token) }
    }

    /// Measurement ranges, in volts / amps / ohms.
    ///
    /// For frequency and period these are the *input voltage* ranges the
    /// counter's front end uses, which is what `FREQ:VOLTage:RANGe` sets.
    public var ranges: [Double] {
        switch self {
        case .dcVoltage, .dcRatio: return [0.1, 1, 10, 100, 1000]
        case .acVoltage: return [0.1, 1, 10, 100, 750]
        case .dcCurrent: return [0.01, 0.1, 1, 3]
        case .acCurrent: return [1, 3]
        case .resistance, .resistance4Wire: return [100, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8]
        case .frequency, .period: return [0.1, 1, 10, 100, 750]
        case .continuity: return [1e3]
        case .diode: return [1]
        }
    }

    /// Unit the range list is expressed in — volts for the counter functions,
    /// where the range is a signal amplitude rather than a frequency.
    public var rangeUnit: String {
        switch self {
        // The counter's range is the amplitude its front end must cope with,
        // and the ratio's is the voltage on the Input terminals — in both cases
        // a voltage, even though the reading is not one.
        case .frequency, .period, .dcRatio: return "V"
        default: return unit
        }
    }

    /// Continuity and diode run on a fixed range that cannot be changed.
    public var hasSelectableRange: Bool {
        self != .continuity && self != .diode
    }

    /// Where `RANGe` and `RANGe:AUTO` live. The counter functions put them under
    /// a `VOLTage` node because they describe the input, not the reading.
    public var rangeRoot: String {
        switch self {
        case .frequency: return "FREQ:VOLT"
        case .period: return "PER:VOLT"
        default: return scpiRoot
        }
    }

    /// Integration time in power-line cycles applies to the DC and resistance
    /// functions. AC uses a filter bandwidth and the counter uses a gate time.
    public var usesIntegrationTime: Bool {
        switch self {
        case .dcVoltage, .dcRatio, .dcCurrent, .resistance, .resistance4Wire: return true
        default: return false
        }
    }

    public var usesBandwidth: Bool {
        self == .acVoltage || self == .acCurrent
    }

    public var usesAperture: Bool {
        self == .frequency || self == .period
    }

    /// Only the DC voltage ranges below 10 V can be switched to the high
    /// impedance input; everywhere else the meter is fixed at 10 MΩ.
    public var usesInputImpedance: Bool {
        self == .dcVoltage
    }

    /// Front-panel terminals the reading comes from — worth spelling out, since
    /// putting the leads in the wrong pair is the usual reason for a wild value.
    public var terminals: String {
        switch self {
        case .dcCurrent, .acCurrent: return "Input HI and the I terminal"
        case .resistance4Wire: return "Input HI/LO plus Sense HI/LO"
        case .dcRatio: return "the signal on Input HI/LO, its reference on Sense HI/LO"
        default: return "Input HI and LO"
        }
    }
}

/// Integration time, in power-line cycles. Longer means quieter and slower, and
/// at 1 PLC and above the meter also rejects line-frequency noise.
public enum IntegrationTime: Double, CaseIterable, Identifiable, Codable, Sendable {
    case fastest = 0.02
    case fast = 0.2
    case normal = 1
    case slow = 10
    case slowest = 100

    public var id: Double { rawValue }

    /// Full digits shown; the meter adds a leading half digit on top.
    public var digits: Int {
        switch self {
        case .fastest: return 4
        case .fast: return 5
        default: return 6
        }
    }

    public var displayDigits: String { "\(digits)½ digits" }

    /// Readings per second the meter can produce, over GPIB with the display off.
    /// RS-232 is nowhere near this — see `DMMController.effectiveRate`.
    public var readingsPerSecond: Double {
        switch self {
        case .fastest: return 1000
        case .fast: return 300
        case .normal: return 60
        case .slow: return 6
        case .slowest: return 0.6
        }
    }

    public var title: String {
        let plc = rawValue < 1 ? String(rawValue) : String(Int(rawValue))
        return "\(plc) PLC — \(displayDigits)"
    }

    /// What fits in a picker three hundred points wide.
    public var shortTitle: String {
        let plc = rawValue < 1 ? String(rawValue) : String(Int(rawValue))
        return "\(plc) PLC · \(digits)½"
    }

    /// True once the aperture spans a whole line cycle, which is where the meter
    /// starts rejecting 50/60 Hz hum.
    public var rejectsLineNoise: Bool { rawValue >= 1 }
}

/// Counter gate time for the frequency and period functions.
public enum GateTime: Double, CaseIterable, Identifiable, Codable, Sendable {
    case ms10 = 0.01
    case ms100 = 0.1
    case s1 = 1

    public var id: Double { rawValue }

    public var digits: Int {
        switch self {
        case .ms10: return 4
        case .ms100: return 5
        case .s1: return 6
        }
    }

    public var title: String {
        switch self {
        case .ms10: return "10 ms — 4½ digits"
        case .ms100: return "100 ms — 5½ digits"
        case .s1: return "1 s — 6½ digits"
        }
    }

    public var shortTitle: String {
        switch self {
        case .ms10: return "10 ms · 4½"
        case .ms100: return "100 ms · 5½"
        case .s1: return "1 s · 6½"
        }
    }
}

/// AC filter bandwidth. The slow filter settles slowly but reads correctly down
/// to 3 Hz; the fast one is for signals that are comfortably above 200 Hz.
public enum ACBandwidth: Int, CaseIterable, Identifiable, Codable, Sendable {
    case slow = 3
    case medium = 20
    case fast = 200

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .slow: return "3 Hz — slow filter, 7 s settling"
        case .medium: return "20 Hz — medium filter, 1 s settling"
        case .fast: return "200 Hz — fast filter, 0.6 s settling"
        }
    }

    public var shortTitle: String { "\(rawValue) Hz" }
}

public enum AutoZero: String, CaseIterable, Identifiable, Codable, Sendable {
    case on = "ON"
    case off = "OFF"
    case once = "ONCE"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .on: return "On — zero before every reading"
        case .off: return "Off — faster, drifts with temperature"
        case .once: return "Once — take a zero now, then hold it"
        }
    }

    public var shortTitle: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .once: return "Once"
        }
    }
}

public enum TriggerSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case immediate = "IMM"
    case bus = "BUS"
    case external = "EXT"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .immediate: return "Immediate — free running"
        case .bus: return "Bus — this app sends *TRG"
        case .external: return "External — rear-panel Ext Trig input"
        }
    }

    public var shortTitle: String {
        switch self {
        case .immediate: return "Immediate"
        case .bus: return "Bus"
        case .external: return "External"
        }
    }
}

/// Which of the meter's own maths is switched on. `statistics` is the meter's
/// `AVERage` function: it accumulates min, max, mean and count inside the
/// instrument, independently of the history this app keeps.
public enum MathFunction: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case null
    case decibel
    case dBm
    case statistics
    case limit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "Off"
        case .null: return "Null (relative)"
        case .decibel: return "dB"
        case .dBm: return "dBm"
        case .statistics: return "Min / Max / Average"
        case .limit: return "Limit test"
        }
    }

    /// The `CALCulate:FUNCtion` keyword, or nil when maths is off.
    public var scpiKeyword: String? {
        switch self {
        case .none: return nil
        case .null: return "NULL"
        case .decibel: return "DB"
        case .dBm: return "DBM"
        case .statistics: return "AVER"
        case .limit: return "LIM"
        }
    }

    /// Maths changes the unit of the reading for dB and dBm.
    public func unit(for function: MeasurementFunction) -> String {
        switch self {
        case .decibel: return "dB"
        case .dBm: return "dBm"
        default: return function.unit
        }
    }

    /// The annunciator the readout panel shows while this is running.
    public var annunciator: String? {
        switch self {
        case .none: return nil
        case .null: return "NULL"
        case .decibel: return "dB"
        case .dBm: return "dBm"
        case .statistics: return "MATH"
        case .limit: return "LIMIT"
        }
    }
}
