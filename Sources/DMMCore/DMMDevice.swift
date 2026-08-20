import Foundation

/// Blocking SCPI transport for one multimeter. Every call performs real serial
/// I/O, so this type must only be used from the polling worker thread — never
/// from the main actor.
public final class DMMDevice {
    private let port: SerialPort

    public var config: SerialConfig { port.config }
    public var isOpen: Bool { port.isOpen }

    /// The response deadline the user configured, kept aside because
    /// `setReadTimeout` moves the live one about as the loop runs.
    public let baseReadTimeout: TimeInterval

    public init(config: SerialConfig) {
        self.port = SerialPort(config: config)
        self.baseReadTimeout = config.readTimeout
    }

    public func open() throws {
        try port.open()
    }

    public func close() {
        // Hand the front panel back before letting go of the line: a meter left
        // in remote mode ignores its own buttons until somebody presses LOCAL.
        try? port.writeLine(SCPI.local)
        port.close()
    }

    /// Widens the response deadline for a burst that will legitimately take a
    /// long time to come back.
    public func setReadTimeout(_ timeout: TimeInterval) {
        port.setReadTimeout(timeout)
    }

    public func send(_ command: String) throws {
        try port.writeLine(command)
    }

    public func send(_ commands: [String]) throws {
        for command in commands {
            try send(command)
        }
    }

    /// Returns the meter's response, or nil when it stayed silent.
    public func query(_ command: String) -> String? {
        do {
            return try port.query(command)
        } catch {
            return nil
        }
    }

    public func queryNumber(_ command: String) -> Double? {
        SCPIParse.number(query(command))
    }

    /// Asks several questions in one round trip.
    ///
    /// Every element must be a query — a command that produces no reply would
    /// leave the answers misaligned, and there is no way to tell from the reply
    /// which one went missing. Returns nil when the meter's answer does not have
    /// exactly one field per question, so the caller can fall back to asking
    /// separately rather than reading someone else's answer.
    public func queryCompound(_ commands: [String]) -> [String]? {
        guard !commands.isEmpty else { return nil }
        guard commands.count > 1 else { return query(commands[0]).map { [$0] } }
        return SCPIParse.compoundFields(query(SCPI.compound(commands)), expected: commands.count)
    }

    /// A query the caller wants to hear about when it fails, rather than one
    /// that quietly returns nil — used during connection setup.
    public func requireQuery(_ command: String) throws -> String {
        try port.query(command)
    }

    /// Ctrl-C: abandons whatever the interface was doing and discards output the
    /// meter had queued. The way back from a half-read burst.
    public func clearInterface() throws {
        try port.write(byte: SCPI.interfaceClear)
        port.flushInput()
    }

    /// Takes the meter into remote mode and finds out what it is.
    ///
    /// `SYSTem:REMote` is not optional over RS-232. Without it the front panel
    /// stays in charge, and the manual warns that traffic in that state "can
    /// cause unpredictable results" — which in practice means readings that
    /// arrive out of step with the commands that asked for them.
    public func identify() throws -> DeviceIdentity {
        try send(SCPI.remote)
        try send(SCPI.clearStatus)

        guard let identification = try? requireQuery(SCPI.identify), !identification.isEmpty else {
            throw DMMDeviceError.noResponse
        }

        let identity = DeviceIdentity.parse(identification)
        guard identity.isMultimeter else {
            throw DMMDeviceError.wrongInstrument(identification)
        }
        return identity
    }

    /// Reads `*IDN?` without claiming the meter for a session — the
    /// "Device Info" button in the connection window.
    public func probeIdentification() -> String? {
        try? send(SCPI.remote)
        return query(SCPI.identify)
    }

    // MARK: - Reading back what the meter is set to

    /// What one field of a configuration read-back describes.
    private enum ConfigurationField {
        case function
        case autoRange
        case range
        case integrationTime
        case aperture
        case bandwidth
    }

    /// The questions worth asking about a given function, and what each answer
    /// means. Built from the function the app believes is selected — which the
    /// first answer then confirms or contradicts.
    private static func configurationQueries(for function: MeasurementFunction) -> [(ConfigurationField, String)] {
        var queries: [(ConfigurationField, String)] = [(.function, SCPI.functionQuery)]
        if function.hasSelectableRange {
            queries.append((.autoRange, SCPI.autoRangeQuery(function)))
            queries.append((.range, SCPI.rangeQuery(function)))
        }
        if function.usesIntegrationTime {
            queries.append((.integrationTime, SCPI.integrationTimeQuery(function)))
        }
        if function.usesAperture {
            queries.append((.aperture, SCPI.apertureQuery(function)))
        }
        if function.usesBandwidth {
            queries.append((.bandwidth, SCPI.bandwidthQuery))
        }
        return queries
    }

    /// Reads the settings the meter is actually using, so the panel can follow a
    /// front-panel change instead of asserting what it last sent.
    ///
    /// The sub-queries name a subsystem — `VOLT:DC:NPLC?` — so they have to be
    /// chosen before the answer to `FUNCtion?` is in. They are built from the
    /// function the application last knew about; if the meter comes back with a
    /// different one, the whole read is repeated against the right subsystem.
    /// That costs one extra round trip on the rare pass where somebody has just
    /// pressed a button on the front panel, and nothing at all otherwise.
    ///
    /// Returns whether the meter answered at all.
    @discardableResult
    public func readConfiguration(into configuration: inout MeterConfiguration,
                                  compound useCompound: Bool = true) -> Bool {
        readConfiguration(into: &configuration, compound: useCompound, allowingRetry: true)
    }

    private func readConfiguration(into configuration: inout MeterConfiguration,
                                   compound useCompound: Bool,
                                   allowingRetry: Bool) -> Bool {
        let assumed = configuration.function
        let queries = Self.configurationQueries(for: assumed)

        let answers: [String?]
        if useCompound, queries.count > 1, let fields = queryCompound(queries.map(\.1)) {
            answers = fields
        } else {
            answers = queries.map { query($0.1) }
        }

        guard answers.contains(where: { $0 != nil }) else { return false }

        // The function is settled first: everything else was asked about the
        // wrong subsystem if it changed.
        if let token = answers.first ?? nil,
           let reported = MeasurementFunction.from(queryToken: token) {
            configuration.function = reported
            if reported != assumed {
                guard allowingRetry else { return true }
                return readConfiguration(into: &configuration, compound: useCompound, allowingRetry: false)
            }
        }

        for (field, answer) in zip(queries.map(\.0), answers).dropFirst() {
            switch field {
            case .function:
                break
            case .autoRange:
                if let auto = SCPIParse.boolean(answer) { configuration.autoRange = auto }
            case .range:
                if let value = SCPIParse.number(answer),
                   let snapped = SCPIParse.nearestRange(value, in: configuration.function.ranges) {
                    configuration.range = snapped
                }
            case .integrationTime:
                if let value = SCPIParse.number(answer),
                   let time = SCPIParse.nearestIntegrationTime(value) {
                    configuration.integrationTime = time
                }
            case .aperture:
                if let value = SCPIParse.number(answer),
                   let gate = SCPIParse.nearestGateTime(value) {
                    configuration.gateTime = gate
                }
            case .bandwidth:
                if let value = SCPIParse.number(answer),
                   let bandwidth = ACBandwidth.allCases.min(by: {
                       abs(Double($0.rawValue) - value) < abs(Double($1.rawValue) - value)
                   }) {
                    configuration.bandwidth = bandwidth
                }
            }
        }
        return true
    }

    public func readInstrumentStatistics(compound useCompound: Bool = true) -> InstrumentStatistics {
        let queries = [SCPI.statisticsMinimum, SCPI.statisticsMaximum,
                       SCPI.statisticsAverage, SCPI.statisticsCount]
        let answers: [String?] = (useCompound ? queryCompound(queries) : nil) ?? queries.map { query($0) }

        return InstrumentStatistics(
            minimum: SCPIParse.number(answers[0]),
            maximum: SCPIParse.number(answers[1]),
            average: SCPIParse.number(answers[2]),
            count: SCPIParse.integer(answers[3])
        )
    }
}

public enum DMMDeviceError: Error, LocalizedError, Equatable {
    case noResponse
    case wrongInstrument(String)

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "No reply from the meter. Check the null-modem adapter and that the front-panel I/O menu is set to RS-232 with a matching baud rate, parity and word length."
        case .wrongInstrument(let identification):
            return "Something answered, but it is not a 34401A: \(identification)"
        }
    }
}
