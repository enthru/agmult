import Foundation
import Observation
import UserNotifications
import DMMCore

#if canImport(AppKit)
import AppKit
#endif

/// Turns a `MeterAlert` into a Notification Centre banner.
///
/// Which kinds are wanted, and whether they are wanted at all, lives here rather
/// than in the controller: the controller's job is to notice that a limit
/// tripped, not to know whether anybody asked to hear about it.
@MainActor
@Observable
final class AlertCentre: AlertPresenter {

    /// The master switch. Turning it on is what asks the system for permission —
    /// never at launch, where the answer would be no on any reasonable day.
    var isEnabled = false {
        didSet {
            guard isEnabled, isEnabled != oldValue else { return }
            requestAuthorization()
        }
    }

    var kinds: Set<MeterAlert.Kind> = [.limit, .connectionLost]

    /// Suppress banners while the app is frontmost. The window already says it.
    var onlyWhenInBackground = true

    /// What the system said when it was asked. Shown in Settings, because
    /// "notifications are on" and "notifications will appear" are not the same
    /// sentence once somebody has said no in System Settings.
    private(set) var authorization: Authorization = .notAsked

    enum Authorization: Equatable {
        case notAsked
        case granted
        case denied
        /// No bundle, no notification centre — the app is running straight out
        /// of `.build`, or this is a test process.
        case unavailable(String)

        var explanation: String? {
            switch self {
            case .notAsked: return nil
            case .granted: return nil
            case .denied: return "macOS is refusing banners for this app. System Settings ▸ Notifications ▸ 34401A Multimeter."
            case .unavailable(let reason): return reason
            }
        }
    }

    /// The banners that were posted, newest last. Kept so a test can assert on
    /// them without a notification centre in sight, and so the Settings pane can
    /// show what the last one was.
    private(set) var posted: [MeterAlert] = []

    /// Where a banner actually goes. Injected so tests, which have no bundle to
    /// post from, never reach the real notification centre.
    private let deliver: (MeterAlert) -> Void
    private let requestPermission: (@escaping (Authorization) -> Void) -> Void
    private let appIsActive: () -> Bool

    init(deliver: ((MeterAlert) -> Void)? = nil,
         requestPermission: ((@escaping (Authorization) -> Void) -> Void)? = nil,
         appIsActive: (() -> Bool)? = nil) {
        self.deliver = deliver ?? AlertCentre.deliverThroughNotificationCentre
        self.requestPermission = requestPermission ?? AlertCentre.askNotificationCentre
        self.appIsActive = appIsActive ?? { NSApp?.isActive ?? false }
    }

    // MARK: - AlertPresenter

    func wantsAlert(of kind: MeterAlert.Kind) -> Bool {
        guard isEnabled, kinds.contains(kind) else { return false }
        if onlyWhenInBackground && appIsActive() { return false }
        return true
    }

    func present(_ alert: MeterAlert) {
        posted.append(alert)
        if posted.count > 20 { posted.removeFirst(posted.count - 20) }
        deliver(alert)
    }

    var lastPosted: MeterAlert? { posted.last }

    // MARK: - Permission

    func requestAuthorization() {
        requestPermission { [weak self] result in
            self?.authorization = result
        }
    }

    // MARK: - The real notification centre

    /// True when there is a bundle to post notifications from. Asking
    /// `UNUserNotificationCenter` for anything without one raises an exception
    /// that no `do/catch` can see, so the check has to happen first — and a test
    /// process is exactly the case that would hit it.
    private static var canPostNotifications: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return !identifier.hasPrefix("com.apple.dt.xctest")
    }

    private static func askNotificationCentre(_ completion: @escaping (Authorization) -> Void) {
        guard canPostNotifications else {
            return completion(.unavailable("Notifications need the assembled app bundle — build it with Scripts/make-app.sh rather than running the bare executable."))
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    completion(.unavailable(error.localizedDescription))
                } else {
                    completion(granted ? .granted : .denied)
                }
            }
        }
    }

    private static func deliverThroughNotificationCentre(_ alert: MeterAlert) {
        guard canPostNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // A limit trip and the overload that follows it are one event as far as
        // the person at the bench is concerned; the identifier per kind means
        // the second replaces the first rather than stacking up.
        let request = UNNotificationRequest(identifier: "agmult.\(alert.kind.rawValue)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
