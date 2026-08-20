import Foundation
import Darwin

/// A POSIX pseudo-terminal pair.
///
/// The simulator holds the master side and speaks SCPI; the application opens
/// the slave path (`/dev/ttysNNN`) exactly as it would open a USB-serial adapter,
/// so every layer below the UI — termios setup, line framing, timeouts — is
/// exercised for real without any hardware attached.
public final class PseudoTerminal {
    public let masterDescriptor: Int32
    /// Device path the client should open, e.g. `/dev/ttys004`.
    public let slavePath: String

    public init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PseudoTerminalError.openFailed(errno) }

        guard grantpt(master) == 0 else {
            let code = errno
            close(master)
            throw PseudoTerminalError.grantFailed(code)
        }
        guard unlockpt(master) == 0 else {
            let code = errno
            close(master)
            throw PseudoTerminalError.unlockFailed(code)
        }
        guard let name = ptsname(master) else {
            let code = errno
            close(master)
            throw PseudoTerminalError.nameFailed(code)
        }

        self.masterDescriptor = master
        self.slavePath = String(cString: name)

        // Hold the slave open ourselves so the master never sees EOF between the
        // client closing and reconnecting, and put it in raw mode so nothing is
        // echoed back to the client as a phantom response.
        let slave = Darwin.open(slavePath, O_RDWR | O_NOCTTY)
        if slave >= 0 {
            var options = termios()
            if tcgetattr(slave, &options) == 0 {
                cfmakeraw(&options)
                options.c_cc.16 = 0 // VMIN
                options.c_cc.17 = 0 // VTIME
                _ = tcsetattr(slave, TCSANOW, &options)
            }
            slaveDescriptor = slave
        }
    }

    private var slaveDescriptor: Int32 = -1

    deinit {
        close(masterDescriptor)
        if slaveDescriptor >= 0 { close(slaveDescriptor) }
    }
}

public enum PseudoTerminalError: Error, LocalizedError {
    case openFailed(Int32)
    case grantFailed(Int32)
    case unlockFailed(Int32)
    case nameFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "posix_openpt failed: \(String(cString: strerror(code)))"
        case .grantFailed(let code): return "grantpt failed: \(String(cString: strerror(code)))"
        case .unlockFailed(let code): return "unlockpt failed: \(String(cString: strerror(code)))"
        case .nameFailed(let code): return "ptsname failed: \(String(cString: strerror(code)))"
        }
    }
}
