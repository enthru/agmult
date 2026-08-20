import SwiftUI
import DMMCore

/// Port picker — the macOS counterpart of the Windows "Select COM Port" window.
/// Ports are `/dev/cu.*` callout devices rather than COM numbers, and the
/// built-in simulator can stand in for hardware.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var ports: [SerialPortInfo] = []
    @State private var selection: SerialPortInfo.ID?
    @State private var config = SerialConfig(path: "")
    @State private var message = ""
    @State private var messageIsError = false
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                portList
                settingsForm
            }

            HStack(spacing: 10) {
                Group {
                    Button("Use Built-in Simulator", action: useSimulator)
                    Spacer()
                    Button("Device Info", action: readDeviceInfo)
                    Button("Reset Device", action: resetDevice)
                }
                .disabled(isBusy)

                // Esc closes the sheet, Return connects — the usual pair.
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(messageIsError ? Color.red : Color.green)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(height: 42, alignment: .topLeading)
        }
        .padding(16)
        .frame(width: 720, height: 400)
        .onAppear(perform: refresh)
    }

    private var portList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Serial Ports").font(.headline)
                Spacer()
                Button("Refresh", action: refresh)
                    .keyboardShortcut("r", modifiers: .command)
            }
            List(ports, selection: $selection) { port in
                Text(port.display)
                    .font(.system(size: 11))
                    .tag(port.id)
            }
            .frame(width: 330)
            .onChange(of: selection) {
                guard let selection, let port = ports.first(where: { $0.id == selection }) else { return }
                config.path = port.path
                checkAvailability(of: port.path)
            }
            Text("Callout devices (/dev/cu.*). USB-serial adapters appear once their driver is loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 330, alignment: .leading)
        }
    }

    private var settingsForm: some View {
        Form {
            TextField("Device path", text: $config.path)

            Picker("Bits per second", selection: $config.baudRate) {
                ForEach(SerialConfig.supportedBaudRates, id: \.self) { rate in
                    Text(String(rate)).tag(rate)
                }
            }
            // The meter couples parity and word length: none goes with eight
            // data bits, even and odd with seven. Offering them separately would
            // only let the user build a combination it cannot speak.
            Picker("Parity", selection: $config.parity) {
                ForEach(SerialParity.allCases, id: \.self) { parity in
                    Text(parity.pairLabel).tag(parity)
                }
            }
            Picker("Stop bits", selection: $config.stopBits) {
                ForEach(SerialStopBits.allCases, id: \.self) { bits in
                    Text(bits.label).tag(bits)
                }
            }
            Picker("Flow control", selection: $config.flowControl) {
                ForEach(SerialFlowControl.allCases, id: \.self) { flow in
                    Text(flow.label).tag(flow)
                }
            }

            Section {
                Text("Factory settings are 9600 baud, even parity with seven data bits and two stop bits. The meter handshakes on DTR/DSR, which macOS cannot gate on — leave flow control at None; at these rates it makes no difference.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 330)
    }

    // MARK: - Actions

    private func refresh() {
        ports = SerialPortLister.list()
        if let path = model.simulatorPath, !ports.contains(where: { $0.path == path }) {
            ports.append(SerialPortInfo(path: path, name: "Built-in simulator"))
        }

        // Offer last time's port and line settings again, if it is still there.
        if config.path.isEmpty, let previous = model.lastConnection,
           ports.contains(where: { $0.path == previous.path }) {
            config = previous
            selection = previous.path
            show("Last used: \(previous.path). Press Return to connect.", isError: false)
        }
    }

    private func useSimulator() {
        guard let path = model.startSimulator() else {
            show("Could not start the simulator.", isError: true)
            return
        }
        config.path = path
        refresh()
        selection = path
        show("Simulator running on \(path). Click Connect.", isError: false)
    }

    private func checkAvailability(of path: String) {
        run({ try ConnectionProbe.checkAvailability(path: path) },
            success: { _ in show("\(path) is ready. Click Device Info or Connect.", isError: false) })
    }

    private func readDeviceInfo() {
        let config = config
        run({ try ConnectionProbe.deviceInfo(config: config) },
            success: { info in show(info, isError: false) })
    }

    private func resetDevice() {
        let config = config
        run({ try ConnectionProbe.reset(config: config) },
            success: { _ in show("Reset command sent.", isError: false) })
    }

    private func connect() {
        let config = config
        run({ try ConnectionProbe.identify(config: config) },
            success: { identity in
                model.controller.connect(config: config, identity: identity)
                model.lastConnection = config
                dismiss()
            })
    }

    /// Serial work blocks, so it runs off the main actor; only the result
    /// touches the UI.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                  success: @escaping (T) -> Void) {
        guard !config.path.isEmpty else {
            show("Choose a serial port first.", isError: true)
            return
        }
        isBusy = true
        message = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            isBusy = false
            switch result {
            case .success(let value):
                success(value)
            case .failure(let error):
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
