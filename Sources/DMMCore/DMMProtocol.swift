import Foundation

/// The SCPI command set of the HP / Agilent / Keysight 34401A. Everything the
/// application sends is spelled out here, so the wire protocol can be read in
/// one place and tested without a serial port.
public enum SCPI {

    // MARK: Common

    public static let identify = "*IDN?"
    public static let reset = "*RST"
    public static let clearStatus = "*CLS"
    public static let selfTest = "*TST?"
    public static let operationComplete = "*OPC?"
    public static let trigger = "*TRG"

    // MARK: Interface

    /// Must be sent before anything else over RS-232. The manual is blunt about
    /// it: sending or receiving data while the meter is in local mode "can cause
    /// unpredictable results", and the front panel stays live and fighting you.
    public static let remote = "SYST:REM"
    public static let local = "SYST:LOC"
    public static let remoteWithLockout = "SYST:RWL"
    public static let errorQuery = "SYST:ERR?"
    public static let versionQuery = "SYST:VERS?"

    /// Ctrl-C. Clears whatever the interface was doing and throws away pending
    /// output — the RS-232 stand-in for an IEEE-488 device clear.
    public static let interfaceClear: UInt8 = 0x03

    // MARK: Measurement configuration

    public static let functionQuery = "FUNC?"

    public static func selectFunction(_ function: MeasurementFunction) -> String {
        "FUNC \"\(function.scpiRoot)\""
    }

    /// `CONFigure` is a heavier hammer than `FUNCtion`: as well as choosing the
    /// function it resets that function's range, resolution and trigger settings
    /// to their defaults. Used when the user picks a function from the panel, so
    /// leftovers from the previous one cannot linger.
    public static func configure(_ function: MeasurementFunction) -> String {
        "CONF:\(function.scpiRoot)"
    }

    public static func rangeQuery(_ function: MeasurementFunction) -> String {
        "\(function.rangeRoot):RANG?"
    }

    public static func setRange(_ function: MeasurementFunction, _ value: Double) -> String {
        "\(function.rangeRoot):RANG \(format(value))"
    }

    public static func autoRangeQuery(_ function: MeasurementFunction) -> String {
        "\(function.rangeRoot):RANG:AUTO?"
    }

    public static func setAutoRange(_ function: MeasurementFunction, _ enabled: Bool) -> String {
        "\(function.rangeRoot):RANG:AUTO \(enabled ? "ON" : "OFF")"
    }

    public static func integrationTimeQuery(_ function: MeasurementFunction) -> String {
        "\(function.scpiRoot):NPLC?"
    }

    public static func setIntegrationTime(_ function: MeasurementFunction, _ time: IntegrationTime) -> String {
        "\(function.scpiRoot):NPLC \(format(time.rawValue))"
    }

    public static func apertureQuery(_ function: MeasurementFunction) -> String {
        "\(function.scpiRoot):APER?"
    }

    public static func setAperture(_ function: MeasurementFunction, _ gate: GateTime) -> String {
        "\(function.scpiRoot):APER \(format(gate.rawValue))"
    }

    /// The AC filter is a single global setting rather than one per function.
    public static let bandwidthQuery = "DET:BAND?"

    public static func setBandwidth(_ bandwidth: ACBandwidth) -> String {
        "DET:BAND \(bandwidth.rawValue)"
    }

    public static let autoZeroQuery = "ZERO:AUTO?"

    public static func setAutoZero(_ mode: AutoZero) -> String {
        "ZERO:AUTO \(mode.rawValue)"
    }

    /// On the 100 mV, 1 V and 10 V DC ranges this swaps the 10 MΩ divider for a
    /// >10 GΩ input, so a high-impedance source is not loaded down.
    public static let inputImpedanceQuery = "INP:IMP:AUTO?"

    public static func setInputImpedanceAuto(_ enabled: Bool) -> String {
        "INP:IMP:AUTO \(enabled ? "ON" : "OFF")"
    }

    // MARK: Triggering and acquisition

    public static let triggerSourceQuery = "TRIG:SOUR?"

    public static func setTriggerSource(_ source: TriggerSource) -> String {
        "TRIG:SOUR \(source.rawValue)"
    }

    public static func setTriggerDelayAuto(_ enabled: Bool) -> String {
        "TRIG:DEL:AUTO \(enabled ? "ON" : "OFF")"
    }

    public static func setTriggerDelay(_ seconds: Double) -> String {
        "TRIG:DEL \(format(seconds))"
    }

    public static func setSampleCount(_ count: Int) -> String {
        "SAMP:COUN \(count)"
    }

    public static func setTriggerCount(_ count: Int) -> String {
        "TRIG:COUN \(count)"
    }

    /// Arms the meter, waits for the trigger and returns every reading of the
    /// burst in one response. One serial round trip for `SAMP:COUN` readings is
    /// the only way to get a useful sample rate out of RS-232.
    public static let read = "READ?"
    public static let abort = "ABOR"
    public static let initiate = "INIT"
    public static let fetch = "FETC?"
    public static let storedCountQuery = "DATA:POIN?"

    // MARK: Maths

    public static let mathStateQuery = "CALC:STAT?"

    public static func setMathState(_ enabled: Bool) -> String {
        "CALC:STAT \(enabled ? "ON" : "OFF")"
    }

    public static func setMathFunction(_ keyword: String) -> String {
        "CALC:FUNC \(keyword)"
    }

    public static let nullOffsetQuery = "CALC:NULL:OFFS?"

    public static func setNullOffset(_ value: Double) -> String {
        "CALC:NULL:OFFS \(format(value))"
    }

    public static func setDecibelReference(_ value: Double) -> String {
        "CALC:DB:REF \(format(value))"
    }

    /// A resistance in ohms — the load dBm is referred to. 600 Ω on power-up.
    public static func setDBmReference(_ ohms: Double) -> String {
        "CALC:DBM:REF \(format(ohms))"
    }

    public static let statisticsMinimum = "CALC:AVER:MIN?"
    public static let statisticsMaximum = "CALC:AVER:MAX?"
    public static let statisticsAverage = "CALC:AVER:AVER?"
    public static let statisticsCount = "CALC:AVER:COUN?"

    public static func setLowerLimit(_ value: Double) -> String {
        "CALC:LIM:LOW \(format(value))"
    }

    public static func setUpperLimit(_ value: Double) -> String {
        "CALC:LIM:UPP \(format(value))"
    }

    // MARK: Display and beeper

    public static let displayOn = "DISP ON"
    public static let displayOff = "DISP OFF"
    public static let displayTextClear = "DISP:TEXT:CLE"

    /// The front panel takes up to twelve characters.
    public static func displayText(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\"", with: " ")
        return "DISP:TEXT \"\(String(cleaned.prefix(12)))\""
    }

    public static let beep = "SYST:BEEP"

    public static func setBeeper(_ enabled: Bool) -> String {
        "SYST:BEEP:STAT \(enabled ? "ON" : "OFF")"
    }

    // MARK: Status

    public static let questionableCondition = "STAT:QUES:COND?"

    /// Joins several queries into one IEEE 488.2 compound message.
    ///
    /// At 9600 baud a round trip costs several milliseconds before the meter has
    /// even started measuring, and a polling pass that asks six separate
    /// questions pays that six times. A compound message asks them all at once
    /// and gets one reply with the answers separated by semicolons.
    ///
    /// The leading colon on each subsequent header matters: within a compound
    /// message the meter keeps the current subsystem path, so `VOLT:DC:RANG?`
    /// after `FUNC?` would be looked up relative to the root anyway, but after
    /// `VOLT:DC:NPLC?` it would not. Sending every header from the root removes
    /// the question. Common commands carry no path and take a bare semicolon.
    public static func compound(_ commands: [String]) -> String {
        guard var line = commands.first else { return "" }
        for command in commands.dropFirst() {
            line += command.hasPrefix("*") ? ";" + command : ";:" + command
        }
        return line
    }

    /// Fixed-notation, period-decimal formatting. The meter rejects the comma
    /// decimal separator some locales would otherwise produce.
    public static func format(_ value: Double) -> String {
        String(format: "%.6G", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum SCPIParse {
    /// What the meter sends instead of a reading when the input is past full
    /// scale on the selected range: `+9.90000000E+37`.
    public static let overloadSentinel = 9.9e37

    public static func number(_ response: String?) -> Double? {
        guard let response else { return nil }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Splits the comma-separated burst a `READ?` with `SAMPle:COUNt` > 1 returns.
    /// Anything unparseable is dropped rather than poisoning the series.
    public static func numbers(_ response: String?) -> [Double] {
        guard let response else { return [] }
        return response
            .split(separator: ",")
            .compactMap { number(String($0)) }
    }

    public static func isOverload(_ value: Double) -> Bool {
        abs(value) >= overloadSentinel * 0.99
    }

    /// Splits the reply to a compound message. Returns nil unless exactly
    /// `expected` fields came back — a short reply means the meter did not
    /// understand the message, and guessing which answer is missing would be
    /// worse than falling back to separate queries.
    public static func compoundFields(_ response: String?, expected: Int) -> [String]? {
        guard let response, expected > 0 else { return nil }
        let fields = response
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return fields.count == expected ? fields : nil
    }

    public static func integer(_ response: String?) -> Int? {
        guard let value = number(response) else { return nil }
        return Int(value.rounded())
    }

    /// `ON`, `1` and `+1` all mean the same thing depending on which query asked.
    public static func boolean(_ response: String?) -> Bool? {
        guard let response else { return nil }
        let token = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if token == "ON" || token == "1" || token == "+1" { return true }
        if token == "OFF" || token == "0" || token == "+0" { return false }
        return nil
    }

    /// Snaps a range read back from the meter to the nearest nominal range, so
    /// `+1.00000000E+01` becomes exactly 10 and matches a picker entry.
    public static func nearestRange(_ value: Double, in ranges: [Double]) -> Double? {
        guard value.isFinite, !ranges.isEmpty else { return nil }
        return ranges.min { abs($0 - value) < abs($1 - value) }
    }

    public static func nearestIntegrationTime(_ value: Double) -> IntegrationTime? {
        IntegrationTime.allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) }
    }

    public static func nearestGateTime(_ value: Double) -> GateTime? {
        GateTime.allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) }
    }
}

/// Decoded `STATus:QUEStionable:CONDition?`.
public struct QuestionableStatus: Equatable, Sendable {
    public let condition: Int

    public init(condition: Int) {
        self.condition = condition
    }

    public var isClear: Bool { condition == 0 }

    public var voltageOverload: Bool { condition & 0x0001 != 0 }
    public var currentOverload: Bool { condition & 0x0002 != 0 }
    public var resistanceOverload: Bool { condition & 0x0200 != 0 }
    public var limitFailedLow: Bool { condition & 0x0800 != 0 }
    public var limitFailedHigh: Bool { condition & 0x1000 != 0 }

    public var isOverload: Bool {
        voltageOverload || currentOverload || resistanceOverload
    }

    public var limitFailed: Bool { limitFailedLow || limitFailedHigh }

    public var labels: [String] {
        var labels: [String] = []
        if voltageOverload { labels.append("Voltage Overload") }
        if currentOverload { labels.append("Current Overload") }
        if resistanceOverload { labels.append("Ohms Overload") }
        if limitFailedLow { labels.append("Limit Failed LO") }
        if limitFailedHigh { labels.append("Limit Failed HI") }
        if labels.isEmpty && condition != 0 { labels.append("Questionable (\(condition))") }
        return labels
    }
}

/// What `*IDN?` said about the meter on the other end of the cable.
public struct DeviceIdentity: Equatable, Sendable {
    public let rawIdentification: String
    public let manufacturer: String
    public let model: String
    public let firmware: String

    public init(rawIdentification: String, manufacturer: String, model: String, firmware: String) {
        self.rawIdentification = rawIdentification
        self.manufacturer = manufacturer
        self.model = model
        self.firmware = firmware
    }

    /// `HEWLETT-PACKARD,34401A,0,11-5-2` becomes manufacturer `HEWLETT-PACKARD`,
    /// model `HP34401A` and firmware `11-5-2`.
    public static func parse(_ identification: String) -> DeviceIdentity {
        let fields = identification
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count >= 2 else {
            let text = identification.trimmingCharacters(in: .whitespaces)
            return DeviceIdentity(rawIdentification: identification, manufacturer: "", model: text, firmware: "")
        }

        let manufacturer = fields[0]
        let bare = fields[1]
        // Agilent and Keysight units answer with their own name; prefixing "HP"
        // to a model that is already spelled out would read oddly.
        let model = manufacturer.uppercased().hasPrefix("HEWLETT") ? "HP" + bare : bare

        return DeviceIdentity(
            rawIdentification: identification,
            manufacturer: manufacturer,
            model: model.isEmpty ? identification : model,
            firmware: fields.count >= 4 ? fields[3] : ""
        )
    }

    /// True for anything that claims to be a 34401A, whoever built it.
    public var isMultimeter: Bool {
        model.uppercased().contains("34401")
    }
}
