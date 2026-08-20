import Foundation
import Darwin

/// Parity modes supported by macOS `termios`.
///
/// On the 34401A parity and word length are not independent: the front-panel
/// I/O menu offers *None with 8 data bits*, *Even with 7* or *Odd with 7*, and
/// nothing else. `SerialParity.dataBits` encodes that pairing so the connection
/// window cannot produce a combination the meter will not speak.
public enum SerialParity: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case odd = 1
    case even = 2

    public var label: String {
        switch self {
        case .none: return "None"
        case .odd: return "Odd"
        case .even: return "Even"
        }
    }

    /// The word length the meter uses with this parity.
    public var dataBits: Int {
        self == .none ? 8 : 7
    }

    /// `Even / 7 data bits` — how the pairing is shown in the port picker.
    public var pairLabel: String {
        "\(label) / \(dataBits) data bits"
    }
}

public enum SerialStopBits: Int, CaseIterable, Codable, Sendable {
    case one = 1
    case two = 2

    public var label: String { self == .one ? "1" : "2" }
}

public enum SerialFlowControl: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case xonXoff = 1
    case hardware = 2

    public var label: String {
        switch self {
        case .none: return "None"
        case .xonXoff: return "Xon/Xoff"
        case .hardware: return "RTS/CTS"
        }
    }
}

public struct SerialConfig: Codable, Sendable, Equatable {
    public var path: String
    public var baudRate: Int
    public var parity: SerialParity
    public var stopBits: SerialStopBits
    public var flowControl: SerialFlowControl
    /// Maximum time to wait for a complete response line.
    public var readTimeout: TimeInterval
    public var writeTimeout: TimeInterval

    /// The meter's own list. It has no 19200 or faster setting, so offering one
    /// would only invite a mismatch.
    public static let supportedBaudRates = [300, 600, 1200, 2400, 4800, 9600]

    public var dataBits: Int { parity.dataBits }

    /// The 34401A's factory configuration: 9600 baud, even parity, seven data
    /// bits, two stop bits.
    public init(path: String = "",
                baudRate: Int = 9600,
                parity: SerialParity = .even,
                stopBits: SerialStopBits = .two,
                flowControl: SerialFlowControl = .none,
                readTimeout: TimeInterval = 3.0,
                writeTimeout: TimeInterval = 2.0) {
        self.path = path
        self.baudRate = baudRate
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
    }
}

public enum SerialError: Error, LocalizedError, Equatable {
    case openFailed(path: String, errno: Int32)
    case notOpen
    case configFailed(stage: String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            let reason = String(cString: strerror(code))
            if code == EBUSY {
                return "\(path) is already in use by another program."
            }
            if code == ENOENT {
                return "\(path) does not exist."
            }
            if code == EACCES {
                return "No permission to open \(path)."
            }
            return "Cannot open \(path): \(reason)."
        case .notOpen:
            return "The serial port is not open."
        case .configFailed(let stage, let code):
            return "Serial configuration failed at \(stage): \(String(cString: strerror(code)))."
        case .writeFailed(let code):
            return "Serial write failed: \(String(cString: strerror(code)))."
        case .readFailed(let code):
            return "Serial read failed: \(String(cString: strerror(code)))."
        case .timedOut:
            return "Timed out waiting for a response from the meter."
        }
    }
}

/// A blocking, line oriented RS-232 port built directly on POSIX `termios`.
///
/// Commands go out with a trailing LF and `readLine` returns everything up to
/// the next LF; the 34401A answers with CRLF, so the leftover CR is trimmed.
///
/// Seven-bit words need one extra courtesy: with even or odd parity the meter
/// sends the eighth bit as parity, and `ISTRIP` is set so it never reaches the
/// parser as part of a character.
///
/// Not thread safe: drive one port from one thread (the polling worker).
public final class SerialPort {
    private var fd: Int32 = -1
    private var savedTermios = termios()
    private var pending: [UInt8] = []

    public private(set) var config: SerialConfig
    public var isOpen: Bool { fd >= 0 }

    public init(config: SerialConfig) {
        self.config = config
    }

    deinit {
        close()
    }

    public func open() throws {
        guard fd < 0 else { return }

        // O_NONBLOCK keeps open() from hanging on a port whose DCD is low; it is
        // cleared again once the line is configured.
        let handle = Darwin.open(config.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(path: config.path, errno: errno)
        }

        // Claim the port so a second instance of the app cannot fight over it.
        if ioctl(handle, TIOCEXCL) == -1 {
            let code = errno
            Darwin.close(handle)
            throw SerialError.openFailed(path: config.path, errno: code)
        }

        // O_NONBLOCK deliberately stays set. Both `readLine` and `write` keep
        // their own deadlines, and a port whose other end has stopped listening
        // must time out rather than park a thread in the kernel forever.

        guard tcgetattr(handle, &savedTermios) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "tcgetattr", errno: code)
        }

        var options = savedTermios
        cfmakeraw(&options)

        options.c_cflag |= tcflag_t(CREAD | CLOCAL)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(config.dataBits == 7 ? CS7 : CS8)

        switch config.parity {
        case .none:
            options.c_cflag &= ~tcflag_t(PARENB | PARODD)
            options.c_iflag &= ~tcflag_t(INPCK | ISTRIP)
        case .even:
            options.c_cflag |= tcflag_t(PARENB)
            options.c_cflag &= ~tcflag_t(PARODD)
            options.c_iflag |= tcflag_t(INPCK | ISTRIP)
        case .odd:
            options.c_cflag |= tcflag_t(PARENB | PARODD)
            options.c_iflag |= tcflag_t(INPCK | ISTRIP)
        }

        if config.stopBits == .two {
            options.c_cflag |= tcflag_t(CSTOPB)
        } else {
            options.c_cflag &= ~tcflag_t(CSTOPB)
        }

        switch config.flowControl {
        case .none:
            options.c_cflag &= ~tcflag_t(CRTSCTS)
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        case .xonXoff:
            options.c_cflag &= ~tcflag_t(CRTSCTS)
            options.c_iflag |= tcflag_t(IXON | IXOFF)
        case .hardware:
            options.c_cflag |= tcflag_t(CRTSCTS)
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        }

        // VMIN/VTIME do not apply to a non-blocking descriptor; they are set to
        // the fully non-blocking pair anyway so the line discipline agrees with
        // the file status flags.
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 0 // VTIME

        guard cfsetspeed(&options, speed_t(config.baudRate)) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "cfsetspeed", errno: code)
        }

        guard tcsetattr(handle, TCSANOW, &options) == 0 else {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configFailed(stage: "tcsetattr", errno: code)
        }

        // The meter gates its transmitter on DSR, which it expects to see driven
        // from our DTR. Darwin has no DTR/DSR flow-control mode, so assert DTR
        // once and leave it asserted for as long as the port is open — which is
        // what every terminal program does and what the meter is waiting for.
        var lines: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(handle, TIOCMBIS, &lines)

        fd = handle
        pending.removeAll(keepingCapacity: true)
        tcflush(fd, TCIOFLUSH)
    }

    public func close() {
        guard fd >= 0 else { return }
        // Give the last command — usually SYSTem:LOCal — a moment to go out, but
        // never wait on a port nobody is reading.
        drainOutput(timeout: 0.5)
        tcsetattr(fd, TCSANOW, &savedTermios)
        Darwin.close(fd)
        fd = -1
        pending.removeAll(keepingCapacity: true)
    }

    /// Waits, up to `timeout`, for the transmit queue to empty.
    ///
    /// `tcdrain` would do this in one call, but on a pseudo-terminal — or on a
    /// port whose peer has stopped reading — it blocks with no deadline at all,
    /// which is how a hung instrument turns into a hung thread.
    private func drainOutput(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var queued: Int32 = 0
            guard ioctl(fd, TIOCOUTQ, &queued) == 0 else { return }
            if queued == 0 { return }
            usleep(2000)
        }
    }

    /// Widens or narrows the response deadline for the reads that follow.
    /// A burst of a hundred readings at 100 PLC legitimately takes minutes, and
    /// the same port has to fall back to a couple of seconds for a `*IDN?`.
    public func setReadTimeout(_ timeout: TimeInterval) {
        config.readTimeout = max(0.2, timeout)
    }

    /// Discards anything the meter has already queued but nobody asked for.
    /// Called before a query so a stale reading cannot be mistaken for the answer.
    public func flushInput() {
        guard fd >= 0 else { return }
        tcflush(fd, TCIFLUSH)
        pending.removeAll(keepingCapacity: true)
    }

    /// Writes `command` followed by LF and waits for it to leave the UART.
    public func writeLine(_ command: String) throws {
        try write(bytes: Array((command + "\n").utf8))
    }

    /// Sends a bare byte — used for the Ctrl-C that clears a wedged interface.
    public func write(byte: UInt8) throws {
        try write(bytes: [byte])
    }

    private func write(bytes: [UInt8]) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        let deadline = Date().addingTimeInterval(config.writeTimeout)
        var offset = 0

        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    if Date() > deadline { throw SerialError.timedOut }
                    usleep(2000)
                    continue
                }
                throw SerialError.writeFailed(errno: errno)
            }
            if Date() > deadline { throw SerialError.timedOut }
        }
    }

    /// Reads up to the next LF. Returns the line without its terminator, with any
    /// trailing CR removed. Throws `.timedOut` if the meter stays quiet.
    public func readLine() throws -> String {
        guard fd >= 0 else { throw SerialError.notOpen }
        let deadline = Date().addingTimeInterval(config.readTimeout)
        var buffer = [UInt8](repeating: 0, count: 512)

        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let lineBytes = Array(pending[pending.startIndex..<index])
                pending.removeSubrange(pending.startIndex...index)
                let line = String(decoding: lineBytes, as: UTF8.self)
                return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\0 \t"))
            }

            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                Darwin.read(fd, pointer.baseAddress!, pointer.count)
            }

            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EINTR {
                throw SerialError.readFailed(errno: errno)
            }
            if Date() > deadline {
                throw SerialError.timedOut
            }
            // Nothing there yet. A short sleep costs a fraction of a millisecond
            // of latency and saves a core from spinning at full tilt.
            usleep(500)
        }
    }

    /// Sends a query and returns the meter's answer.
    public func query(_ command: String) throws -> String {
        flushInput()
        try writeLine(command)
        return try readLine()
    }
}
