import Foundation

/// What the user did with one trip notification: the trip, the action, and the arrival time
/// the notification was about. The host hands these to
/// `WaitItOutModel.handleNotificationAction(tripID:action:arriveBy:)`.
public struct TripNotificationResponse: Equatable, Sendable {
    public let tripID: String
    public let action: NotificationAction
    public let arriveBy: Date?

    public init(tripID: String, action: NotificationAction, arriveBy: Date?) {
        self.tripID = tripID
        self.action = action
        self.arriveBy = arriveBy
    }
}

/// The parts of the backend's trip notification the host needs. The host owns the system
/// notification APIs; this type only knows the payload's spelling, so that spelling stays in
/// `Backend/` and the host never parses dates itself.
public enum TripNotificationPayload {
    /// The category the backend sets on every trip notification.
    public static let categoryIdentifier = "WAIT_IT_OUT_TRIP"
    /// The identifier of the category's one action.
    public static let leftActionIdentifier = "WAIT_IT_OUT_LEFT"
    /// The title of that action.
    public static let leftActionTitle = "I've left"

    /// The trip's id (`OccurrenceID.rawValue`), or `nil` when the payload has none.
    public static func tripID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let text = userInfo["tripId"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The arrival time the notification was about, or `nil` when the payload has none or it
    /// cannot be read. "I've left" is sent for exactly this time.
    public static func arriveBy(from userInfo: [AnyHashable: Any]) -> Date? {
        (userInfo["arriveBy"] as? String).flatMap(BackendDate.parse)
    }

    /// What the user did, from the response's action identifier: the "I've left" action, or
    /// opening the notification for anything else.
    public static func action(forIdentifier identifier: String) -> NotificationAction {
        identifier == leftActionIdentifier ? .left : .open
    }

    /// Reads the system's response to a notification. `openActionIdentifier` is the system's
    /// identifier for tapping the notification itself, which the host passes in because the
    /// package never names the notification APIs.
    ///
    /// `nil` means there is nothing to do: the notification is not about a trip (no trip id),
    /// or the response is neither opening it nor "I've left", such as a dismissal. A dismissed
    /// notification must never open the app's trip or end its monitoring.
    public static func response(
        userInfo: [AnyHashable: Any],
        actionIdentifier: String,
        openActionIdentifier: String
    ) -> TripNotificationResponse? {
        guard let tripID = tripID(from: userInfo) else { return nil }
        guard actionIdentifier == leftActionIdentifier || actionIdentifier == openActionIdentifier else { return nil }
        return TripNotificationResponse(
            tripID: tripID,
            action: action(forIdentifier: actionIdentifier),
            arriveBy: arriveBy(from: userInfo)
        )
    }
}
