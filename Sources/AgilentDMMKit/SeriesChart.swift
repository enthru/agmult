import SwiftUI
import Charts
import DMMCore

/// Axis labels, in the same notation as every reading in the application.
///
/// Swift Charts formats numbers in the viewer's locale, which on a machine set
/// to a comma-decimal locale puts "4,1915" on the axis directly above a readout
/// saying "4.19150 V". Instrument work is period-decimal throughout, so the
/// labels are formatted rather than left to the default.
enum AxisNumber {
    /// Decimals enough to tell one gridline from the next, and no more.
    static func decimals(forSpan span: Double, divisions: Int = 6) -> Int {
        guard span > 0, span.isFinite else { return 0 }
        let step = span / Double(divisions)
        return min(9, max(0, Int(ceil(-log10(step))) + 1))
    }

    static func label(_ value: Double, decimals: Int) -> String {
        Format.number(value, decimals)
    }
}

/// A horizontal reference line on a chart.
struct ChartMarker: Identifiable {
    let label: String
    let value: Double
    let color: Color

    var id: String { label }
}

/// The strip chart shared by the measurement graph and every math waveform.
///
/// Histories run to millions of readings, so the series is decimated for drawing
/// — minima and maxima preserved, so a spike one reading wide still shows —
/// while the full history stays available for statistics and export. Dragging
/// across the plot selects a region and everything downstream follows.
struct SeriesChart: View {
    let samples: [Reading]
    let unit: String
    let seriesName: String
    let settings: GraphSettings
    let markers: [ChartMarker]
    let drawsEveryPoint: Bool
    @Binding var selection: ClosedRange<Double>?

    /// Roughly how many points to hand the chart. Past this the line is drawn
    /// from more points than the window has pixels.
    private static let drawTarget = 1400

    private var drawn: [Reading] {
        drawsEveryPoint ? samples : SampleBuffer.decimate(samples, into: Self.drawTarget)
    }

    private var origin: Date? { samples.first?.timestamp }

    private func x(_ sample: Reading) -> Double {
        switch settings.xAxis {
        case .sampleNumber:
            return Double(sample.index)
        case .time:
            return sample.timestamp.timeIntervalSince(origin ?? sample.timestamp)
        }
    }

    var body: some View {
        Chart {
            if let selection {
                RectangleMark(
                    xStart: .value("From", selection.lowerBound),
                    xEnd: .value("To", selection.upperBound)
                )
                .foregroundStyle(Color.accentColor.opacity(0.15))
            }

            ForEach(drawn) { sample in
                LineMark(
                    x: .value(settings.xAxis.title, x(sample)),
                    y: .value(seriesName, sample.value)
                )
                .foregroundStyle(settings.curveColor.color)
                .interpolationMethod(.linear)

                if settings.showPoints {
                    PointMark(
                        x: .value(settings.xAxis.title, x(sample)),
                        y: .value(seriesName, sample.value)
                    )
                    .foregroundStyle(settings.curveColor.color)
                    .symbolSize(12)
                }
            }

            ForEach(markers) { marker in
                RuleMark(y: .value(marker.label, marker.value))
                    .foregroundStyle(marker.color)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // The label sits on the plot, so whatever the curve is
                    // doing runs straight through it — and a dense capture is
                    // doing something everywhere. It gets the plot's own
                    // background behind it, and `fitToPlot` keeps the topmost
                    // marker from being cut off against the top edge.
                    .annotation(position: .top,
                                alignment: .leading,
                                spacing: 2,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Text(marker.label)
                            .font(.caption2)
                            .foregroundStyle(marker.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(settings.plotBackground.color.opacity(0.85))
                            )
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            // Swift Charts puts the value axis on the trailing edge by default;
            // instrument graphs read better with it on the left.
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let value = mark.as(Double.self) {
                        Text(AxisNumber.label(value, decimals: yDecimals))
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
                        Text(AxisNumber.label(value, decimals: xDecimals))
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(settings.plotBackground.color)
        }
        .chartXAxisLabel(settings.xAxis.title)
        .chartYAxisLabel(position: .leading) { Text("\(seriesName) (\(unit))") }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(proxy: proxy, geometry: geometry))
                    .onTapGesture { selection = nil }
            }
        }
    }

    private func dragGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                guard let plotFrame = proxy.plotFrame else { return }
                let origin = geometry[plotFrame].origin
                guard let start: Double = proxy.value(atX: drag.startLocation.x - origin.x),
                      let end: Double = proxy.value(atX: drag.location.x - origin.x) else { return }
                selection = min(start, end)...max(start, end)
            }
    }

    private var yDecimals: Int {
        let domain = yDomain
        return AxisNumber.decimals(forSpan: domain.upperBound - domain.lowerBound)
    }

    /// Sample numbers are whole; a time axis wants a little precision.
    private var xDecimals: Int {
        guard settings.xAxis == .time else { return 0 }
        guard let first = drawn.first, let last = drawn.last else { return 0 }
        return AxisNumber.decimals(forSpan: x(last) - x(first))
    }

    private var yDomain: ClosedRange<Double> {
        guard settings.autoAxis else {
            let lower = min(settings.manualMinimum, settings.manualMaximum)
            let upper = max(settings.manualMinimum, settings.manualMaximum)
            return lower...(upper > lower ? upper : lower + 1)
        }

        let statistics = Statistics.over(samples.map(\.value))
        var lowest = statistics.isEmpty ? 0 : statistics.minimum
        var highest = statistics.isEmpty ? 1 : statistics.maximum
        for marker in markers {
            lowest = min(lowest, marker.value)
            highest = max(highest, marker.value)
        }
        if highest - lowest < 1e-12 {
            let pad = max(abs(highest) * 0.001, 0.5)
            lowest -= pad
            highest += pad
        }
        let margin = (highest - lowest) * 0.08
        return (lowest - margin)...(highest + margin)
    }
}

/// The numbers under a chart: what is on screen, what was selected, and how the
/// series is doing overall.
struct SeriesInfoPanel: View {
    let samples: [Reading]
    let unit: String
    let overall: Statistics
    let selection: ClosedRange<Double>?
    let xAxis: GraphXAxis
    let onClearSelection: () -> Void

    private var origin: Date? { samples.first?.timestamp }

    private func x(_ sample: Reading) -> Double {
        switch xAxis {
        case .sampleNumber: return Double(sample.index)
        case .time: return sample.timestamp.timeIntervalSince(origin ?? sample.timestamp)
        }
    }

    private var selected: [Reading] {
        guard let selection else { return [] }
        return samples.filter { selection.contains(x($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                GridRow {
                    Text("Samples held: \(samples.count)")
                    Text("Maximum: \(engineering(overall.isEmpty ? nil : overall.maximum))")
                    Text("Mean: \(engineering(overall.isEmpty ? nil : overall.mean))")
                }
                GridRow {
                    Text("Latest: \(engineering(samples.last?.value))")
                    Text("Minimum: \(engineering(overall.isEmpty ? nil : overall.minimum))")
                    Text("σ: \(engineering(overall.isEmpty ? nil : overall.standardDeviation))")
                }
                GridRow {
                    Text(samples.last.map { DateFormatter.logTimestamp.string(from: $0.timestamp) } ?? "—")
                    Text("Peak-peak: \(engineering(overall.isEmpty ? nil : overall.peakToPeak))")
                    Text("Counted: \(overall.count)")
                }
            }

            if selection != nil {
                Divider()
                let statistics = Statistics.over(selected.map(\.value))
                HStack(spacing: 24) {
                    Text("Selected: \(statistics.count)")
                    Text("Min: \(engineering(statistics.isEmpty ? nil : statistics.minimum))")
                    Text("Max: \(engineering(statistics.isEmpty ? nil : statistics.maximum))")
                    Text("Mean: \(engineering(statistics.isEmpty ? nil : statistics.mean))")
                    Text("σ: \(engineering(statistics.isEmpty ? nil : statistics.standardDeviation))")
                    Spacer()
                    Button("Clear Selection", action: onClearSelection)
                        .controlSize(.small)
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Text("Drag across the plot to select a region and see its statistics; click once to clear.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func engineering(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: unit) } ?? "—"
    }
}
