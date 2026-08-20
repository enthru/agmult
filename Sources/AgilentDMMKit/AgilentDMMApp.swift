import SwiftUI
import AppKit
import Combine
import DMMCore
import DMMSimulator

struct AgilentDMMApp: App {
    @State private var model = AppModel()

    init() {
        // Lets the app behave like a normal windowed application even when the
        // binary is run straight out of .build rather than from a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Multimeter", id: "main") {
            MainView()
                .environment(model)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.saveNow()
                }
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            AppCommands(model: model)
        }

        // ⌘, — the standard place for preferences on macOS.
        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Graph", id: "graph") {
            GraphWindow().environment(model)
        }
        .defaultSize(width: 900, height: 560)

        Window("Histogram", id: "histogram") {
            HistogramWindow().environment(model)
        }
        .defaultSize(width: 860, height: 540)

        Window("Stability", id: "stability") {
            StabilityWindow().environment(model)
        }
        .defaultSize(width: 900, height: 620)

        // One window per derived waveform, addressed by its identifier — the
        // count is not known until the user creates them.
        WindowGroup("Math Waveform", id: "waveform", for: UUID.self) { $identifier in
            MathWaveformWindow(waveformID: identifier).environment(model)
        }
        .defaultSize(width: 940, height: 620)

        Window("Serial Connection Help", id: "help-serial") { SerialHelpView() }
        Window("General Help", id: "help-general") { GeneralHelpView() }
        Window("Credits", id: "credits") { CreditsView() }
    }
}

/// What ⌘S does, published by whichever window is frontmost.
struct ExportAction: Equatable {
    let title: String
    let perform: () -> Void

    static func == (lhs: ExportAction, rhs: ExportAction) -> Bool {
        lhs.title == rhs.title
    }
}

struct ExportActionKey: FocusedValueKey {
    typealias Value = ExportAction
}

extension FocusedValues {
    var exportAction: ExportAction? {
        get { self[ExportActionKey.self] }
        set { self[ExportActionKey.self] = newValue }
    }
}

/// The menu bar. Everything in the panels is here too, with the shortcuts a Mac
/// user expects: ⌘, for Settings, ⌘S to save the front window, ⌘O to pick a
/// port, ⌘K to clear the list, ⌘0–⌘3 for the windows.
struct AppCommands: Commands {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.exportAction) private var exportAction

    private var controller: DMMController { model.controller }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .saveItem) {
            Button(exportAction?.title ?? "Export…") { exportAction?.perform() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(exportAction == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Main Window") { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandMenu("Config") {
            Button("Select Serial Port…") { model.isConnectionSheetPresented = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Disconnect") { controller.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Divider()
            Button("Reset Device") { controller.resetDevice() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Button("Self Test") { controller.runSelfTest() }
                .disabled(!controller.isConnected)
            Button("Clear Interface (Ctrl-C)") { controller.clearInterface() }
                .disabled(!controller.isConnected)
            Button("Return to Local") { controller.returnToLocal() }
                .disabled(!controller.isConnected)
            Divider()
            Picker("Mains Frequency", selection: $model.controller.lineFrequency) {
                Text("50 Hz").tag(50.0)
                Text("60 Hz").tag(60.0)
            }
            Divider()
            Button(model.simulatorPath == nil ? "Start Built-in Simulator" : "Simulator on \(model.simulatorPath ?? "")") {
                if let path = model.startSimulator() {
                    controller.append("Simulator on \(path)")
                    model.isConnectionSheetPresented = true
                }
            }
            .disabled(model.simulatorPath != nil)
            simulatorMenu
        }

        CommandMenu("Function") {
            ForEach(MeasurementFunction.allCases) { function in
                Button(function.title) { controller.setFunction(function) }
                    .disabled(!controller.isConnected)
            }
        }

        CommandMenu("Measurement") {
            Menu("Range") {
                Button("Auto") { controller.setAutoRange(true) }
                Divider()
                ForEach(controller.configuration.function.ranges, id: \.self) { range in
                    Button(Format.range(range, unit: controller.configuration.function.rangeUnit)) {
                        controller.setRange(range)
                    }
                }
            }
            .disabled(!controller.isConnected || !controller.configuration.function.hasSelectableRange)

            Menu("Integration Time") {
                ForEach(IntegrationTime.allCases) { time in
                    Button(time.title) { controller.setIntegrationTime(time) }
                }
            }
            .disabled(!controller.isConnected || !controller.configuration.function.usesIntegrationTime)

            Menu("Gate Time") {
                ForEach(GateTime.allCases) { gate in
                    Button(gate.title) { controller.setGateTime(gate) }
                }
            }
            .disabled(!controller.isConnected || !controller.configuration.function.usesAperture)

            Menu("AC Filter") {
                ForEach(ACBandwidth.allCases) { bandwidth in
                    Button(bandwidth.title) { controller.setBandwidth(bandwidth) }
                }
            }
            .disabled(!controller.isConnected || !controller.configuration.function.usesBandwidth)

            Menu("Auto Zero") {
                ForEach(AutoZero.allCases) { mode in
                    Button(mode.title) { controller.setAutoZero(mode) }
                }
            }
            .disabled(!controller.isConnected)

            Divider()

            Menu("Readings per Burst") {
                ForEach(MeterConfiguration.sampleCountChoices, id: \.self) { count in
                    Button(String(count)) { controller.setSampleCount(count) }
                }
            }
            Menu("Trigger Source") {
                ForEach(TriggerSource.allCases) { source in
                    Button(source.title) { controller.setTriggerSource(source) }
                }
            }
            Divider()
            Button(controller.frontPanelIsOn ? "Switch Meter Display Off" : "Switch Meter Display On") {
                controller.toggleFrontPanel()
            }
            .disabled(!controller.isConnected)
        }

        CommandMenu("Math") {
            ForEach(MathFunction.allCases) { function in
                Button(function.title) { controller.setMathFunction(function) }
                    .disabled(!controller.isConnected)
            }
            Divider()
            Button("Capture Null Offset") { controller.captureNull() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!controller.isConnected)
            Divider()
            // The history belongs to the app, not the meter, so these stay live
            // after a disconnection.
            Button("Reset History and Statistics") { controller.resetHistory() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Reset Runtime") { controller.resetRuntime() }
        }

        CommandMenu("Graphs") {
            Button("Show Graph") { openWindow(id: "graph") }
                .keyboardShortcut("1", modifiers: .command)
            Button("Show Histogram") { openWindow(id: "histogram") }
                .keyboardShortcut("2", modifiers: .command)
            Button("Show Stability") { openWindow(id: "stability") }
                .keyboardShortcut("3", modifiers: .command)
            Button("New Math Waveform") {
                let waveform = model.addWaveform()
                openWindow(id: "waveform", value: waveform.id)
            }
            .keyboardShortcut("4", modifiers: .command)

            if !model.waveforms.isEmpty {
                Divider()
                ForEach(model.waveforms) { waveform in
                    Button(waveform.name) { openWindow(id: "waveform", value: waveform.id) }
                }
            }

            Divider()
            Menu("History Size") {
                ForEach(SampleBuffer.capacityChoices, id: \.self) { capacity in
                    Button(capacityLabel(capacity)) { controller.historyCapacity = capacity }
                }
            }
            Toggle("Draw Every Point", isOn: $model.drawsEveryPoint)
        }

        // CommandsBuilder tops out at ten statements, so the last few menus
        // travel together.
        Group {
            CommandMenu("Data Logger") {
                Toggle("Save Readings to Text File", isOn: $model.controller.logReadingsText)
                Toggle("Save Readings to CSV File", isOn: $model.controller.logReadingsCSV)
                Toggle("Save Events to Text File", isOn: $model.controller.logStatusText)
                Divider()
                Button("Choose Folder…", action: chooseLogFolder)
                Button("Reveal Folder in Finder") {
                    try? FileManager.default.createDirectory(at: controller.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(controller.logDirectory)
                }
            }

            CommandMenu("List") {
                Toggle("Auto Scroll", isOn: $model.controller.autoScroll)
                Toggle("Update List", isOn: $model.controller.updateList)
                Toggle("Add Readings to List", isOn: $model.controller.addReadingsToList)
                Divider()
                Button("Clear List") { controller.clearEntries() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(controller.entries.isEmpty)
            }

            CommandMenu("Speech") {
                Toggle("Speak Readings", isOn: Binding(
                    get: { controller.speech.isEnabled },
                    set: { controller.speech.isEnabled = $0 }
                ))
                Button("Speak Now") {
                    guard let value = controller.latestReading else { return }
                    controller.speech.speak(controller.speech.spoken(value: value, unit: controller.displayUnit))
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(controller.latestReading == nil)
                Button("Stop Speaking") { controller.speech.stop() }
                Divider()
                Menu("Interval") {
                    ForEach([2.0, 5.0, 10.0, 30.0, 60.0], id: \.self) { seconds in
                        Button("\(Int(seconds)) s") { controller.speech.interval = seconds }
                    }
                }
            }

            CommandGroup(replacing: .help) {
                Button("General Help") { openWindow(id: "help-general") }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
                Button("Serial Connection Help") { openWindow(id: "help-serial") }
                Button("Credits") { openWindow(id: "credits") }
            }
        }
    }

    // MARK: - Helpers

    /// Steering for the built-in simulator, so the demo can be driven from the
    /// app rather than only from the command line.
    @ViewBuilder
    private var simulatorMenu: some View {
        if let signal = model.simulatedSignal {
            Menu("Simulated Signal") {
                Menu("Shape") {
                    ForEach(SimulatedSignal.Modulation.allCases, id: \.self) { shape in
                        Button(shape.title) { signal.modulation = shape }
                    }
                }
                Menu("DC Input") {
                    ForEach([0.05, 0.5, 4.19, 12.0, 120.0], id: \.self) { volts in
                        Button(Format.engineering(volts, unit: "V")) { signal[.dcVoltage] = volts }
                    }
                }
                Menu("Noise") {
                    Button("Quiet (0.2 ppm)") { signal.noiseFraction = 2e-7 }
                    Button("Typical (2 ppm)") { signal.noiseFraction = 2e-6 }
                    Button("Noisy (50 ppm)") { signal.noiseFraction = 5e-5 }
                }
            }
        }
    }

    private func capacityLabel(_ capacity: Int) -> String {
        capacity >= 1_000_000 ? "\(capacity / 1_000_000)M Samples" : "\(capacity / 1000)K Samples"
    }

    private func chooseLogFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = controller.logDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.setLogDirectory(url)
            controller.append("Log folder: \(url.lastPathComponent)")
        }
    }
}

/// Entry point used by the thin `AgilentDMM` executable target.
public func runAgilentDMM() {
    MainActor.assumeIsolated {
        AgilentDMMApp.main()
    }
}
