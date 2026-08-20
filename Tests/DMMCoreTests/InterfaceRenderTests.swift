import XCTest
import SwiftUI
@testable import DMMCore
@testable import DMMSimulator
@testable import AgilentDMMKit

/// Renders the real SwiftUI views off-screen against live simulator data.
///
/// This catches layout and binding faults that a logic-only test cannot, and the
/// rendered images are written to `AGMULT_RENDER_DIR` when that variable is set,
/// so the interface can be inspected without launching the app.
@MainActor
final class InterfaceRenderTests: XCTestCase {

    private var server: SimulatorServer!
    private var model: AppModel!

    override func setUp() async throws {
        let meter = Simulated34401A()
        meter.simulatesTiming = false
        meter.signal.modulation = .sine
        meter.signal.modulationDepth = 0.01
        meter.signal.modulationPeriod = 3
        meter.signal[.dcVoltage] = 4.19

        server = try SimulatorServer(meter: meter)
        server.start()

        model = AppModel(store: .ephemeral())
        model.controller.beeperEnabled = false
        model.controller.updateInterval = 0
        model.controller.pollPlan.configurationInterval = 5

        let config = SerialConfig(path: server.devicePath, readTimeout: 2, writeTimeout: 2)
        let identity = try ConnectionProbe.identify(config: config)
        model.controller.connect(config: config, identity: identity)
        model.controller.setSampleCount(20)

        // A derived waveform, so the math window has something real to draw.
        let waveform = model.addWaveform()
        waveform.recipe = WaveformRecipe(operation: .movingAverage, parameterA: 8)

        // Wait for a history worth plotting rather than a single point.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if model.controller.history.samples.count > 200 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    override func tearDown() async throws {
        model?.controller.disconnect()
        server?.stop()
        model = nil
        server = nil
    }

    func testTheSimulatorProducedSomethingWorthDrawing() {
        XCTAssertGreaterThan(model.controller.history.samples.count, 100)
        XCTAssertEqual(model.controller.latestReading!, 4.19, accuracy: 0.1)
    }

    /// `ImageRenderer` cannot draw AppKit-backed controls (List, Form, TextField,
    /// HSplitView), so these windows come out partly blank. Rendering them is
    /// still worth doing: it evaluates every view body and binding, which is
    /// where a mis-wired key path or a missing environment value would show up.
    /// The layout complaint this replaced: six boxes stacked in one narrow
    /// column, so reaching the fourth meant scrolling past three while most of a
    /// wide window sat empty. The grid has to fit in the space the window
    /// actually gives it.
    func testControlsFitWithoutScrollingAtTheDefaultWindowSize() throws {
        // Left pane of a 1320-wide window, minus the readout, strip and status
        // bar from an 880-tall one.
        let pane = CGSize(width: 660, height: 600)
        let image = try render(ControlGrid().environment(model), size: pane)
        try write(image, named: "control-grid.png")

        let needed = height(ofControlsAtWidth: pane.width)
        XCTAssertLessThanOrEqual(needed, pane.height,
                                 "the controls want \(needed) points and have \(pane.height)")
    }

    /// The panels were tightened until two columns fit in the pane the default
    /// window actually gives them — the first attempt missed by thirty points
    /// and silently fell back to one.
    func testControlsCollapseToOneColumnWhenNarrow() throws {
        let narrow = height(ofControlsAtWidth: 340)
        let wide = height(ofControlsAtWidth: 660)
        XCTAssertGreaterThan(narrow, wide,
                             "one column (\(narrow)) has to be taller than two (\(wide))")
    }

    /// Height the control grid needs at a given width.
    ///
    /// The width is pinned inside the SwiftUI hierarchy rather than on the
    /// hosting view: `fittingSize` measures the content, and a frame set on the
    /// AppKit view outside it is not a constraint the layout ever sees.
    private func height(ofControlsAtWidth width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: ControlGrid().environment(model).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The scrolling column has to build and render whether or not its content
    /// overflows — the overflow affordance is an overlay on the same view.
    func testScrollingColumnRendersWithAndWithoutOverflow() throws {
        let tall = try render(ScrollableColumn { ControlGrid() }.environment(model),
                              size: CGSize(width: 340, height: 200))
        XCTAssertGreaterThan(tall.size.width, 0)
        try write(tall, named: "controls-overflowing.png")

        let roomy = try render(ScrollableColumn { ControlGrid() }.environment(model),
                               size: CGSize(width: 660, height: 700))
        XCTAssertGreaterThan(roomy.size.width, 0)
    }

    func testMainWindowBuildsAndRenders() throws {
        let image = try render(MainView().environment(model), size: CGSize(width: 1320, height: 880))
        XCTAssertGreaterThan(image.size.width, 0)
        try write(image, named: "main-window.png")
    }

    func testReadoutPanelShowsLiveValues() throws {
        XCTAssertTrue(model.controller.readingIsValid, "the panel needs a real reading to show")
        let image = try render(ReadoutPanel().environment(model).frame(width: 940),
                               size: CGSize(width: 940, height: 240))
        try write(image, named: "readout-panel.png")
    }

    /// The reading row used to be pinned to a fixed height shorter than its own
    /// contents, and an oversized child in SwiftUI is not clipped — it is drawn
    /// over whatever is next to it. Rendering the panel with the floor taken
    /// away must give the same height as rendering it normally: with content
    /// present, the floor is not what decides the size.
    func testTheReadingRowIsSizedByItsContentsRatherThanClampedToAFixedHeight() throws {
        XCTAssertTrue(model.controller.readingIsValid,
                      "the collision only appears once there is a reading and a timestamp to collide")

        let withFloor = try naturalHeight(of: ReadoutPanel().environment(model), width: 940)
        let withoutFloor = try naturalHeight(of: ReadoutPanel(minimumReadingRowHeight: 0).environment(model),
                                             width: 940)
        XCTAssertEqual(withFloor, withoutFloor, accuracy: 0.5,
                       "the row is being clamped to \(withFloor - withoutFloor) points less than it needs")
    }

    /// The menu bar item, drawn against a live meter. Its label is what the
    /// system puts in the bar and its content is a menu, which `ImageRenderer`
    /// will not draw — but evaluating the body is what catches a binding that
    /// went stale, and the label is real drawing.
    func testTheMenuBarItemRendersWhatItWillShow() throws {
        let readout = MenuBarReadout(controller: model.controller)
        readout.sample()
        XCTAssertTrue(readout.isConnected)
        XCTAssertTrue(readout.title.contains("V"), "expected a voltage, got \(readout.title)")
        XCTAssertLessThanOrEqual(readout.title.count, 12, "the menu bar is not a place for a long number")

        try write(try render(MenuBarLabel(readout: readout), size: CGSize(width: 140, height: 24)),
                  named: "menu-bar-label.png")

        // And with no meter: still a legible item rather than a bare glyph.
        model.controller.disconnect()
        readout.sample()
        XCTAssertFalse(readout.title.isEmpty)
        try write(try render(MenuBarLabel(readout: readout), size: CGSize(width: 140, height: 24)),
                  named: "menu-bar-label-idle.png")
        let menu = try render(MenuBarReadoutContent().environment(model),
                              size: CGSize(width: 260, height: 320))
        XCTAssertGreaterThan(menu.size.width, 0)
    }

    func testControlPanelsRender() throws {
        try write(try render(FunctionBar().environment(model), size: CGSize(width: 700, height: 90)),
                  named: "panel-function.png")
        try write(try render(RangeBox().environment(model), size: CGSize(width: 480, height: 220)),
                  named: "panel-range.png")
        try write(try render(TriggerBox().environment(model), size: CGSize(width: 480, height: 260)),
                  named: "panel-trigger.png")
        try write(try render(MathBox().environment(model), size: CGSize(width: 480, height: 200)),
                  named: "panel-math.png")
        try write(try render(UtilityBox().environment(model), size: CGSize(width: 480, height: 180)),
                  named: "panel-utility.png")
        try write(try render(InstrumentStrip().environment(model), size: CGSize(width: 900, height: 60)),
                  named: "panel-info.png")
    }

    /// Each function shows a different set of controls; every one of those
    /// branches has to build.
    func testEveryFunctionsControlsRender() throws {
        for function in MeasurementFunction.allCases {
            model.controller.setFunction(function)
            let image = try render(RangeBox().environment(model), size: CGSize(width: 480, height: 240))
            XCTAssertGreaterThan(image.size.width, 0, "\(function) failed to render")
        }
    }

    /// Same for the maths: each choice swaps in its own parameter row.
    func testEveryMathFunctionsControlsRender() throws {
        for math in MathFunction.allCases {
            model.controller.setMathFunction(math)
            let image = try render(MathBox().environment(model), size: CGSize(width: 480, height: 240))
            XCTAssertGreaterThan(image.size.width, 0, "\(math) failed to render")
        }
    }

    func testGraphWindowRenders() throws {
        try write(try render(GraphWindow().environment(model), size: CGSize(width: 940, height: 600)),
                  named: "graph.png")

        model.graph.xAxis = .time
        model.graph.showPoints = true
        model.graph.apply(theme: .black)
        try write(try render(GraphWindow().environment(model), size: CGSize(width: 940, height: 600)),
                  named: "graph-time-black.png")
    }

    func testStabilityWindowRenders() throws {
        XCTAssertNotNil(AllanDeviation.compute(readings: model.controller.history.samples),
                        "the window needs a curve to draw")
        try write(try render(StabilityWindow().environment(model), size: CGSize(width: 940, height: 620)),
                  named: "stability.png")
    }

    /// Before enough readings have arrived there is no curve, and the window has
    /// to say so rather than draw an empty pair of log axes.
    func testStabilityWindowSaysSoWhenThereIsNothingToAnalyse() throws {
        model.controller.resetHistory()
        let image = try render(StabilityWindow().environment(model), size: CGSize(width: 800, height: 500))
        XCTAssertGreaterThan(image.size.width, 0)
        try write(image, named: "stability-empty.png")
    }

    func testHistogramWindowRenders() throws {
        try write(try render(HistogramWindow().environment(model), size: CGSize(width: 900, height: 560)),
                  named: "histogram.png")
    }

    func testMathWaveformWindowRenders() throws {
        let waveform = try XCTUnwrap(model.waveforms.first)
        XCTAssertFalse(model.samples(for: waveform.id).isEmpty, "the transform produced nothing to draw")

        try write(try render(MathWaveformWindow(waveformID: waveform.id).environment(model),
                             size: CGSize(width: 1000, height: 640)),
                  named: "math-waveform.png")
    }

    /// Every transform, rendered through the real window, so a divide-by-zero or
    /// an empty result cannot take the view down.
    func testEveryWaveformOperationRenders() throws {
        let waveform = try XCTUnwrap(model.waveforms.first)
        for operation in WaveformOperation.allCases {
            waveform.recipe = WaveformRecipe(operation: operation)
            let image = try render(MathWaveformWindow(waveformID: waveform.id).environment(model),
                                   size: CGSize(width: 900, height: 560))
            XCTAssertGreaterThan(image.size.width, 0, "\(operation) failed to render")
        }
    }

    /// A waveform whose source has been deleted must show something sensible
    /// rather than crash the window it is still open in.
    func testAWaveformWindowSurvivesItsWaveformBeingDeleted() throws {
        let waveform = try XCTUnwrap(model.waveforms.first)
        model.removeWaveform(id: waveform.id)
        let image = try render(MathWaveformWindow(waveformID: waveform.id).environment(model),
                               size: CGSize(width: 700, height: 400))
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testConnectionWindowBuildsAndRenders() throws {
        try write(try render(ConnectionView().environment(model), size: CGSize(width: 720, height: 400)),
                  named: "connection.png")
    }

    /// The Settings window (⌘,) — each pane is rendered on its own, since a
    /// TabView only builds the tab that is showing.
    func testSettingsWindowRenders() throws {
        try write(try render(SettingsView().environment(model), size: CGSize(width: 580, height: 460)),
                  named: "settings.png")
        try write(try render(GeneralSettings().environment(model), size: CGSize(width: 580, height: 460)),
                  named: "settings-general.png")
        try write(try render(AcquisitionSettings().environment(model), size: CGSize(width: 580, height: 500)),
                  named: "settings-acquisition.png")
        try write(try render(GraphsSettings().environment(model), size: CGSize(width: 580, height: 640)),
                  named: "settings-graphs.png")
        try write(try render(LoggingSettings().environment(model), size: CGSize(width: 580, height: 460)),
                  named: "settings-logging.png")
        try write(try render(SpeechSettings().environment(model), size: CGSize(width: 580, height: 500)),
                  named: "settings-speech.png")
    }

    func testHelpWindowsRender() throws {
        try write(try render(GeneralHelpView(), size: CGSize(width: 640, height: 900)), named: "help-general.png")
        try write(try render(SerialHelpView(), size: CGSize(width: 640, height: 900)), named: "help-serial.png")
        try write(try render(CreditsView(), size: CGSize(width: 640, height: 600)), named: "credits.png")
    }

    // MARK: - Helpers

    private func render(_ view: some View, size: CGSize) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "the view failed to render")
    }

    /// The height a view takes when only its width is decided for it — which is
    /// what a layout that overflows its own frame will not report honestly.
    private func naturalHeight(of view: some View, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return try XCTUnwrap(renderer.nsImage, "the view failed to render").size.height
    }

    private func write(_ image: NSImage, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGMULT_RENDER_DIR"] else { return }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode \(name)")
            return
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}
