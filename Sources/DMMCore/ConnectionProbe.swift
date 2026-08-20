import Foundation

/// One-shot operations from the connection window. Each opens the port, does its
/// business and closes again, so the port stays free until the user connects.
public enum ConnectionProbe {
    /// Confirms the port can be opened at all — the equivalent of double-clicking
    /// a COM port in the Windows list to see whether it is free.
    public static func checkAvailability(path: String) throws {
        let port = SerialPort(config: SerialConfig(path: path))
        try port.open()
        port.close()
    }

    /// Full handshake: remote mode, then `*IDN?`.
    public static func identify(config: SerialConfig) throws -> DeviceIdentity {
        let device = DMMDevice(config: config)
        try device.open()
        defer { device.close() }
        return try device.identify()
    }

    /// "Device Info" — reads `*IDN?` and echoes the port name on the front panel
    /// so it is obvious which of several meters just answered.
    public static func deviceInfo(config: SerialConfig) throws -> String {
        let device = DMMDevice(config: config)
        try device.open()
        defer { device.close() }

        guard let identification = device.probeIdentification(), !identification.isEmpty else {
            throw DMMDeviceError.noResponse
        }

        try? device.send(SCPI.displayText((config.path as NSString).lastPathComponent))
        let version = device.query(SCPI.versionQuery)
        return version.map { "\(identification)  ·  SCPI \($0)" } ?? identification
    }

    /// Sends `*RST` without connecting — useful when the meter was left mid-burst
    /// by something else and will not answer cleanly.
    public static func reset(config: SerialConfig) throws {
        let device = DMMDevice(config: config)
        try device.open()
        defer { device.close() }
        try device.clearInterface()
        try device.send(SCPI.remote)
        try device.send(SCPI.reset)
        try device.send(SCPI.clearStatus)
    }
}
