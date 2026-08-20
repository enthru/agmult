import Foundation

/// Something the meter did that is worth interrupting somebody for.
///
/// The event list already records everything; this is the much shorter list of
/// things worth saying out loud to a person who is not looking at the window.
/// A long capture is exactly the situation where nobody is: the whole point of
/// leaving a meter logging overnight is not to sit with it.
public struct MeterAlert: Equatable, Sendable {

    public enum Kind: String, CaseIterable, Sendable, Codable {
        /// A limit test tripped — the reading left the band it was told to stay in.
        case limit
        /// The input went past full scale on the range in force.
        case overload
        /// The meter stopped answering, or the port went away under it.
        case connectionLost

        public var title: String {
            switch self {
            case .limit: return "Limit tripped"
            case .overload: return "Overload"
            case .connectionLost: return "Connection lost"
            }
        }

        /// What the Settings checkbox says, and why anyone would want it.
        public var explanation: String {
            switch self {
            case .limit: return "The reading left the band set in Math ▸ Limit test"
            case .overload: return "The input went past full scale on the range in use"
            case .connectionLost: return "The meter stopped answering, ending the session"
            }
        }
    }

    public let kind: Kind
    public let title: String
    public let body: String

    public init(kind: Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Whoever turns an alert into something a person notices.
///
/// The controller does not know what that is. On the Mac it is a notification
/// banner, which needs a bundle to exist and permission to have been granted,
/// and neither is true in a test process — hence a protocol rather than a call
/// straight into `UNUserNotificationCenter`.
@MainActor
public protocol AlertPresenter: AnyObject {
    /// Which kinds the presenter wants at all. Asked before each alert is built,
    /// so switching a kind off in Settings takes effect immediately.
    func wantsAlert(of kind: MeterAlert.Kind) -> Bool
    func present(_ alert: MeterAlert)
}
