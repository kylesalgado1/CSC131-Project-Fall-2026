import UIKit
import UserNotifications
import WaitItOutUX

/// Receives what only the application object is told: the push service's device token and the
/// user's responses to trip notifications. It forwards both to the shared model and session
/// in `AppComposition` and decides nothing itself; the payload's spelling and the meaning of
/// each response live in the package (`TripNotificationPayload`).
///
/// In the standalone demo composition there is no session, and this class then touches no
/// notification API at all.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard AppComposition.shared.session != nil else { return true }
        // The delegate is set before launch finishes so a notification that started the app
        // is delivered here. The model already exists (AppComposition), so nothing has to be
        // kept for later.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.tripCategory])
        return true
    }

    /// The category the backend puts on every trip notification, with its one action.
    /// "I've left" opens the app (`.foreground`): the app then tells the server and shows the
    /// outcome, instead of a request made in the background that could fail unseen.
    private static var tripCategory: UNNotificationCategory {
        let left = UNNotificationAction(
            identifier: TripNotificationPayload.leftActionIdentifier,
            title: TripNotificationPayload.leftActionTitle,
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: TripNotificationPayload.categoryIdentifier,
            actions: [left],
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: Push registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let composition = AppComposition.shared
        guard let session = composition.session else { return }
        Task { @MainActor in
            // The push service hands over the same token at every launch; only a change is
            // worth telling the server at once.
            if await session.updateDeviceToken(deviceToken) {
                composition.model.pushRegistrationDidChange()
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let composition = AppComposition.shared
        guard let session = composition.session else { return }
        let description = error.localizedDescription
        Task { @MainActor in
            if await session.registrationFailed(description) {
                composition.model.pushRegistrationDidChange()
            }
        }
    }

    // MARK: Notifications

    /// A trip notification that arrives while the app is open is still shown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// The user tapped a notification or chose "I've left". The stored settings and schedule
    /// are loaded first (a cold start joins the launch load), then the model opens the trip
    /// and, for "I've left", tells the server. The system is told the response was handled
    /// only after the outcome is recorded in the model's state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let tripResponse = TripNotificationPayload.response(
            userInfo: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier,
            openActionIdentifier: UNNotificationDefaultActionIdentifier
        )
        guard let tripResponse else {
            completionHandler()
            return
        }
        Task { @MainActor in
            let model = AppComposition.shared.model
            await model.prepareForNotificationResponse()
            await model.handleNotificationAction(
                tripID: tripResponse.tripID,
                action: tripResponse.action,
                arriveBy: tripResponse.arriveBy
            )
            completionHandler()
        }
    }
}
