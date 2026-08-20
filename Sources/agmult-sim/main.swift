import Foundation
import DMMCore
import DMMSimulator

// Command line front end for the multimeter simulator. Prints the device path
// to connect to and then traces the SCPI conversation until interrupted.

// Line-buffer stdout so the trace still appears when the output is piped to a
// file or another program rather than a terminal.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
var inputValue: Double?
var modulation = SimulatedSignal.Modulation.drift
var modulationDepth = 0.02
var modulationPeriod = 30.0
var lineFrequency = 50.0
var realTime = true
var verbose = true

func usage() -> String {
    """
    agmult-sim — HP/Agilent/Keysight 34401A multimeter simulator

    Usage: agmult-sim [options]

      --volts, -v VALUE   DC volts on the input (default 4.19)
      --shape SHAPE       \(SimulatedSignal.Modulation.allCases.map(\.rawValue).joined(separator: " | "))
      --depth FRACTION    Modulation amplitude as a fraction (default 0.02)
      --period SECONDS    Modulation period (default 30)
      --line HERTZ        Mains frequency for integration timing (default 50)
      --fast              Answer immediately instead of taking as long as a
                          real acquisition would
      --quiet, -q         Do not trace SCPI traffic

    Connect the app to the device path printed on start-up.
    """
}

var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--volts", "-v":
        index += 1
        if index < arguments.count { inputValue = Double(arguments[index]) }
    case "--shape":
        index += 1
        if index < arguments.count, let shape = SimulatedSignal.Modulation(rawValue: arguments[index].lowercased()) {
            modulation = shape
        }
    case "--depth":
        index += 1
        if index < arguments.count, let value = Double(arguments[index]) { modulationDepth = value }
    case "--period":
        index += 1
        if index < arguments.count, let value = Double(arguments[index]) { modulationPeriod = value }
    case "--line":
        index += 1
        if index < arguments.count, let value = Double(arguments[index]) { lineFrequency = value }
    case "--fast":
        realTime = false
    case "--quiet", "-q":
        verbose = false
    case "--help", "-h":
        print(usage())
        exit(0)
    default:
        break
    }
    index += 1
}

let signal = SimulatedSignal()
if let inputValue { signal[.dcVoltage] = inputValue }
signal.modulation = modulation
signal.modulationDepth = modulationDepth
signal.modulationPeriod = modulationPeriod

let meter = Simulated34401A(signal: signal)
meter.simulatesTiming = realTime
meter.lineFrequency = lineFrequency

do {
    let server = try SimulatorServer(meter: meter)
    if verbose {
        server.onTraffic = { received, replied in
            let command = received.trimmingCharacters(in: .whitespacesAndNewlines)
            if let replied {
                // A burst of a hundred readings would drown the trace.
                let shown = replied.count > 90 ? String(replied.prefix(90)) + "…" : replied
                print("  \(command)  ->  \(shown)")
            } else {
                print("  \(command)")
            }
        }
    }
    server.start()

    print("Simulated HP34401A ready.")
    print("  Device path : \(server.devicePath)")
    print("  DC input    : \(Format.engineering(signal[.dcVoltage], unit: "V"))")
    print("  Shape       : \(modulation.title), ±\(Format.number(modulationDepth * 100, 1))% over \(Format.number(modulationPeriod, 0)) s")
    print("  Timing      : \(realTime ? "real, \(Format.number(lineFrequency, 0)) Hz mains" : "immediate")")
    print("  Settings    : 9600 8N1 or 7E2 — the pty ignores line settings")
    print("Press Ctrl-C to stop.")

    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("Failed to start simulator: \(error.localizedDescription)\n".utf8))
    exit(1)
}
