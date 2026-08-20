import AppIntents
import Foundation
import DMMCore

/// Shortcuts and the automation tools that sit on top of App Intents.
///
/// The point is not to control the meter from an iPhone. It is that a bench
/// instrument becomes something a script can ask a question of: read a voltage
/// after each step of a soak test, log it into a spreadsheet, stop when it
/// drifts. The Windows original has nothing of the sort, and neither has the
/// meter — its own interface is this serial line and nothing else.
///
/// Every intent works on the running application: the serial port is open in
/// this process and cannot be shared. `openAppWhenRun` is therefore not
/// optional — an intent that arrived while the app was closed would otherwise
/// have nothing to talk to.

// MARK: - Reading

struct TakeReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Reading"
    static let description = IntentDescription(
        "Returns the multimeter's most recent reading, in the function's own unit.",
        categoryName: "Measurement"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        guard !controller.isOverloaded else {
            throw IntentError.overloaded
        }
        guard let value = controller.latestReading else {
            throw IntentError.noReadingYet
        }
        return .result(value: value, dialog: IntentDialog(stringLiteral: controller.formattedReading))
    }
}

struct ReadStatisticsIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Statistics"
    static let description = IntentDescription(
        "Returns the mean of everything captured in this session, with the spread as spoken detail.",
        categoryName: "Measurement"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Statistic", default: .mean)
    var statistic: StatisticChoice

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        let statistics = controller.statistics
        // "How many readings?" has an answer before the first one arrives, and
        // it is zero. The others genuinely do not.
        guard let value = statistic.value(from: statistics) else {
            throw IntentError.noReadingYet
        }
        let text = Format.engineering(value, unit: controller.displayUnit)
        return .result(value: value,
                       dialog: IntentDialog(stringLiteral: "\(statistic.title) of \(statistics.count) readings: \(text)"))
    }
}

enum StatisticChoice: String, AppEnum {
    case mean, minimum, maximum, standardDeviation, peakToPeak, count

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Statistic")

    static let caseDisplayRepresentations: [StatisticChoice: DisplayRepresentation] = [
        .mean: "Mean",
        .minimum: "Minimum",
        .maximum: "Maximum",
        .standardDeviation: "Standard Deviation",
        .peakToPeak: "Peak to Peak",
        .count: "Count",
    ]

    var title: String {
        switch self {
        case .mean: return "Mean"
        case .minimum: return "Minimum"
        case .maximum: return "Maximum"
        case .standardDeviation: return "Standard deviation"
        case .peakToPeak: return "Peak to peak"
        case .count: return "Count"
        }
    }

    /// The statistics carry NaN rather than nil for "nothing yet", which is
    /// right for arithmetic and wrong for an answer given to somebody.
    func value(from statistics: Statistics) -> Double? {
        let value: Double
        switch self {
        case .mean: value = statistics.mean
        case .minimum: value = statistics.minimum
        case .maximum: value = statistics.maximum
        case .standardDeviation: value = statistics.standardDeviation
        case .peakToPeak: value = statistics.peakToPeak
        case .count: value = Double(statistics.count)
        }
        return value.isFinite ? value : nil
    }
}

// MARK: - Control

struct SelectFunctionIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Measurement Function"
    static let description = IntentDescription(
        "Switches the meter to a measurement function — DC volts, resistance, the dc:dc ratio and the rest.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Function")
    var function: FunctionChoice

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        controller.setFunction(function.function)
        return .result(dialog: IntentDialog(stringLiteral: "Measuring \(function.function.title.lowercased())."))
    }
}

struct ResetHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset History and Statistics"
    static let description = IntentDescription(
        "Throws away the captured readings and starts the statistics again — what you want at the top of a run.",
        categoryName: "Control"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try IntentSupport.connectedController()
        controller.resetHistory()
        return .result(dialog: "History cleared.")
    }
}

/// The measurement functions as Shortcuts sees them.
///
/// A separate enum rather than `MeasurementFunction` itself, for two reasons
/// that point the same way. App Intents will not accept an enum that lives in
/// another module — DMMCore is where the SCPI layer lives, and it has no
/// business importing AppIntents — and the metadata is extracted at build time,
/// so the names have to be written out as literals here rather than derived
/// from `title` in a loop. The mapping below is the one place the two lists have
/// to agree, and the test that walks `allCases` is what keeps them agreeing.
enum FunctionChoice: String, AppEnum, CaseIterable {
    case dcVoltage, dcRatio, acVoltage, dcCurrent, acCurrent
    case resistance, resistance4Wire, frequency, period, continuity, diode

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Measurement Function")

    static let caseDisplayRepresentations: [FunctionChoice: DisplayRepresentation] = [
        .dcVoltage: "DC Voltage",
        .dcRatio: "DC Voltage Ratio",
        .acVoltage: "AC Voltage",
        .dcCurrent: "DC Current",
        .acCurrent: "AC Current",
        .resistance: "2-Wire Resistance",
        .resistance4Wire: "4-Wire Resistance",
        .frequency: "Frequency",
        .period: "Period",
        .continuity: "Continuity",
        .diode: "Diode Test",
    ]

    var function: MeasurementFunction {
        switch self {
        case .dcVoltage: return .dcVoltage
        case .dcRatio: return .dcRatio
        case .acVoltage: return .acVoltage
        case .dcCurrent: return .dcCurrent
        case .acCurrent: return .acCurrent
        case .resistance: return .resistance
        case .resistance4Wire: return .resistance4Wire
        case .frequency: return .frequency
        case .period: return .period
        case .continuity: return .continuity
        case .diode: return .diode
        }
    }

    init(_ function: MeasurementFunction) {
        switch function {
        case .dcVoltage: self = .dcVoltage
        case .dcRatio: self = .dcRatio
        case .acVoltage: self = .acVoltage
        case .dcCurrent: self = .dcCurrent
        case .acCurrent: self = .acCurrent
        case .resistance: self = .resistance
        case .resistance4Wire: self = .resistance4Wire
        case .frequency: self = .frequency
        case .period: self = .period
        case .continuity: self = .continuity
        case .diode: self = .diode
        }
    }
}

// MARK: - Spoken phrases

struct AgilentDMMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakeReadingIntent(),
            phrases: [
                "Take a reading with \(.applicationName)",
                "What does \(.applicationName) say",
            ],
            shortTitle: "Take a Reading",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: ReadStatisticsIntent(),
            phrases: ["Read \(.applicationName) statistics"],
            shortTitle: "Read Statistics",
            systemImageName: "function"
        )
        AppShortcut(
            intent: ResetHistoryIntent(),
            phrases: ["Reset \(.applicationName)"],
            shortTitle: "Reset History",
            systemImageName: "arrow.counterclockwise"
        )
    }
}

// MARK: - Shared plumbing

enum IntentSupport {
    /// The controller of the running application, or a refusal that says which
    /// of the two things is missing — the app or the meter.
    @MainActor
    static func connectedController() throws -> DMMController {
        guard let model = AppModel.current else { throw IntentError.notRunning }
        guard model.controller.isConnected else { throw IntentError.notConnected }
        return model.controller
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected
    case noReadingYet
    case overloaded

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning:
            return "The multimeter application is not running yet."
        case .notConnected:
            return "No meter is connected. Open the app and choose a serial port first."
        case .noReadingYet:
            return "The meter has not produced a reading yet."
        case .overloaded:
            return "The input is past full scale — there is no reading to give you."
        }
    }
}
