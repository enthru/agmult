import XCTest
@testable import DMMCore
@testable import AgilentDMMKit

/// Settings survive a restart — and, more importantly, survive the *next*
/// version of the application reading a file the current one wrote.
@MainActor
final class PreferencesTests: XCTestCase {

    func testEverythingTheUserChangedComesBack() async throws {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        first.panelTextColor = .amberOrDefault
        first.panelBackground = .gray
        first.drawsEveryPoint = true
        first.graph.curveColor = .pink
        first.graph.xAxis = .time
        first.graph.showPoints = true
        first.graph.autoAxis = false
        first.graph.manualMinimum = -1.5
        first.histogram.binCount = 256
        first.controller.usesCompoundQueries = false
        first.controller.updateInterval = 0.25
        first.controller.lineFrequency = 60
        first.controller.historyCapacity = 500_000
        first.controller.tableCapacity = 10_000
        first.controller.logReadingsCSV = true
        first.controller.addReadingsToList = true
        first.controller.speech.isEnabled = true
        first.controller.speech.interval = 30
        first.controller.speech.upperThreshold = 4.5
        first.lastConnection = SerialConfig(path: "/dev/cu.usbserial-1410", baudRate: 4800, parity: .odd)
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.panelTextColor, first.panelTextColor)
        XCTAssertEqual(second.panelBackground, .gray)
        XCTAssertTrue(second.drawsEveryPoint)
        XCTAssertEqual(second.graph.curveColor, .pink)
        XCTAssertEqual(second.graph.xAxis, .time)
        XCTAssertTrue(second.graph.showPoints)
        XCTAssertFalse(second.graph.autoAxis)
        XCTAssertEqual(second.graph.manualMinimum, -1.5)
        XCTAssertEqual(second.histogram.binCount, 256)
        XCTAssertFalse(second.controller.usesCompoundQueries)
        XCTAssertEqual(second.controller.updateInterval, 0.25)
        XCTAssertEqual(second.controller.lineFrequency, 60)
        XCTAssertEqual(second.controller.historyCapacity, 500_000)
        XCTAssertEqual(second.controller.history.capacity, 500_000, "and reaches the buffer")
        XCTAssertEqual(second.controller.tableCapacity, 10_000)
        XCTAssertTrue(second.controller.logReadingsCSV)
        XCTAssertTrue(second.controller.addReadingsToList)
        XCTAssertTrue(second.controller.speech.isEnabled)
        XCTAssertEqual(second.controller.speech.interval, 30)
        XCTAssertEqual(second.controller.speech.upperThreshold, 4.5)
        XCTAssertEqual(second.lastConnection?.path, "/dev/cu.usbserial-1410")
        XCTAssertEqual(second.lastConnection?.baudRate, 4800)
        XCTAssertEqual(second.lastConnection?.parity, .odd)
    }

    func testTheMeterConfigurationComesBackWithoutBeingSentAnywhere() async throws {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        var configuration = MeterConfiguration()
        configuration.function = .resistance4Wire
        configuration.autoRange = false
        configuration.range = 1e5
        configuration.integrationTime = .slowest
        configuration.autoZero = .off
        configuration.sampleCount = 50
        configuration.triggerSource = .bus
        var math = MathConfiguration()
        math.function = .dBm
        math.dBmReference = 50
        first.controller.restore(configuration: configuration, math: math)
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.controller.configuration, configuration)
        XCTAssertEqual(second.controller.math, math)
        XCTAssertEqual(second.controller.displayUnit, "dBm")
    }

    /// A chain of math waveforms is only worth restoring if the identifiers
    /// survive, or every waveform comes back pointing at the measurement.
    func testWaveformChainsSurviveWithTheirSources() async throws {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        let base = first.addWaveform()
        base.name = "Smoothed"
        base.recipe = WaveformRecipe(operation: .movingAverage, parameterA: 32)
        let derived = first.addWaveform(source: base.id)
        derived.name = "Slope"
        derived.recipe = WaveformRecipe(operation: .derivative)
        derived.settings.curveColor = .yellow
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.waveforms.count, 2)
        let restoredBase = try XCTUnwrap(second.waveforms.first { $0.name == "Smoothed" })
        let restoredDerived = try XCTUnwrap(second.waveforms.first { $0.name == "Slope" })

        XCTAssertEqual(restoredBase.id, base.id)
        XCTAssertEqual(restoredDerived.source, restoredBase.id)
        XCTAssertEqual(restoredBase.recipe.operation, .movingAverage)
        XCTAssertEqual(restoredBase.recipe.parameterA, 32)
        XCTAssertEqual(restoredDerived.recipe.operation, .derivative)
        XCTAssertEqual(restoredDerived.settings.curveColor, .yellow)
        XCTAssertEqual(second.unit(for: restoredDerived.id), "V/s", "the chain still resolves")
    }

    /// A file written by an older build is missing whatever has been added
    /// since. Keeping what is there beats throwing the lot away.
    func testAFileMissingNewerKeysKeepsWhatItDoesHave() throws {
        let json = """
        {"version":1,"panelTextColor":"pink","lineFrequency":60}
        """
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.panelTextColor, .pink)
        XCTAssertEqual(preferences.lineFrequency, 60)
        XCTAssertEqual(preferences.historyCapacity, 100_000, "absent keys take their defaults")
        XCTAssertTrue(preferences.usesCompoundQueries)
        XCTAssertNil(preferences.lastConnection)
    }

    /// A key that is present but the wrong shape falls back rather than taking
    /// the whole file down with it.
    func testAMalformedGroupFallsBackToItsDefault() throws {
        let json = """
        {"panelBackground":"gray","graph":"this used to be an object","tableCapacity":4242}
        """
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))

        XCTAssertEqual(preferences.panelBackground, .gray)
        XCTAssertEqual(preferences.tableCapacity, 4242)
        XCTAssertEqual(preferences.graph.curveColor, Preferences.Graph().curveColor)
    }

    func testGarbageInTheStoreIsIgnoredRatherThanCrashing() {
        // A named suite so the test writes somewhere of its own, and removes it
        // again rather than leaving litter in the user's preferences.
        let suite = "agmult-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: PreferenceStore.key)

        let store = PreferenceStore(defaults: defaults)
        XCTAssertNil(store.load())

        let model = AppModel(store: store)
        XCTAssertEqual(model.panelTextColor, .green, "defaults, not a crash")
    }

    /// The observation-driven saver has to notice a change made anywhere, not
    /// only through the paths that happen to call `saveNow`.
    func testAChangeIsWrittenWithoutAnybodyAskingItTo() async throws {
        let store = PreferenceStore.ephemeral()
        let model = AppModel(store: store)

        model.controller.tableCapacity = 777
        // Writes are debounced; a slider drag should not mean sixty writes.
        XCTAssertNil(store.load(), "not written immediately")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(store.load()?.tableCapacity, 777)
    }

    /// Live measurement state changes many times a second and has no business
    /// waking the settings writer.
    func testReadingsDoNotTriggerSaves() async throws {
        let store = PreferenceStore.ephemeral()
        let model = AppModel(store: store)

        for index in 0..<500 {
            model.controller.history.append(value: Double(index), at: Date())
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(store.load(), "the history is not a setting")
    }

    func testCollectingAndApplyingAreSymmetric() {
        let model = AppModel(store: .ephemeral())
        let original = model.preferences

        model.apply(original)
        XCTAssertEqual(model.preferences, original)
    }
}

private extension PanelColor {
    /// The readout panel's default text colour, named once so the test does not
    /// have to be edited when the default is retuned.
    static let amberOrDefault = PanelColor.orange
}
