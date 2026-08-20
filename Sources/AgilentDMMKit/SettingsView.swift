import SwiftUI
import AppKit
import DMMCore

/// The Settings window behind ⌘, — the standard macOS home for everything that
/// is a preference rather than an action. The menus keep their entries; both
/// drive the same `AppModel`, so nothing is duplicated but the presentation.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AcquisitionSettings()
                .tabItem { Label("Acquisition", systemImage: "waveform.path.ecg") }
            GraphsSettings()
                .tabItem { Label("Graphs", systemImage: "chart.xyaxis.line") }
            LoggingSettings()
                .tabItem { Label("Logging", systemImage: "doc.text") }
            SpeechSettings()
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
        }
        .environment(model)
        .frame(width: 580, height: 460)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var controller = model.controller

        Form {
            Section("Readout Panel") {
                colorPicker("Text colour", selection: $model.panelTextColor)
                colorPicker("Panel colour", selection: $model.panelBackground,
                            choices: [.black, .white, .gray])
            }

            Section("Lists") {
                Toggle("Auto scroll", isOn: $controller.autoScroll)
                Toggle("Update event list", isOn: $controller.updateList)
                Toggle("Add every reading to the event list", isOn: $controller.addReadingsToList)
                Picker("Readings table holds", selection: $controller.tableCapacity) {
                    Text("500").tag(500)
                    Text("2 000").tag(2_000)
                    Text("10 000").tag(10_000)
                    Text("50 000").tag(50_000)
                }
                Text("The table is separate from the graph history: it is what you scroll through, not what you plot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Beep when a limit test fails", isOn: $controller.beeperEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Acquisition

struct AcquisitionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var controller = model.controller

        Form {
            Section("Loop") {
                HStack {
                    TextField("Pause between bursts", value: $controller.updateInterval,
                              format: .number.precision(.fractionLength(0...3)))
                        .frame(width: 80)
                    Stepper("", value: $controller.updateInterval, in: 0...3600, step: 0.1)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
                Picker("Mains frequency", selection: $controller.lineFrequency) {
                    Text("50 Hz").tag(50.0)
                    Text("60 Hz").tag(60.0)
                }
                Text("Zero pause asks for the next burst as soon as the last answer is in. The mains frequency is only used to predict how long a burst should take, so a slow meter is not mistaken for a dead one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ask For Each Pass") {
                Toggle("Readings", isOn: $controller.pollPlan.takeReadings)
                Toggle("Questionable status (overload, limits)", isOn: $controller.pollPlan.readQuestionableStatus)
                Toggle("Configuration read-back", isOn: $controller.pollPlan.readConfiguration)
                Toggle("Meter's own min / max / average", isOn: $controller.pollPlan.readInstrumentStatistics)
                Toggle("Combine queries into one message", isOn: $controller.usesCompoundQueries)
                Picker("Read configuration every", selection: $controller.pollPlan.configurationInterval) {
                    Text("pass").tag(1)
                    Text("5 passes").tag(5)
                    Text("10 passes").tag(10)
                    Text("50 passes").tag(50)
                }
                Text("Every query is a round trip, and at 9600 baud a round trip costs several milliseconds before the meter has even started measuring. Combining them folds a whole pass into one message; switching off what you do not need removes the questions altogether. The loop falls back to asking separately on its own if a meter turns out not to understand a combined message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How Fast Can It Go") {
                LabeledContent("Estimated burst") {
                    Text("\(Format.number(controller.configuration.estimatedBurstDuration(lineFrequency: controller.lineFrequency) * 1000, 0)) ms")
                }
                LabeledContent("Measured rate") {
                    Text("\(Format.number(controller.measuredRate, 1)) readings/s")
                }
                Text("For the highest rate: 0.02 PLC, auto zero off, the meter's display off, and as many readings per burst as you can use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Graphs

struct GraphsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var settings = model.graph
        @Bindable var histogram = model.histogram

        Form {
            Section("Measurement Graph") {
                colorPicker("Curve", selection: $settings.curveColor)
                colorPicker("Plot background", selection: $settings.plotBackground)
                colorPicker("Figure background", selection: $settings.figureBackground)
                Picker("Theme", selection: Binding(
                    get: { settings.theme },
                    set: { settings.apply(theme: $0) }
                )) {
                    ForEach(GraphTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("X axis", selection: $settings.xAxis) {
                    ForEach(GraphXAxis.allCases) { axis in
                        Text(axis.title).tag(axis)
                    }
                }
                Toggle("Auto Y axis", isOn: $settings.autoAxis)
                if !settings.autoAxis {
                    HStack {
                        Text("Y range")
                        TextField("Min", value: $settings.manualMinimum, format: .number)
                            .frame(width: 80)
                        TextField("Max", value: $settings.manualMaximum, format: .number)
                            .frame(width: 80)
                    }
                }
                Toggle("Show points", isOn: $settings.showPoints)
                Toggle("Mean marker", isOn: $settings.showMean)
                Toggle("Min / max markers", isOn: $settings.showExtremes)
                Toggle("Limit markers", isOn: $settings.showLimits)
            }

            Section("Histogram") {
                Picker("Bins", selection: $histogram.binCount) {
                    ForEach(Histogram.binCountChoices, id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                colorPicker("Bars", selection: $histogram.barColor)
                Toggle("Mean and ±σ markers", isOn: $histogram.showNormalMarkers)
            }

            Section("History") {
                Picker("Keep at most", selection: Binding(
                    get: { model.controller.historyCapacity },
                    set: { model.controller.historyCapacity = $0 }
                )) {
                    ForEach(SampleBuffer.capacityChoices, id: \.self) { capacity in
                        Text(capacity >= 1_000_000
                             ? "\(capacity / 1_000_000)M readings"
                             : "\(capacity / 1000)K readings")
                            .tag(capacity)
                    }
                }
                Toggle("Draw every point", isOn: $model.drawsEveryPoint)
                Text("Curves are normally decimated to about 1400 points with minima and maxima preserved, so spikes survive and a million-reading history still draws. Turning that off is honest and slow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logging

struct LoggingSettings: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    var body: some View {
        @Bindable var controller = model.controller

        Form {
            Section("Write While Connected") {
                Toggle("Readings to text file", isOn: $controller.logReadingsText)
                Toggle("Readings to CSV file", isOn: $controller.logReadingsCSV)
                Toggle("Events to text file", isOn: $controller.logStatusText)
                Text("Files are named by date, model and port. At thirty readings a second a CSV grows by roughly two megabytes an hour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Folder") {
                LabeledContent("Location") {
                    Text(controller.logDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Reveal in Finder", action: revealFolder)
                }
                LabeledContent("Written this session") {
                    Text("\(controller.loggedLineCount) lines")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = controller.logDirectory
        if panel.runModal() == .OK, let url = panel.url {
            controller.setLogDirectory(url)
            controller.append("Log folder: \(url.lastPathComponent)")
        }
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: controller.logDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(controller.logDirectory)
    }
}

// MARK: - Speech

struct SpeechSettings: View {
    @Environment(AppModel.self) private var model
    @State private var upperText = ""
    @State private var lowerText = ""

    private var speech: SpeechAnnouncer { model.controller.speech }

    var body: some View {
        Form {
            Section("Spoken Readings") {
                Toggle("Speak readings", isOn: Binding(
                    get: { speech.isEnabled },
                    set: { speech.isEnabled = $0 }
                ))
                Toggle("Speak on a timer", isOn: Binding(
                    get: { speech.speaksPeriodically },
                    set: { speech.speaksPeriodically = $0 }
                ))
                Picker("Every", selection: Binding(
                    get: { speech.interval },
                    set: { speech.interval = $0 }
                )) {
                    ForEach([2.0, 5.0, 10.0, 30.0, 60.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                HStack {
                    Text("Speed")
                    Slider(value: Binding(
                        get: { Double(speech.rate) },
                        set: { speech.rate = Float($0) }
                    ), in: 0.3...0.7)
                }
            }

            Section("Speak on a Threshold") {
                HStack {
                    Text("Above").frame(width: 60, alignment: .leading)
                    TextField("off", text: $upperText)
                        .frame(width: 100)
                        .onSubmit { speech.upperThreshold = Double(upperText) }
                    Text(model.controller.displayUnit).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Below").frame(width: 60, alignment: .leading)
                    TextField("off", text: $lowerText)
                        .frame(width: 100)
                        .onSubmit { speech.lowerThreshold = Double(lowerText) }
                    Text(model.controller.displayUnit).foregroundStyle(.secondary)
                }
                Button("Clear thresholds") {
                    upperText = ""
                    lowerText = ""
                    speech.upperThreshold = nil
                    speech.lowerThreshold = nil
                }
                Text("A threshold speaks once when the reading crosses it, and again only after it has come back. Leave a field empty to switch it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Test") {
                    speech.speak(speech.spoken(value: model.controller.latestReading ?? 4.19,
                                               unit: model.controller.displayUnit))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            upperText = speech.upperThreshold.map { SCPI.format($0) } ?? ""
            lowerText = speech.lowerThreshold.map { SCPI.format($0) } ?? ""
        }
    }
}

// MARK: - Shared

/// A colour row that shows the swatch as well as the name.
@ViewBuilder
private func colorPicker(_ title: String,
                         selection: Binding<PanelColor>,
                         choices: [PanelColor] = PanelColor.allCases) -> some View {
    Picker(title, selection: selection) {
        ForEach(choices) { choice in
            Label {
                Text(choice.title)
            } icon: {
                Circle().fill(choice.color)
            }
            .tag(choice)
        }
    }
}
