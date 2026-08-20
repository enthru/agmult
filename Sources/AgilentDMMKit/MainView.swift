import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DMMCore

/// The main window.
///
/// Laid out for the screen a bench Mac actually has rather than for a narrow
/// column: the readout across the top, the function keys as a row, the
/// remaining controls in a grid that takes two columns when there is width for
/// them, and the whole right-hand side given over to the live trace with the
/// readings underneath it. The controls used to be six boxes stacked in one
/// narrow column, which meant scrolling past three of them to reach the fourth
/// while two thirds of a wide window sat empty.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var detail: DetailPane = .readings
    @State private var selection: ClosedRange<Double>?

    private var controller: DMMController { model.controller }

    enum DetailPane: String, CaseIterable, Identifiable {
        case readings, events

        var id: String { rawValue }
        var title: String { self == .readings ? "Readings" : "Events" }
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ReadoutPanel()
            InstrumentStrip()
            Divider()

            HSplitView {
                controls
                    .frame(minWidth: 330, idealWidth: 700)

                liveData
                    .frame(minWidth: 320, idealWidth: 620)
            }

            StatusBar()
        }
        .frame(minWidth: 960, minHeight: 700)
        .sheet(isPresented: $model.isConnectionSheetPresented) {
            ConnectionView()
        }
        .navigationTitle(controller.deviceTitle)
        .navigationSubtitle(controller.isConnected ? controller.portDisplayName : "not connected")
        .focusedSceneValue(\.exportAction, exportAction)
        .onDisappear { controller.disconnect() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            FunctionBar()
            Divider()
            ScrollableColumn {
                ControlGrid()
            }
        }
    }

    // MARK: - Live data

    /// The trace over the readings that produced it. A split rather than tabs:
    /// watching the curve and reading the numbers is the same activity.
    ///
    /// Both halves are told to fill the width. A `VSplitView` takes its width
    /// from its children, and children that merely hug their content leave the
    /// split sized to the widest label in it — which put the divider two thirds
    /// of the way across the pane and stranded everything to the left of it.
    private var liveData: some View {
        VSplitView {
            VStack(spacing: 0) {
                if controller.history.isEmpty {
                    // A blank white rectangle explains nothing. Say what is
                    // missing and how to get some.
                    ContentUnavailableView {
                        Label("No readings yet", systemImage: "waveform.path.ecg")
                    } description: {
                        Text(controller.isConnected
                             ? "The trace appears as readings arrive."
                             : "Connect a meter, or Config ▸ Start Built-in Simulator to try it without one.")
                    } actions: {
                        if !controller.isConnected {
                            Button("Select Serial Port…") { model.isConnectionSheetPresented = true }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MeasurementTrace(selection: $selection)
                        .padding(8)
                        .background(model.graph.figureBackground.color)

                    if let selection {
                        selectionSummary(selection)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, idealHeight: 380)

            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $detail) {
                        ForEach(DetailPane.allCases) { pane in
                            Text(pane.title).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                    Text(detail == .readings
                         ? "\(controller.tableReadings.count) shown"
                         : "\(controller.entries.count) entries")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Divider()

                switch detail {
                case .readings:
                    if controller.tableReadings.isEmpty {
                        emptyPane("No readings yet")
                    } else {
                        ReadingsTable()
                    }
                case .events:
                    if controller.entries.isEmpty {
                        emptyPane("Nothing has happened yet")
                    } else {
                        EventListView()
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 220)
        }
    }

    private func emptyPane(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Statistics for a dragged-out region, without leaving the main window.
    private func selectionSummary(_ range: ClosedRange<Double>) -> some View {
        let samples = controller.history.samples.filter { sample in
            let x = model.graph.xAxis == .sampleNumber
                ? Double(sample.index)
                : sample.timestamp.timeIntervalSince(controller.history.samples.first?.timestamp ?? sample.timestamp)
            return range.contains(x)
        }
        let statistics = Statistics.over(samples.map(\.value))

        return HStack(spacing: 16) {
            Text("Selected \(statistics.count)")
            Text("Min \(engineering(statistics.isEmpty ? nil : statistics.minimum))")
            Text("Max \(engineering(statistics.isEmpty ? nil : statistics.maximum))")
            Text("Mean \(engineering(statistics.isEmpty ? nil : statistics.mean))")
            Text("σ \(engineering(statistics.isEmpty ? nil : statistics.standardDeviation))")
            Spacer()
            Button("Clear") { selection = nil }
                .controlSize(.mini)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func engineering(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: controller.displayUnit) } ?? "—"
    }

    // MARK: - Export

    private var exportAction: ExportAction {
        switch detail {
        case .readings:
            return ExportAction(title: "Export Readings…", perform: exportReadings)
        case .events:
            return ExportAction(title: "Export Event List…", perform: exportEntries)
        }
    }

    private func exportEntries() {
        let text = controller.entries.map(\.text).joined(separator: "\n") + "\n"
        Exporter.save(Data(text.utf8), suggestedName: "Event-List.txt", type: .plainText)
    }

    private func exportReadings() {
        let csv = SampleBuffer.csv(controller.tableReadings,
                                   valueHeader: "\(controller.configuration.function.shortTitle) (\(controller.displayUnit))")
        Exporter.save(Data(csv.utf8), suggestedName: "Readings.csv", type: .commaSeparatedText)
    }
}

/// A scrolling column whose scroller is visible whenever there is something to
/// scroll — and absent when there is not.
///
/// macOS overlay scrollers fade out a second after the scroll stops, so a pane
/// with more content below looks exactly like a pane with nothing below;
/// `.scrollIndicators(.visible)` asks for a visible indicator and still gets one
/// that disappears. The legacy scroller reserves its own strip and does not
/// fade. Its `autohidesScrollers` is left on, which for that style means "hide
/// when the content fits" rather than "hide after scrolling" — so an area that
/// cannot scroll does not grow a scroll bar to say so.
struct ScrollableColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .background(PersistentScroller().frame(width: 0, height: 0))
        }
    }
}

/// Switches the enclosing `NSScrollView` to a scroller that does not fade.
///
/// A zero-sized probe rather than a wrapper: it only needs to reach the scroll
/// view SwiftUI already made, and wrapping the whole column in an
/// `NSViewRepresentable` would mean giving up SwiftUI's layout inside it.
private struct PersistentScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureEnclosingScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureEnclosingScrollView()
        }

        private func configureEnclosingScrollView() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.hasVerticalScroller = true
            // Left on deliberately: for a legacy scroller this means "only when
            // the content does not fit", which is the whole point.
            scrollView.autohidesScrollers = true

            // A legacy scroller at its regular size takes a fifteen-point strip
            // out of a column that is already narrow. The small control size is
            // about two thirds of that and still plainly a scroll bar.
            scrollView.verticalScroller?.controlSize = .small
            scrollView.tile()
        }
    }
}

/// The control boxes, in as many columns as the width allows.
///
/// Its own view so a test can render it at the size the window gives it and
/// check that everything fits without scrolling — which is the whole point of
/// the grid.
struct ControlGrid: View {
    /// Two columns as soon as the pane is wide enough for them, one when it is
    /// not. Nothing here is tall, so wrapping costs nothing and saves the scroll.
    ///
    /// Three hundred is the width the panels were tightened to fit in: at the
    /// default split that is two columns, where three hundred and thirty was one
    /// by a margin of thirty points.
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            RangeBox()
            TriggerBox()
            MathBox()
            UtilityBox()
        }
        .padding(10)
    }
}

/// Every reading as it arrives, which is the "measurement table" of the original.
struct ReadingsTable: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    var body: some View {
        ScrollViewReader { proxy in
            List(controller.tableReadings) { reading in
                HStack(spacing: 8) {
                    Text(String(reading.index))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    Text(DateFormatter.tableTimestamp.string(from: reading.timestamp))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(controller.formatted(reading.value))
                }
                .font(.system(size: 11, design: .monospaced))
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .id(reading.index)
            }
            .listStyle(.plain)
            .onChange(of: controller.tableReadings.count) {
                guard controller.autoScroll, let last = controller.tableReadings.last else { return }
                proxy.scrollTo(last.index, anchor: .bottom)
            }
        }
    }
}

/// The scrolling record of everything that happened: entries are "text,time" and
/// can be paused or cleared.
struct EventListView: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    var body: some View {
        ScrollViewReader { proxy in
            List(controller.entries) { entry in
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: controller.entries.count) {
                guard controller.autoScroll, let last = controller.entries.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    var body: some View {
        HStack(spacing: 14) {
            Text("Runtime \(Format.duration(controller.runtime))")

            Divider().frame(height: 14)

            Text("\(controller.readingCount) readings · \(Format.number(controller.measuredRate, 1)) rdg/s")

            if controller.overloadCount > 0 {
                Text("\(controller.overloadCount) overload\(controller.overloadCount == 1 ? "" : "s")")
                    .foregroundStyle(.red)
            }

            if controller.logReadingsText || controller.logReadingsCSV || controller.logStatusText {
                Divider().frame(height: 14)
                Label("Logging", systemImage: "record.circle")
                    .foregroundStyle(.red)
            }

            if controller.speech.isEnabled {
                Divider().frame(height: 14)
                Label("Speaking", systemImage: "speaker.wave.2")
            }

            Spacer()

            Text("History \(controller.history.samples.count) / \(controller.history.capacity)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// One save panel, used by every window that can export something.
enum Exporter {
    static func save(_ data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Renders a view to a PNG at twice the on-screen size and saves it.
    @MainActor
    static func savePNG(of view: some View, size: CGSize, suggestedName: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        save(png, suggestedName: suggestedName, type: .png)
    }
}
