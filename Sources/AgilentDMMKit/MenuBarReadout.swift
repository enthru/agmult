import SwiftUI
import Observation
import DMMCore

/// The reading as it appears in the menu bar, sampled on a slow timer.
///
/// Not simply `controller.formattedReading`: at twenty readings a second the
/// menu bar would redraw twenty times a second, the width of the item would
/// twitch on every digit, and nothing about a number changing that fast can be
/// read anyway. Two updates a second is as fast as the eye has any use for.
///
/// The timer is also what keeps the observation graph out of it. A view that
/// read the controller directly would be invalidated by every snapshot; this
/// object reads it from a timer callback instead, so only `title` changes and
/// only the menu bar item redraws.
@MainActor
@Observable
final class MenuBarReadout {

    /// What the menu bar shows: the reading, or a dash when there is nothing.
    private(set) var title = "—"
    private(set) var isConnected = false

    static let updateInterval: TimeInterval = 0.5

    @ObservationIgnored private weak var controller: DMMController?
    @ObservationIgnored private var timer: Timer?

    init(controller: DMMController) {
        self.controller = controller
        start()
    }

    deinit {
        timer?.invalidate()
    }

    private func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // Common mode, or the reading freezes for as long as a menu is open —
        // which is precisely when somebody is looking at it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    /// Reads the controller and publishes only what changed.
    func sample() {
        guard let controller else { return }
        let connected = controller.isConnected
        if isConnected != connected { isConnected = connected }

        let text = connected ? Self.compactReading(of: controller) : "—"
        if title != text { title = text }
    }

    /// The reading, trimmed to something a menu bar can hold. The full display
    /// runs to `1000.0000 mV`; twelve characters is the width past which the
    /// item starts pushing other apps' menus off a laptop screen.
    static func compactReading(of controller: DMMController) -> String {
        guard controller.latestReading != nil || controller.isOverloaded else { return "—" }
        let text = controller.formattedReading
        return text.count <= 12 ? text : String(text.prefix(12))
    }
}

/// What sits in the menu bar itself.
///
/// A monospaced digit font, or the item resizes on every changing digit and
/// drags every menu to its right along with it.
///
/// The text is always drawn, including the dash that stands for "no meter".
/// It began as an icon on its own until there was a reading to show, which made
/// the item impossible to find: a small anonymous glyph among a dozen other
/// small anonymous glyphs, saying nothing about which app it belonged to. An
/// item nobody can find is not a feature, however correctly it is installed.
struct MenuBarLabel: View {
    let readout: MenuBarReadout

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
            Text(readout.title).monospacedDigit()
        }
    }
}

/// The menu bar item: the reading in the bar, the statistics behind it.
struct MenuBarReadoutContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var controller: DMMController { model.controller }

    var body: some View {
        Group {
            if controller.isConnected {
                Text("\(controller.identity?.model ?? "Meter") · \(controller.configuration.function.title)")
                Divider()
                statistic("Reading", controller.formattedReading)
                statistic("Max", controller.statistics.maximum)
                statistic("Mean", controller.statistics.mean)
                statistic("Min", controller.statistics.minimum)
                statistic("σ", controller.statistics.standardDeviation)
                Text("\(controller.readingCount) readings · \(Format.number(controller.measuredRate, 1)) rdg/s")
            } else {
                Text("No meter connected")
            }

            Divider()

            Button("Show Main Window") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Show Graph") {
                openWindow(id: "graph")
                NSApp.activate()
            }
            Button("Speak the Reading") { controller.speakNow() }
                .disabled(!controller.readingIsValid)

            Divider()

            if controller.isConnected {
                Button("Disconnect") { controller.disconnect() }
            } else {
                Button("Connect…") {
                    model.isConnectionSheetPresented = true
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    /// A menu row is a single label; a `LabeledContent` would be drawn as one
    /// anyway, so the two halves are joined here with the value already
    /// formatted the way the readout panel formats it.
    private func statistic(_ name: String, _ value: Double?) -> some View {
        statistic(name, value.map { Format.engineering($0, unit: controller.displayUnit) } ?? "—")
    }

    private func statistic(_ name: String, _ text: String) -> some View {
        Text("\(name)   \(text)")
    }
}
