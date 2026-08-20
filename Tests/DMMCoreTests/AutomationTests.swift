import XCTest
import AppIntents
@testable import DMMCore
@testable import AgilentDMMKit

/// The three ways the app reaches out of its own window: a banner, the menu bar
/// and Shortcuts.
@MainActor
final class AutomationTests: XCTestCase {

    // MARK: - Banners

    /// Builds a centre that never touches the real notification centre.
    private func makeCentre(appIsActive: Bool = false) -> (AlertCentre, () -> [MeterAlert]) {
        var delivered: [MeterAlert] = []
        let centre = AlertCentre(deliver: { delivered.append($0) },
                                 requestPermission: { $0(.granted) },
                                 appIsActive: { appIsActive })
        return (centre, { delivered })
    }

    func testNothingIsDeliveredUntilSomebodyAsksForIt() {
        let (centre, delivered) = makeCentre()
        XCTAssertFalse(centre.isEnabled, "an app that demands permission on first launch has not earned it")
        XCTAssertFalse(centre.wantsAlert(of: .limit))

        centre.isEnabled = true
        XCTAssertTrue(centre.wantsAlert(of: .limit))
        XCTAssertEqual(centre.authorization, .granted, "turning it on is what asks")

        centre.present(MeterAlert(kind: .limit, title: "Limit tripped", body: "4.31 V is above 4.30 V"))
        XCTAssertEqual(delivered().count, 1)
        XCTAssertEqual(centre.lastPosted?.kind, .limit)
    }

    func testEachKindCanBeTurnedOffOnItsOwn() {
        let (centre, _) = makeCentre()
        centre.isEnabled = true
        centre.kinds = [.connectionLost]

        XCTAssertTrue(centre.wantsAlert(of: .connectionLost))
        XCTAssertFalse(centre.wantsAlert(of: .limit))
        XCTAssertFalse(centre.wantsAlert(of: .overload))
    }

    func testABannerOverTheWindowThatAlreadySaysItIsSuppressed() {
        let (foreground, _) = makeCentre(appIsActive: true)
        foreground.isEnabled = true
        XCTAssertFalse(foreground.wantsAlert(of: .limit), "the big green number is right there")

        foreground.onlyWhenInBackground = false
        XCTAssertTrue(foreground.wantsAlert(of: .limit), "unless it was asked for anyway")
    }

    func testTheBannerHistoryIsBounded() {
        let (centre, _) = makeCentre()
        centre.isEnabled = true
        for index in 0..<40 {
            centre.present(MeterAlert(kind: .overload, title: "Overload", body: "\(index)"))
        }
        XCTAssertEqual(centre.posted.count, 20)
        XCTAssertEqual(centre.lastPosted?.body, "39")
    }

    func testAlertSettingsSurviveARestart() {
        let store = PreferenceStore.ephemeral()

        let first = AppModel(store: store)
        first.alerts.kinds = [.overload]
        first.alerts.onlyWhenInBackground = false
        first.showsMenuBarReading = false
        first.saveNow()

        let second = AppModel(store: store)
        XCTAssertEqual(second.alerts.kinds, [.overload])
        XCTAssertFalse(second.alerts.onlyWhenInBackground)
        XCTAssertFalse(second.showsMenuBarReading)
        XCTAssertFalse(second.alerts.isEnabled, "and permission is not re-requested for a switch that was off")
    }

    // MARK: - Menu bar

    func testTheMenuBarSaysNothingRatherThanZeroWhenThereIsNoMeter() {
        let controller = DMMController()
        let readout = MenuBarReadout(controller: controller)
        readout.sample()

        XCTAssertFalse(readout.isConnected)
        XCTAssertEqual(readout.title, "—")
        XCTAssertEqual(MenuBarReadout.compactReading(of: controller), "—")
    }

    func testTheMenuBarItemAlwaysHasSomethingToShow() {
        // The item is drawn from `title` alone, so an empty one would leave a
        // bare icon in the bar with nothing to say whose it is.
        let controller = DMMController()
        let readout = MenuBarReadout(controller: controller)
        for _ in 0..<3 {
            readout.sample()
            XCTAssertFalse(readout.title.isEmpty)
        }
    }

    func testTheMenuBarUpdatesSlowlyEnoughToBeRead() {
        // Twenty readings a second is a number nobody can read and a menu bar
        // that redraws twenty times a second. Two a second is the compromise.
        XCTAssertGreaterThanOrEqual(MenuBarReadout.updateInterval, 0.25)
        XCTAssertLessThanOrEqual(MenuBarReadout.updateInterval, 1.0)
    }

    // MARK: - Shortcuts vocabulary

    /// The one place the intent vocabulary and the instrument have to agree.
    /// App Intents will not take an enum from another module, so the functions
    /// are spelled out twice; this is what stops the second list rotting.
    func testEveryMeasurementFunctionHasAShortcutsName() {
        XCTAssertEqual(FunctionChoice.allCases.count, MeasurementFunction.allCases.count)

        for function in MeasurementFunction.allCases {
            let choice = FunctionChoice(function)
            XCTAssertEqual(choice.function, function, "\(function) does not survive the round trip")
            XCTAssertEqual(choice.rawValue, function.rawValue, "the two spellings have drifted apart")

            let representation = FunctionChoice.caseDisplayRepresentations[choice]
            XCTAssertNotNil(representation, "\(function) has no name for Shortcuts to show")
        }
    }

    func testEveryStatisticShortcutsOffersCanBeAnswered() {
        var statistics = Statistics()
        XCTAssertTrue(statistics.isEmpty)
        for choice in StatisticChoice.allCases where choice != .count {
            // Nothing measured yet is nil, not NaN dressed up as an answer.
            XCTAssertNil(choice.value(from: statistics), "\(choice) invented a value")
            XCTAssertNotNil(StatisticChoice.caseDisplayRepresentations[choice])
        }
        // Except the count, which has a true answer before the first reading.
        XCTAssertEqual(StatisticChoice.count.value(from: statistics), 0)

        statistics = Statistics(count: 3, minimum: 1, maximum: 3, mean: 2, standardDeviation: 1)
        XCTAssertEqual(StatisticChoice.mean.value(from: statistics), 2)
        XCTAssertEqual(StatisticChoice.peakToPeak.value(from: statistics), 2)
        XCTAssertEqual(StatisticChoice.count.value(from: statistics), 3)
    }

    func testAnIntentWithNoApplicationBehindItSaysSo() async {
        let previous = AppModel.current
        AppModel.current = nil
        defer { AppModel.current = previous }

        do {
            _ = try await TakeReadingIntent().perform()
            XCTFail("an intent cannot read a meter that nothing is holding open")
        } catch let error as IntentError {
            XCTAssertEqual(error, .notRunning)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnIntentWithNoMeterConnectedSaysThatInstead() async {
        let previous = AppModel.current
        AppModel.current = AppModel(store: .ephemeral())
        defer { AppModel.current = previous }

        do {
            _ = try await SelectFunctionIntent().perform()
            XCTFail("there is no meter to switch")
        } catch let error as IntentError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
