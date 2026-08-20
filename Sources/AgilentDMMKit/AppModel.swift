import SwiftUI
import DMMCore
import DMMSimulator

/// Named colours offered by the panel and graph colour menus.
enum PanelColor: String, CaseIterable, Identifiable, Sendable {
    case green, blue, cyan, red, yellow, orange, white, black, pink, violet, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .green: return Color(red: 0.10, green: 0.80, blue: 0.30)
        case .blue: return Color(red: 0.16, green: 0.50, blue: 0.95)
        case .cyan: return Color(red: 0.10, green: 0.68, blue: 0.94)
        case .red: return Color(red: 0.92, green: 0.22, blue: 0.20)
        case .yellow: return Color(red: 0.95, green: 0.80, blue: 0.10)
        case .orange: return Color(red: 0.98, green: 0.55, blue: 0.10)
        case .white: return .white
        case .black: return .black
        case .pink: return Color(red: 0.96, green: 0.40, blue: 0.65)
        case .violet: return Color(red: 0.60, green: 0.35, blue: 0.92)
        case .gray: return Color(white: 0.35)
        }
    }
}

enum GraphXAxis: String, CaseIterable, Identifiable, Sendable {
    case sampleNumber, time

    var id: String { rawValue }

    var title: String {
        self == .sampleNumber ? "Sample Number" : "Time (s)"
    }
}

enum GraphTheme: String, CaseIterable, Identifiable {
    case standard, black, blue, gray, grayBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default Theme"
        case .black: return "Black Theme"
        case .blue: return "Blue Theme"
        case .gray: return "Gray Theme"
        case .grayBlack: return "Gray Black Theme"
        }
    }
}

/// Appearance and marker settings for one graph window.
@MainActor
@Observable
final class GraphSettings {
    var curveColor: PanelColor = .cyan
    var plotBackground: PanelColor = .white
    var figureBackground: PanelColor = .white
    var autoAxis = true
    var manualMinimum: Double = 0
    var manualMaximum: Double = 1
    var showPoints = false
    var showMean = true
    var showExtremes = true
    var showLimits = false
    var xAxis: GraphXAxis = .sampleNumber
    /// The last preset applied, so the Settings window can show which is in use.
    private(set) var theme: GraphTheme = .standard

    init(curveColor: PanelColor = .cyan) {
        self.curveColor = curveColor
    }

    var preferences: Preferences.Graph {
        Preferences.Graph(curveColor: curveColor,
                          plotBackground: plotBackground,
                          figureBackground: figureBackground,
                          theme: theme,
                          autoAxis: autoAxis,
                          manualMinimum: manualMinimum,
                          manualMaximum: manualMaximum,
                          showPoints: showPoints,
                          showMean: showMean,
                          showExtremes: showExtremes,
                          showLimits: showLimits,
                          xAxis: xAxis)
    }

    func apply(_ saved: Preferences.Graph) {
        // The theme first: it sets the two background colours, which the saved
        // values then override in case they were changed after it was picked.
        apply(theme: saved.theme)
        curveColor = saved.curveColor
        plotBackground = saved.plotBackground
        figureBackground = saved.figureBackground
        autoAxis = saved.autoAxis
        manualMinimum = saved.manualMinimum
        manualMaximum = saved.manualMaximum
        showPoints = saved.showPoints
        showMean = saved.showMean
        showExtremes = saved.showExtremes
        showLimits = saved.showLimits
        xAxis = saved.xAxis
    }

    func apply(theme: GraphTheme) {
        self.theme = theme
        switch theme {
        case .standard:
            plotBackground = .white
            figureBackground = .white
        case .black:
            plotBackground = .black
            figureBackground = .black
        case .blue:
            plotBackground = .white
            figureBackground = .blue
        case .gray:
            plotBackground = .white
            figureBackground = .gray
        case .grayBlack:
            plotBackground = .black
            figureBackground = .gray
        }
    }
}

/// A derived series the user built from the readings — or from another derived
/// series. `source` being nil means "the live measurement".
@MainActor
@Observable
final class MathWaveform: Identifiable {
    /// Given rather than generated, so a chain of waveforms still points at the
    /// right sources after the application has been restarted.
    let id: UUID
    var name: String
    var recipe: WaveformRecipe
    var source: UUID?
    var settings: GraphSettings

    init(id: UUID = UUID(),
         name: String,
         recipe: WaveformRecipe = WaveformRecipe(),
         source: UUID? = nil,
         color: PanelColor = .orange) {
        self.id = id
        self.name = name
        self.recipe = recipe
        self.source = source
        self.settings = GraphSettings(curveColor: color)
    }
}

@MainActor
@Observable
final class HistogramSettings {
    var binCount = 64
    var source: UUID?
    var barColor: PanelColor = .violet
    var plotBackground: PanelColor = .white
    var showNormalMarkers = true
}

/// Application-wide state: the instrument controller plus everything that is
/// purely presentation (panel colours, graph settings, derived waveforms and the
/// built-in simulator).
@MainActor
@Observable
final class AppModel {
    /// The model the running application is using.
    ///
    /// App Intents arrive from outside the view hierarchy — there is no
    /// environment to read them out of — and the serial port is open in this one
    /// process, so there is exactly one model they could mean. Set by the app at
    /// launch and by nothing else: a test making its own model must not become
    /// the one Shortcuts talks to.
    static var current: AppModel?

    var controller = DMMController()

    /// Notification banners for the handful of events worth interrupting for.
    let alerts = AlertCentre()

    /// The live reading in the menu bar. Off costs nothing; on, it is the only
    /// way to watch a capture without giving it a window.
    var showsMenuBarReading = true

    private let store: PreferenceStore
    private var saveTask: Task<Void, Never>?

    var panelTextColor: PanelColor = .green
    var panelBackground: PanelColor = .black
    /// Draw every retained reading rather than a decimated curve. Honest, and
    /// unusably slow past a few tens of thousands of points — hence the warning
    /// beside it in Settings.
    var drawsEveryPoint = false

    var graph = GraphSettings(curveColor: .cyan)
    var histogram = HistogramSettings()
    var waveforms: [MathWaveform] = []

    var isConnectionSheetPresented = false
    /// Which series the stability window is analysing.
    var stabilitySource: UUID?
    /// The port that worked last time, offered again by the connection window.
    var lastConnection: SerialConfig?

    private(set) var simulator: SimulatorServer?
    var simulatorPath: String? { simulator?.devicePath }

    /// The signal the built-in simulator is pretending to measure, so the demo
    /// can be steered from the app rather than only from the command line.
    var simulatedSignal: SimulatedSignal? { simulator?.signal }

    /// - Parameter store: where settings are read from and written to. Tests
    ///   pass an ephemeral store so a run never touches the real ones. Resolved
    ///   inside the initialiser rather than as a default argument, which would
    ///   be evaluated outside the main actor.
    init(store: PreferenceStore? = nil) {
        self.store = store ?? .standard
        if let saved = self.store.load() {
            apply(saved)
        }
        controller.alerts = alerts
        observeForSaving()
    }

    // MARK: - Persistence

    /// The current state of everything worth remembering.
    ///
    /// Reading this is also what registers the observation: whatever it touches
    /// is what triggers a save when it changes. Live measurement state is
    /// deliberately absent — the reading history changes many times a second and
    /// has no business waking the settings writer.
    var preferences: Preferences {
        var preferences = Preferences()

        preferences.panelTextColor = panelTextColor
        preferences.panelBackground = panelBackground
        preferences.drawsEveryPoint = drawsEveryPoint

        preferences.graph = graph.preferences
        preferences.histogram = Preferences.Histogram(
            binCount: histogram.binCount,
            barColor: histogram.barColor,
            plotBackground: histogram.plotBackground,
            showNormalMarkers: histogram.showNormalMarkers,
            source: histogram.source
        )
        preferences.waveforms = waveforms.map {
            Preferences.Waveform(id: $0.id,
                                 name: $0.name,
                                 recipe: $0.recipe,
                                 source: $0.source,
                                 graph: $0.settings.preferences)
        }
        preferences.stabilitySource = stabilitySource

        preferences.meter = controller.configuration
        preferences.math = controller.math
        preferences.pollPlan = controller.pollPlan
        preferences.updateInterval = controller.updateInterval
        preferences.lineFrequency = controller.lineFrequency
        preferences.usesCompoundQueries = controller.usesCompoundQueries

        preferences.historyCapacity = controller.historyCapacity
        preferences.tableCapacity = controller.tableCapacity
        preferences.autoScroll = controller.autoScroll
        preferences.updateList = controller.updateList
        preferences.addReadingsToList = controller.addReadingsToList
        preferences.beeperEnabled = controller.beeperEnabled

        preferences.logReadingsText = controller.logReadingsText
        preferences.logReadingsCSV = controller.logReadingsCSV
        preferences.logStatusText = controller.logStatusText
        preferences.logDirectoryPath = controller.logDirectory.path

        preferences.alerts = Preferences.Alerts(isEnabled: alerts.isEnabled,
                                                kinds: alerts.kinds,
                                                onlyWhenInBackground: alerts.onlyWhenInBackground)
        preferences.showsMenuBarReading = showsMenuBarReading

        preferences.speech = Preferences.Speech(
            isEnabled: controller.speech.isEnabled,
            speaksPeriodically: controller.speech.speaksPeriodically,
            interval: controller.speech.interval,
            rate: controller.speech.rate,
            upperThreshold: controller.speech.upperThreshold,
            lowerThreshold: controller.speech.lowerThreshold
        )
        preferences.lastConnection = lastConnection

        return preferences
    }

    func apply(_ preferences: Preferences) {
        panelTextColor = preferences.panelTextColor
        panelBackground = preferences.panelBackground
        drawsEveryPoint = preferences.drawsEveryPoint

        graph.apply(preferences.graph)
        histogram.binCount = preferences.histogram.binCount
        histogram.barColor = preferences.histogram.barColor
        histogram.plotBackground = preferences.histogram.plotBackground
        histogram.showNormalMarkers = preferences.histogram.showNormalMarkers
        histogram.source = preferences.histogram.source

        waveforms = preferences.waveforms.map { saved in
            let waveform = MathWaveform(id: saved.id, name: saved.name, recipe: saved.recipe, source: saved.source)
            waveform.settings.apply(saved.graph)
            return waveform
        }
        stabilitySource = preferences.stabilitySource

        controller.restore(configuration: preferences.meter, math: preferences.math)
        controller.pollPlan = preferences.pollPlan
        controller.updateInterval = preferences.updateInterval
        controller.lineFrequency = preferences.lineFrequency
        controller.usesCompoundQueries = preferences.usesCompoundQueries

        controller.historyCapacity = preferences.historyCapacity
        controller.tableCapacity = preferences.tableCapacity
        controller.autoScroll = preferences.autoScroll
        controller.updateList = preferences.updateList
        controller.addReadingsToList = preferences.addReadingsToList
        controller.beeperEnabled = preferences.beeperEnabled

        controller.logReadingsText = preferences.logReadingsText
        controller.logReadingsCSV = preferences.logReadingsCSV
        controller.logStatusText = preferences.logStatusText
        if let path = preferences.logDirectoryPath {
            controller.setLogDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }

        alerts.kinds = preferences.alerts.kinds
        alerts.onlyWhenInBackground = preferences.alerts.onlyWhenInBackground
        // Last, and only if it was on: assigning `isEnabled` re-asks the system,
        // which is silent once an answer exists — anybody with this saved has
        // been asked already — and refreshes what Settings reports, so a
        // permission revoked in System Settings shows up here rather than in a
        // banner that never arrives.
        if preferences.alerts.isEnabled { alerts.isEnabled = true }
        showsMenuBarReading = preferences.showsMenuBarReading

        controller.speech.isEnabled = preferences.speech.isEnabled
        controller.speech.speaksPeriodically = preferences.speech.speaksPeriodically
        controller.speech.interval = preferences.speech.interval
        controller.speech.rate = preferences.speech.rate
        controller.speech.upperThreshold = preferences.speech.upperThreshold
        controller.speech.lowerThreshold = preferences.speech.lowerThreshold

        lastConnection = preferences.lastConnection
    }

    /// Watches everything `preferences` reads and re-arms itself after each
    /// change. `onChange` runs before the new value is in place, hence the hop
    /// to the next turn of the main actor before anything is collected.
    private func observeForSaving() {
        withObservationTracking {
            _ = preferences
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSave()
                self.observeForSaving()
            }
        }
    }

    /// Dragging a slider changes a setting sixty times a second; there is no
    /// reason for the disk to hear about all sixty.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes immediately — on quit, where there is no next turn to wait for.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        store.save(preferences)
    }

    // MARK: - Waveforms

    @discardableResult
    func addWaveform(source: UUID? = nil) -> MathWaveform {
        let palette: [PanelColor] = [.orange, .violet, .pink, .yellow, .green, .blue]
        let waveform = MathWaveform(
            name: "Math \(waveforms.count + 1)",
            source: source,
            color: palette[waveforms.count % palette.count]
        )
        waveforms.append(waveform)
        return waveform
    }

    func waveform(id: UUID?) -> MathWaveform? {
        guard let id else { return nil }
        return waveforms.first { $0.id == id }
    }

    func removeWaveform(id: UUID) {
        // Anything fed by the waveform being removed falls back to the live
        // measurement rather than pointing at nothing.
        for waveform in waveforms where waveform.source == id {
            waveform.source = nil
        }
        waveforms.removeAll { $0.id == id }
    }

    /// Sources a waveform may draw from: the measurement, plus every other
    /// waveform that does not depend on this one.
    func availableSources(for waveform: MathWaveform) -> [MathWaveform] {
        waveforms.filter { $0.id != waveform.id && !dependsOn(waveform: $0, on: waveform.id) }
    }

    private func dependsOn(waveform: MathWaveform, on target: UUID, depth: Int = 0) -> Bool {
        guard depth < 32, let source = waveform.source else { return false }
        if source == target { return true }
        guard let parent = self.waveform(id: source) else { return false }
        return dependsOn(waveform: parent, on: target, depth: depth + 1)
    }

    /// Resolves a source to its samples, applying every transform in the chain.
    /// The depth limit is belt and braces: `availableSources(for:)` already keeps
    /// a cycle from being created in the first place.
    func samples(for source: UUID?, depth: Int = 0) -> [Reading] {
        guard let source, depth < 32 else { return controller.history.samples }
        guard let waveform = waveform(id: source) else { return controller.history.samples }
        return waveform.recipe.apply(to: samples(for: waveform.source, depth: depth + 1))
    }

    func unit(for source: UUID?, depth: Int = 0) -> String {
        guard let source, depth < 32 else { return controller.displayUnit }
        guard let waveform = waveform(id: source) else { return controller.displayUnit }
        return waveform.recipe.unit(from: unit(for: waveform.source, depth: depth + 1))
    }

    func name(for source: UUID?) -> String {
        guard let source, let waveform = waveform(id: source) else {
            return controller.configuration.function.shortTitle
        }
        return waveform.name
    }

    // MARK: - Simulator

    /// Starts the built-in SCPI simulator and returns the device path to connect
    /// to, so the whole application can be exercised without hardware.
    @discardableResult
    func startSimulator() -> String? {
        if let simulator { return simulator.devicePath }
        do {
            let meter = Simulated34401A()
            meter.lineFrequency = controller.lineFrequency
            let server = try SimulatorServer(meter: meter)
            server.start()
            simulator = server
            return server.devicePath
        } catch {
            controller.append("Simulator failed: \(error.localizedDescription)")
            return nil
        }
    }

    func stopSimulator() {
        simulator?.stop()
        simulator = nil
    }
}
