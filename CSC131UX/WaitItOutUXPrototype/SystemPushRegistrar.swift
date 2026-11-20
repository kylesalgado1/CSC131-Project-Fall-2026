import UIKit
import UserNotifications
import WaitItOutUX

/// The host's `PushRegistering` adapter: the notification permission and the registration with
/// the push service, which the package never names. It only reads and asks; `BackendSession`
/// decides when (permission is requested only when the user turns leave-home reminders on in
/// Live mode or chooses Allow Notifications).
struct SystemPushRegistrar: PushRegistering {
    /// The push environment the server must use for this build's device tokens. It follows the
    /// signed `aps-environment` entitlement, not the build configuration: the one entitlements
    /// file says `development`, so both Debug and Release tokens belong to the sandbox. A
    /// distribution build needs the `production` entitlement and this value changed with it
    /// (`scripts/check_project_structure.py` compares the two).
    let apnsEnvironment = "sandbox"

    func authorizationStatus() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.permission(for: settings.authorizationStatus)
    }

    /// Shows the system prompt only while the user has not decided; afterwards it reports the
    /// decision without asking again.
    func requestPermission() async -> NotificationPermission {
        let current = await authorizationStatus()
        guard current == .notDetermined else { return current }
        // The alerts are visible banners with a sound; no badge is used. A failed request
        // leaves the permission as it was, which the status read below reports.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    @MainActor
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Provisional and ephemeral authorizations can show alerts, so they count as allowed.
    static func permission(for status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}
