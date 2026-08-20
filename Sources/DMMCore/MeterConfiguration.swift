import Foundation

/// Everything about how the meter is currently taking a reading.
///
/// The application keeps this as the intended state and sends it down as a list
/// of commands; the polling loop reads the same values back, so what the panel
/// shows is what the instrument is actually doing, even if somebody presses a
/// button on the front panel.
public struct MeterConfiguration: Sendable, Equatable, Codable {
    public var function: MeasurementFunction = .dcVoltage
    public var autoRange = true
    public var range: Double = 10
    public var integrationTime: IntegrationTime = .normal
    public var gateTime: GateTime = .ms100
    public var bandwidth: ACBandwidth = .medium
    public var autoZero: AutoZero = .on
    /// >10 GΩ input on the 100 mV, 1 V and 10 V DC ranges instead of 10 MΩ.
    public var highInputImpedance = false
    public var triggerSource: TriggerSource = .immediate
    public var triggerDelayAuto = true
    public var triggerDelay: Double = 0
    /// Readings the meter takes per trigger. Every one of them costs nothing
    /// extra in serial round trips, which is where the sample rate comes from.
    public var sampleCount: Int = 1

    public static let sampleCountChoices = [1, 2, 5, 10, 20, 50, 100]

    public init() {}

    /// Digits the current settings resolve to.
    public var digits: Int {
        if function.usesAperture { return gateTime.digits }
        if function.usesIntegrationTime { return integrationTime.digits }
        // AC and the fixed functions always read at 6½ digits.
        return 6
    }

    /// The range in force, or nil while auto-ranging has not reported one yet.
    public var effectiveRange: Double? {
        function.hasSelectableRange ? range : function.ranges.first
    }

    /// Commands that put the meter into this state from whatever it was in.
    ///
    /// `CONFigure` goes first because it resets the function's own range and
    /// resolution to defaults — everything after it is deliberate.
    public func commands(includeFunction: Bool = true) -> [String] {
        var commands: [String] = []

        if includeFunction {
            commands.append(SCPI.configure(function))
        }

        if function.hasSelectableRange {
            if autoRange {
                commands.append(SCPI.setAutoRange(function, true))
            } else {
                // Setting an explicit range switches auto-ranging off by itself,
                // but saying so makes the read-back unambiguous.
                commands.append(SCPI.setAutoRange(function, false))
                commands.append(SCPI.setRange(function, range))
            }
        }

        if function.usesIntegrationTime {
            commands.append(SCPI.setIntegrationTime(function, integrationTime))
        }
        if function.usesAperture {
            commands.append(SCPI.setAperture(function, gateTime))
        }
        if function.usesBandwidth {
            commands.append(SCPI.setBandwidth(bandwidth))
        }
        if function.usesIntegrationTime {
            commands.append(SCPI.setAutoZero(autoZero))
        }
        if function.usesInputImpedance {
            commands.append(SCPI.setInputImpedanceAuto(highInputImpedance))
        }

        commands.append(contentsOf: triggerCommands)
        return commands
    }

    public var triggerCommands: [String] {
        var commands = [SCPI.setTriggerSource(triggerSource)]
        commands.append(SCPI.setTriggerDelayAuto(triggerDelayAuto))
        if !triggerDelayAuto {
            commands.append(SCPI.setTriggerDelay(triggerDelay))
        }
        commands.append(SCPI.setSampleCount(sampleCount))
        commands.append(SCPI.setTriggerCount(1))
        return commands
    }

    /// Roughly how long one burst takes inside the meter, before serial overhead.
    /// Used to keep the polling interval from being shorter than the meter can
    /// possibly answer in.
    public func estimatedBurstDuration(lineFrequency: Double = 50) -> TimeInterval {
        let perReading: TimeInterval
        if function.usesAperture {
            perReading = gateTime.rawValue + 0.02
        } else if function.usesIntegrationTime {
            perReading = integrationTime.rawValue / lineFrequency + (autoZero == .on ? integrationTime.rawValue / lineFrequency : 0) + 0.002
        } else {
            perReading = 0.02
        }
        return perReading * Double(sampleCount)
    }
}

/// The meter's own maths, which runs on the readings before they are sent.
public struct MathConfiguration: Sendable, Equatable, Codable {
    public var function: MathFunction = .none
    /// Subtracted from every reading, in the measurement's own unit.
    public var nullOffset: Double = 0
    /// The dB function is relative: this is the reference level, in dBm.
    public var decibelReference: Double = 0
    /// dBm is referred to a load; this is that load, in ohms.
    public var dBmReference: Double = 600
    public var lowerLimit: Double = -1
    public var upperLimit: Double = 1

    /// The load resistances the meter accepts for dBm.
    public static let dBmReferenceChoices: [Double] = [
        50, 75, 93, 110, 124, 125, 135, 150, 250, 300, 500, 600, 800, 900, 1000, 1200, 8000,
    ]

    public init() {}

    public var isEnabled: Bool { function != .none }

    public func commands() -> [String] {
        guard let keyword = function.scpiKeyword else {
            return [SCPI.setMathState(false)]
        }

        var commands = [SCPI.setMathFunction(keyword)]
        switch function {
        case .null:
            commands.append(SCPI.setNullOffset(nullOffset))
        case .decibel:
            commands.append(SCPI.setDecibelReference(decibelReference))
        case .dBm:
            commands.append(SCPI.setDBmReference(dBmReference))
        case .limit:
            commands.append(SCPI.setLowerLimit(lowerLimit))
            commands.append(SCPI.setUpperLimit(upperLimit))
        case .statistics, .none:
            break
        }
        commands.append(SCPI.setMathState(true))
        return commands
    }
}

/// Min, max, mean and count as the *meter* accumulated them — a separate tally
/// from the history this application keeps, and the one that keeps counting
/// while the app is not asking for readings.
public struct InstrumentStatistics: Sendable, Equatable {
    public var minimum: Double?
    public var maximum: Double?
    public var average: Double?
    public var count: Int?

    public init(minimum: Double? = nil, maximum: Double? = nil, average: Double? = nil, count: Int? = nil) {
        self.minimum = minimum
        self.maximum = maximum
        self.average = average
        self.count = count
    }

    public var isEmpty: Bool {
        minimum == nil && maximum == nil && average == nil && (count ?? 0) == 0
    }
}
