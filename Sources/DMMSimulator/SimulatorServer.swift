import Foundation
import Darwin

/// Runs a `Simulated34401A` behind a pseudo-terminal on a background thread.
///
/// Point the application at `devicePath` and it will talk to the simulator over
/// a genuine serial line discipline.
public final class SimulatorServer: @unchecked Sendable {
    public let devicePath: String

    private let terminal: PseudoTerminal
    private let meter: Simulated34401A
    private let queue = DispatchQueue(label: "com.agmult.simulator", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var muted = false
    private var pending = [UInt8]()

    /// Called with every command line received and every response sent — used by
    /// the CLI to print a live trace of the conversation.
    public var onTraffic: (@Sendable (_ received: String, _ replied: String?) -> Void)?

    public init(meter: Simulated34401A = Simulated34401A()) throws {
        self.meter = meter
        self.terminal = try PseudoTerminal()
        self.devicePath = terminal.slavePath
    }

    public var simulatedMeter: Simulated34401A { meter }
    public var signal: SimulatedSignal { meter.signal }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.pump() }
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Keeps accepting commands but answers none of them — a meter that has been
    /// switched off, put back into HP-IB mode or had its cable pulled. The line
    /// itself is still there, which is exactly what makes this case awkward:
    /// nothing fails, everything simply times out.
    public var isMute: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return muted
        }
        set {
            lock.lock(); defer { lock.unlock() }
            muted = newValue
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 512)

        while isRunning {
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                read(terminal.masterDescriptor, pointer.baseAddress!, pointer.count)
            }

            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                drain()
                continue
            }

            // EIO means no process currently holds the slave open; EAGAIN means
            // nothing has arrived yet. Both are normal — wait and look again.
            if count <= 0 {
                if errno != EAGAIN && errno != EINTR && errno != EIO && count < 0 {
                    break
                }
                usleep(2000)
            }
        }
    }

    private func drain() {
        while !pending.isEmpty {
            // Ctrl-C arrives on its own, with no terminator behind it, and has to
            // take effect immediately rather than waiting for a line that may
            // never come.
            if pending.first == 0x03 {
                pending.removeFirst()
                _ = meter.respond(to: "\u{03}")
                onTraffic?("<Ctrl-C>", nil)
                continue
            }

            guard let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return }
            let lineBytes = Array(pending[pending.startIndex..<index])
            pending.removeSubrange(pending.startIndex...index)
            guard !lineBytes.isEmpty else { continue }

            let command = String(decoding: lineBytes, as: UTF8.self)
            guard !isMute else {
                onTraffic?(command, nil)
                continue
            }
            let reply = meter.respond(to: command)
            if let reply {
                send(reply)
            }
            onTraffic?(command, reply)
        }
    }

    /// The 34401A terminates its responses with CRLF.
    private func send(_ response: String) {
        let bytes = Array((response + "\r\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer -> Int in
                write(terminal.masterDescriptor, pointer.baseAddress! + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else {
                if errno == EINTR || errno == EAGAIN {
                    usleep(1000)
                    continue
                }
                break
            }
        }
    }
}
