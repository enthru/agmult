import SwiftUI
import Charts
import UniformTypeIdentifiers
import DMMCore

/// Allan deviation and drift — what a long capture is actually for.
///
/// The standard deviation in the readout panel answers the wrong question about
/// a record that lasts hours: it grows with the record, because everything
/// drifts. This window answers the right one. How much does the *average* move
/// if I average for a second? For a minute? For an hour? And at what point does
/// averaging longer stop helping?
struct StabilityWindow: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }
    private var samples: [Reading] { model.samples(for: model.stabilitySource) }
    private var unit: String { model.unit(for: model.stabilitySource) }
    private var allan: AllanDeviation? { AllanDeviation.compute(readings: samples) }
    private var drift: LinearFit? { LinearFit.over(samples) }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Source", selection: $model.stabilitySource) {
                    Text("\(controller.configuration.function.shortTitle) (measurement)").tag(UUID?.none)
                    ForEach(model.waveforms) { waveform in
                        Text(waveform.name).tag(UUID?.some(waveform.id))
                    }
                }
                .frame(width: 260)

                Spacer()

                Button("Save Image", action: saveImage)
                Button("Save Data", action: saveData)
                    .disabled(allan == nil)
            }
            .padding(10)
            .background(.bar)

            Divider()

            if let allan {
                chart(allan)
                    .padding(12)

                Divider()
                summary(allan)
            } else {
                ContentUnavailableView(
                    "Not enough readings yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Allan deviation needs at least sixteen readings, and is worth looking at from a few hundred. Leave the meter running.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle("Stability — \(model.name(for: model.stabilitySource))")
        .focusedSceneValue(\.exportAction, ExportAction(title: "Save Stability Data…", perform: saveData))
    }

    // MARK: - Chart

    private func chart(_ allan: AllanDeviation) -> some View {
        let solid = allan.wellDetermined
        let sparse = allan.points.filter { point in !solid.contains { $0.tau == point.tau } }

        return Chart {
            ForEach(allan.points) { point in
                LineMark(
                    x: .value("Averaging time", point.tau),
                    y: .value("Allan deviation", point.deviation)
                )
                .foregroundStyle(model.graph.curveColor.color)
            }

            // Error bars, clamped clear of zero: on a log axis a lower bound at
            // or below zero has nowhere to be drawn.
            ForEach(allan.points) { point in
                RuleMark(
                    x: .value("Averaging time", point.tau),
                    yStart: .value("Low", max(point.deviation - point.uncertainty, point.deviation * 0.2)),
                    yEnd: .value("High", point.deviation + point.uncertainty)
                )
                .foregroundStyle(model.graph.curveColor.color.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 4))
            }

            ForEach(solid) { point in
                PointMark(
                    x: .value("Averaging time", point.tau),
                    y: .value("Allan deviation", point.deviation)
                )
                .foregroundStyle(model.graph.curveColor.color)
                .symbolSize(50)
            }

            // The long averaging times are drawn hollow: they are built from a
            // handful of independent differences and scatter accordingly.
            ForEach(sparse) { point in
                PointMark(
                    x: .value("Averaging time", point.tau),
                    y: .value("Allan deviation", point.deviation)
                )
                .foregroundStyle(.secondary)
                .symbol(.circle)
                .symbolSize(30)
            }

            if let optimum = allan.optimumAveragingTime {
                RuleMark(x: .value("Best", optimum.tau))
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("best at \(Format.engineering(optimum.tau, unit: "s", significantDigits: 3))")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
            }
        }
        .chartXScale(type: .log)
        .chartYScale(type: .log)
        .chartXAxisLabel("Averaging time τ")
        .chartYAxisLabel(position: .leading) { Text("Allan deviation σ") }
        // Decades on a log axis spelled out in full are a column of zeroes —
        // and, left to Swift Charts, a column of zeroes in the viewer's locale.
        // Engineering notation says the same thing in three characters.
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(Format.engineering(value, unit: unit, significantDigits: 3))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { mark in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(Format.engineering(value, unit: "s", significantDigits: 3))
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(model.graph.plotBackground.color)
        }
    }

    // MARK: - Numbers

    private func summary(_ allan: AllanDeviation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !allan.samplingIsEvenEnough {
                Label("Readings are unevenly spaced (±\(Format.number(allan.intervalJitter * 100, 0))%). Allan deviation assumes a steady rate — read this curve as a hint, not a measurement.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                GridRow {
                    Text("Readings: \(allan.readingCount)")
                    Text("Interval: \(Format.engineering(allan.sampleInterval, unit: "s"))")
                    Text("Shortest τ: \(engineeringTime(allan.points.first?.tau))")
                }
                GridRow {
                    Text("σ at shortest τ: \(engineering(allan.points.first?.deviation))")
                    Text("Best τ: \(engineeringTime(allan.optimumAveragingTime?.tau))")
                    Text("σ there: \(engineering(allan.optimumAveragingTime?.deviation))")
                }
                GridRow {
                    Text("Slope: \(allan.logSlope.map { Format.number($0, 2) } ?? "—")")
                    Text(allan.noiseDescription ?? "")
                        .gridCellColumns(2)
                }
            }

            Divider()

            if let drift {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                    GridRow {
                        Text(driftHeadline(drift))
                            .foregroundStyle(Color.accentColor)
                        Text("Over: \(span(drift.span))")
                        Text("Total: \(engineering(drift.totalChange))")
                    }
                    GridRow {
                        Text("Fit r²: \(Format.number(drift.rSquared, 4))")
                        Text("Points: \(drift.count)")
                        Text(drift.rSquared < 0.5 ? "mostly noise, not a trend" : "")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not enough readings for a drift fit.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Below a minute of record, an hourly rate is an extrapolation by a factor
    /// of hundreds and reads as a wildly precise nonsense — 315 volts an hour
    /// from twenty milliseconds of data. The total change over the record is the
    /// number that is actually supported by the measurement, so that is what is
    /// shown until there is enough record to say more.
    private static let minimumSpanForARate: TimeInterval = 60

    private func driftHeadline(_ drift: LinearFit) -> String {
        guard drift.span >= Self.minimumSpanForARate else {
            return "Drift: record too short for an hourly rate"
        }
        return "Drift: \(Format.engineering(drift.slopePerHour, unit: unit)) / hour"
    }

    private func engineering(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: unit) } ?? "—"
    }

    private func engineeringTime(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: "s", significantDigits: 4) } ?? "—"
    }

    /// `00:41:12` reads well for a long capture and says nothing at all about a
    /// short one, where `41.2 ms` is the whole answer.
    private func span(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? Format.duration(seconds) : Format.engineering(seconds, unit: "s", significantDigits: 4)
    }

    // MARK: - Export

    private func saveImage() {
        guard let allan else { return }
        Exporter.savePNG(of: chart(allan).padding(16).background(model.graph.figureBackground.color),
                         size: CGSize(width: 1100, height: 650),
                         suggestedName: "Allan-Deviation.png")
    }

    private func saveData() {
        guard let allan else { return }
        var text = allan.csv(unit: unit)
        if let drift {
            text += "\n# Drift \(drift.slopePerHour) \(unit)/hour over \(drift.span) s, r2 \(drift.rSquared)\n"
        }
        Exporter.save(Data(text.utf8), suggestedName: "Allan-Deviation.csv", type: .commaSeparatedText)
    }
}
