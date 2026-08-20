import Foundation
import DMMCore

/// Everything the application remembers between launches.
///
/// Decoding is deliberately forgiving. A preferences file written by an older
/// build is missing whatever has been added since, and the honest behaviour is
/// to keep what is there and default the rest — not to throw the lot away
/// because one key is new. Scalars fall back individually; a group whose shape
/// has changed falls back as a group, which is the one place a future field can
/// still cost the user a setting.
struct Preferences: Codable, Equatable {

    struct Graph: Codable, Equatable {
        var curveColor: PanelColor = .cyan
        var plotBackground: PanelColor = .white
        var figureBackground: PanelColor = .white
        var theme: GraphTheme = .standard
        var autoAxis = true
        var manualMinimum: Double = 0
        var manualMaximum: Double = 1
        var showPoints = false
        var showMean = true
        var showExtremes = true
        var showLimits = false
        var xAxis: GraphXAxis = .sampleNumber
    }

    struct Histogram: Codable, Equatable {
        var binCount = 64
        var barColor: PanelColor = .violet
        var plotBackground: PanelColor = .white
        var showNormalMarkers = true
        var source: UUID?
    }

    struct Waveform: Codable, Equatable {
        var id = UUID()
        var name = "Math"
        var recipe = WaveformRecipe()
        var source: UUID?
        var graph = Graph()
    }

    /// Notification banners. Off until asked for: an application that demands
    /// permission to interrupt you on first launch, before it has measured
    /// anything, has not earned it.
    struct Alerts: Codable, Equatable {
        var isEnabled = false
        var kinds: Set<MeterAlert.Kind> = [.limit, .connectionLost]
        /// Only when the app is not the one you are looking at. A banner over
        /// the window whose big green number already says the same thing is
        /// noise, not news.
        var onlyWhenInBackground = true
    }

    struct Speech: Codable, Equatable {
        var isEnabled = false
        var speaksPeriodically = true
        var interval: TimeInterval = 10
        var rate: Float = 0.5
        var upperThreshold: Double?
        var lowerThreshold: Double?
    }

    var version = 1

    var panelTextColor: PanelColor = .green
    var panelBackground: PanelColor = .black
    var drawsEveryPoint = false

    var graph = Graph()
    var histogram = Histogram()
    var waveforms: [Waveform] = []
    var stabilitySource: UUID?

    var meter = MeterConfiguration()
    var math = MathConfiguration()
    var pollPlan = DMMPollPlan()
    var updateInterval: TimeInterval = 0
    var lineFrequency: Double = 50
    var usesCompoundQueries = true

    var historyCapacity = 100_000
    var tableCapacity = 2_000
    var autoScroll = true
    var updateList = true
    var addReadingsToList = false
    var beeperEnabled = true

    var logReadingsText = false
    var logReadingsCSV = false
    var logStatusText = false
    var logDirectoryPath: String?

    var speech = Speech()
    var alerts = Alerts()
    /// The reading in the menu bar, for glancing at from another application.
    var showsMenuBarReading = true
    /// The port that worked last time, so reconnecting is one click.
    var lastConnection: SerialConfig?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()

        // `try?` of an optional decode gives a double optional: the outer nil
        // means the value was there but the wrong shape, the inner that the key
        // was absent. Both mean "use the default".
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func optional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }

        version = value(.version, defaults.version)
        panelTextColor = value(.panelTextColor, defaults.panelTextColor)
        panelBackground = value(.panelBackground, defaults.panelBackground)
        drawsEveryPoint = value(.drawsEveryPoint, defaults.drawsEveryPoint)

        graph = value(.graph, defaults.graph)
        histogram = value(.histogram, defaults.histogram)
        waveforms = value(.waveforms, defaults.waveforms)
        stabilitySource = optional(.stabilitySource, UUID.self)

        meter = value(.meter, defaults.meter)
        math = value(.math, defaults.math)
        pollPlan = value(.pollPlan, defaults.pollPlan)
        updateInterval = value(.updateInterval, defaults.updateInterval)
        lineFrequency = value(.lineFrequency, defaults.lineFrequency)
        usesCompoundQueries = value(.usesCompoundQueries, defaults.usesCompoundQueries)

        historyCapacity = value(.historyCapacity, defaults.historyCapacity)
        tableCapacity = value(.tableCapacity, defaults.tableCapacity)
        autoScroll = value(.autoScroll, defaults.autoScroll)
        updateList = value(.updateList, defaults.updateList)
        addReadingsToList = value(.addReadingsToList, defaults.addReadingsToList)
        beeperEnabled = value(.beeperEnabled, defaults.beeperEnabled)

        logReadingsText = value(.logReadingsText, defaults.logReadingsText)
        logReadingsCSV = value(.logReadingsCSV, defaults.logReadingsCSV)
        logStatusText = value(.logStatusText, defaults.logStatusText)
        logDirectoryPath = optional(.logDirectoryPath, String.self)

        speech = value(.speech, defaults.speech)
        alerts = value(.alerts, defaults.alerts)
        showsMenuBarReading = value(.showsMenuBarReading, defaults.showsMenuBarReading)
        lastConnection = optional(.lastConnection, SerialConfig.self)
    }
}

/// Where preferences live. Backed by `UserDefaults` in the application and by
/// memory in tests, so a test run never touches the user's real settings.
@MainActor
final class PreferenceStore {
    static let key = "com.agmult.preferences"

    static let standard = PreferenceStore(defaults: .standard)
    static func ephemeral() -> PreferenceStore { PreferenceStore(defaults: nil) }

    private let defaults: UserDefaults?
    private var memory: Data?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() -> Preferences? {
        guard let data = defaults?.data(forKey: Self.key) ?? memory else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        if let defaults {
            defaults.set(data, forKey: Self.key)
        } else {
            memory = data
        }
    }

    func clear() {
        defaults?.removeObject(forKey: Self.key)
        memory = nil
    }
}

extension PanelColor: Codable {}
extension GraphTheme: Codable {}
extension GraphXAxis: Codable {}
