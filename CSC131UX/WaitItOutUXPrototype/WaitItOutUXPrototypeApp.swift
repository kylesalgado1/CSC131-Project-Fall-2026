import SwiftUI
import WaitItOutUX

/// Thin app host. It owns the process entry point; the single shared feature model comes from
/// `AppComposition`, and every screen, model, and service lives in the WaitItOutUX package.
/// The `AppDelegate` receives the push token and notification responses and forwards them to
/// the same model.
@main
@MainActor
struct WaitItOutUXPrototypeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppComposition.shared.model

    var body: some Scene {
        WindowGroup {
            WaitItOutRootView(model: model)
        }
    }
}
