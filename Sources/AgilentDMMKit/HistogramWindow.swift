import SwiftUI
import Charts
import UniformTypeIdentifiers
import DMMCore

/// How the readings are distributed — the view a strip chart cannot give you.
///
/// On a six-and-a-half-digit meter this is where the last two digits stop being
/// a blur and turn into a shape: a clean bell means noise, two humps mean
/// something is switching, a long tail means something is drifting.
struct HistogramWindow: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }
    private var settings: HistogramSettings { model.histogram }

    private var samples: [Reading] { model.samples(for: settings.source) }
    private var unit: String { model.unit(for: settings.source) }
    private var histogram: Histogram {
        Histogram(values: samples.map(\.value), binCount: settings.binCount)
    }

    var body: some View {
        @Bindable var settings = model.histogram

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Source", selection: $settings.source) {
                    Text("\(controller.configuration.function.shortTitle) (measurement)").tag(UUID?.none)
                    ForEach(model.waveforms) { waveform in
                        Text(waveform.name).tag(UUID?.some(waveform.id))
                    }
                }
                .frame(width: 260)

                Picker("Bins", selection: $settings.binCount) {
                    ForEach(Histogram.binCountChoices, id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                .frame(width: 110)

                Menu("Colour") {
                    ForEach(PanelColor.allCases) { color in
                        Button(color.title) { settings.barColor = color }
                    }
                }
                .frame(width: 100)

                Toggle("Mean and ±σ", isOn: $settings.showNormalMarkers)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Save Image", action: saveImage)
                Button("Save Data", action: saveData)
            }
            .padding(10)
            .background(.bar)

            Divider()

            chart
                .padding(12)

            Divider()
            summary
        }
        .frame(minWidth: 660, minHeight: 460)
        .navigationTitle("Histogram — \(model.name(for: settings.source))")
        .focusedSceneValue(\.exportAction, ExportAction(title: "Save Histogram Data…", perform: saveData))
    }

    private var chart: some View {
        let histogram = self.histogram
        let statistics = histogram.statistics

        return Chart {
            ForEach(histogram.bins) { bin in
                // Explicit rectangles rather than BarMark: a bar on a continuous
                // axis gets its width from the automatic step and drags the
                // domain down to zero, which on readings clustered around 4.19 V
                // squashes the whole distribution into a single line.
                RectangleMark(
                    xStart: .value("From", bin.lowerBound),
                    xEnd: .value("To", bin.upperBound),
                    yStart: .value("Count", 0),
                    yEnd: .value("Count", bin.count)
                )
                .foregroundStyle(settings.barColor.color)
            }

            if settings.showNormalMarkers, !statistics.isEmpty, statistics.standardDeviation > 0 {
                RuleMark(x: .value("Mean", statistics.mean))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top) { Text("mean").font(.caption2).foregroundStyle(.green) }

                ForEach([-1.0, 1.0], id: \.self) { side in
                    RuleMark(x: .value("Sigma", statistics.mean + side * statistics.standardDeviation))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .chartXScale(domain: valueDomain)
        .chartPlotStyle { plot in
            plot.background(settings.plotBackground.color)
        }
        .chartXAxisLabel("\(model.name(for: settings.source)) (\(unit))")
        .chartYAxisLabel(position: .leading) { Text("Count") }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis {
            // Bin edges are readings, so they follow the same period-decimal
            // notation as everything else rather than the viewer's locale.
            AxisMarks { mark in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(AxisNumber.label(value, decimals: binDecimals))
                    }
                }
            }
        }
    }

    /// Exactly the span the bins cover, so the distribution fills the plot
    /// instead of sitting in a corner of an axis that starts at zero.
    private var valueDomain: ClosedRange<Double> {
        guard let first = histogram.bins.first, let last = histogram.bins.last else { return 0...1 }
        let lower = first.lowerBound
        let upper = last.upperBound
        guard upper > lower else { return lower...(lower + 1) }
        return lower...upper
    }

    private var binDecimals: Int {
        let statistics = histogram.statistics
        guard !statistics.isEmpty else { return 0 }
        return AxisNumber.decimals(forSpan: statistics.peakToPeak)
    }

    private var summary: some View {
        let statistics = histogram.statistics
        return HStack(spacing: 24) {
            Text("Samples: \(statistics.count)")
            Text("Mean: \(engineering(statistics.isEmpty ? nil : statistics.mean))")
            Text("σ: \(engineering(statistics.isEmpty ? nil : statistics.standardDeviation))")
            Text("Peak-peak: \(engineering(statistics.isEmpty ? nil : statistics.peakToPeak))")
            Text("Bins: \(settings.binCount)")
            Text("Tallest bin: \(histogram.peakCount)")
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func engineering(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: unit) } ?? "—"
    }

    private func saveImage() {
        Exporter.savePNG(of: chart.padding(16).background(Color.white),
                         size: CGSize(width: 1100, height: 650),
                         suggestedName: "Histogram.png")
    }

    private func saveData() {
        Exporter.save(Data(histogram.csv(valueHeader: unit).utf8),
                      suggestedName: "Histogram.csv",
                      type: .commaSeparatedText)
    }
}
