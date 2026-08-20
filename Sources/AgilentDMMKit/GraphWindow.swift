import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DMMCore

/// The live measurement trace, with the reference lines somebody watching a
/// drifting reading actually wants: the mean, the extremes, and the limit-test
/// thresholds when limit testing is on.
///
/// Shared by the graph window and by the main window's inline chart, so the two
/// cannot drift apart.
struct MeasurementTrace: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: ClosedRange<Double>?

    private var controller: DMMController { model.controller }
    private var settings: GraphSettings { model.graph }

    var body: some View {
        SeriesChart(samples: controller.history.samples,
                    unit: controller.displayUnit,
                    seriesName: controller.configuration.function.shortTitle,
                    settings: settings,
                    markers: markers,
                    drawsEveryPoint: model.drawsEveryPoint,
                    selection: $selection)
    }

    private var markers: [ChartMarker] {
        var result: [ChartMarker] = []
        let statistics = controller.history.statistics
        guard !statistics.isEmpty else { return result }

        if settings.showMean {
            result.append(ChartMarker(label: "Mean \(Format.engineering(statistics.mean, unit: controller.displayUnit))",
                                      value: statistics.mean, color: .green))
        }
        if settings.showExtremes {
            result.append(ChartMarker(label: "Max \(Format.engineering(statistics.maximum, unit: controller.displayUnit))",
                                      value: statistics.maximum, color: .orange))
            result.append(ChartMarker(label: "Min \(Format.engineering(statistics.minimum, unit: controller.displayUnit))",
                                      value: statistics.minimum, color: .blue))
        }
        if settings.showLimits, controller.math.function == .limit {
            result.append(ChartMarker(label: "Limit HI", value: controller.math.upperLimit, color: .red))
            result.append(ChartMarker(label: "Limit LO", value: controller.math.lowerLimit, color: .red))
        }
        return result
    }
}

/// The live measurement graph.
struct GraphWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ClosedRange<Double>?

    private var controller: DMMController { model.controller }
    private var settings: GraphSettings { model.graph }
    private var samples: [Reading] { controller.history.samples }

    var body: some View {
        VStack(spacing: 0) {
            chart
                .padding(12)
                .background(settings.figureBackground.color)

            Divider()

            SeriesInfoPanel(samples: samples,
                            unit: controller.displayUnit,
                            overall: controller.history.statistics,
                            selection: selection,
                            xAxis: settings.xAxis,
                            onClearSelection: { selection = nil })
        }
        .frame(minWidth: 660, minHeight: 440)
        .navigationTitle("\(controller.identity?.model ?? "Meter") \(controller.configuration.function.shortTitle) Graph")
        .toolbar {
            ToolbarItemGroup {
                GraphAppearanceMenu(settings: settings)
                Button("Save Image", action: saveImage)
                Button("Save Data", action: saveData)
            }
        }
        .focusedSceneValue(\.exportAction, ExportAction(title: "Save Graph Data…", perform: saveData))
    }

    private var chart: some View {
        MeasurementTrace(selection: $selection).environment(model)
    }

    private func saveImage() {
        Exporter.savePNG(of: chart.padding(16).background(settings.figureBackground.color),
                         size: CGSize(width: 1200, height: 700),
                         suggestedName: "\(controller.configuration.function.shortTitle)-Graph.png")
    }

    private func saveData() {
        let csv = controller.history.csv(valueHeader: "\(controller.configuration.function.shortTitle) (\(controller.displayUnit))")
        Exporter.save(Data(csv.utf8),
                      suggestedName: "\(controller.configuration.function.shortTitle)-Readings.csv",
                      type: .commaSeparatedText)
    }
}

/// One derived waveform, in its own window.
struct MathWaveformWindow: View {
    let waveformID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: ClosedRange<Double>?
    @State private var parameterAText = ""
    @State private var parameterBText = ""

    private var waveform: MathWaveform? { model.waveform(id: waveformID) }

    var body: some View {
        if let waveform {
            content(waveform)
        } else {
            ContentUnavailableView("No waveform",
                                   systemImage: "function",
                                   description: Text("This math waveform has been removed. Create a new one from the Graphs menu."))
                .frame(minWidth: 500, minHeight: 300)
        }
    }

    private func content(_ waveform: MathWaveform) -> some View {
        @Bindable var waveform = waveform
        let samples = model.samples(for: waveform.id)
        let unit = model.unit(for: waveform.id)

        return VStack(spacing: 0) {
            recipeBar(waveform)

            Divider()

            SeriesChart(samples: samples,
                        unit: unit,
                        seriesName: waveform.name,
                        settings: waveform.settings,
                        markers: [],
                        drawsEveryPoint: model.drawsEveryPoint,
                        selection: $selection)
                .padding(12)
                .background(waveform.settings.figureBackground.color)

            Divider()

            SeriesInfoPanel(samples: samples,
                            unit: unit,
                            overall: Statistics.over(samples.map(\.value)),
                            selection: selection,
                            xAxis: waveform.settings.xAxis,
                            onClearSelection: { selection = nil })
        }
        .frame(minWidth: 700, minHeight: 500)
        .navigationTitle(waveform.name)
        .navigationSubtitle("\(model.name(for: waveform.source)) → \(waveform.recipe.summary)")
        .toolbar {
            ToolbarItemGroup {
                GraphAppearanceMenu(settings: waveform.settings)
                Button("Derive From This") {
                    let child = model.addWaveform(source: waveform.id)
                    openWindow(id: "waveform", value: child.id)
                }
                .help("A waveform whose source is this one — maths on maths")
                Button("Save Data") { saveData(waveform, samples: samples, unit: unit) }
            }
        }
        .focusedSceneValue(\.exportAction,
                           ExportAction(title: "Save \(waveform.name) Data…",
                                        perform: { saveData(waveform, samples: samples, unit: unit) }))
        .onAppear {
            parameterAText = SCPI.format(waveform.recipe.parameterA)
            parameterBText = SCPI.format(waveform.recipe.parameterB)
        }
    }

    private func recipeBar(_ waveform: MathWaveform) -> some View {
        @Bindable var waveform = waveform

        return HStack(spacing: 10) {
            TextField("Name", text: $waveform.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

            Picker("Source", selection: $waveform.source) {
                Text(model.controller.configuration.function.shortTitle + " (measurement)").tag(UUID?.none)
                ForEach(model.availableSources(for: waveform)) { candidate in
                    Text(candidate.name).tag(UUID?.some(candidate.id))
                }
            }
            .frame(width: 220)

            Picker("Operation", selection: $waveform.recipe.operation) {
                ForEach(WaveformOperation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .frame(width: 260)
            .onChange(of: waveform.recipe.operation) { _, operation in
                waveform.recipe.parameterA = operation.defaultParameterA
                waveform.recipe.parameterB = operation.defaultParameterB
                parameterAText = SCPI.format(waveform.recipe.parameterA)
                parameterBText = SCPI.format(waveform.recipe.parameterB)
            }

            if let label = waveform.recipe.operation.parameterALabel {
                HStack(spacing: 4) {
                    Text(label).font(.caption)
                    TextField("", text: $parameterAText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { waveform.recipe.parameterA = Double(parameterAText) ?? waveform.recipe.parameterA }
                }
            }
            if let label = waveform.recipe.operation.parameterBLabel {
                HStack(spacing: 4) {
                    Text(label).font(.caption)
                    TextField("", text: $parameterBText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit { waveform.recipe.parameterB = Double(parameterBText) ?? waveform.recipe.parameterB }
                }
            }

            Spacer()

            Button(role: .destructive) {
                model.removeWaveform(id: waveform.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func saveData(_ waveform: MathWaveform, samples: [Reading], unit: String) {
        let csv = SampleBuffer.csv(samples, valueHeader: "\(waveform.name) (\(unit))")
        Exporter.save(Data(csv.utf8), suggestedName: "\(waveform.name).csv", type: .commaSeparatedText)
    }
}

/// The colour, theme, axis and marker controls every chart window carries.
struct GraphAppearanceMenu: View {
    @Bindable var settings: GraphSettings

    var body: some View {
        Menu("Appearance") {
            Menu("Curve Colour") {
                ForEach(PanelColor.allCases) { color in
                    Button(color.title) { settings.curveColor = color }
                }
            }
            Menu("Theme") {
                ForEach(GraphTheme.allCases) { theme in
                    Button(theme.title) { settings.apply(theme: theme) }
                }
            }
            Divider()
            Picker("X Axis", selection: $settings.xAxis) {
                ForEach(GraphXAxis.allCases) { axis in
                    Text(axis.title).tag(axis)
                }
            }
            Toggle("Auto Y Axis", isOn: $settings.autoAxis)
            Toggle("Show Points", isOn: $settings.showPoints)
            Divider()
            Toggle("Mean Marker", isOn: $settings.showMean)
            Toggle("Min / Max Markers", isOn: $settings.showExtremes)
            Toggle("Limit Markers", isOn: $settings.showLimits)
        }
    }
}
