import SwiftUI

/// Public entry point of the feature package. The app host creates a `WaitItOutModel`
/// with its chosen dependencies and shows this view as the scene's root.
@MainActor
public struct WaitItOutRootView: View {
    private let model: WaitItOutModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: WaitItOutModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ForEach(PrototypeTab.displayOrder) { tab in
                screen(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
        .preferredColorScheme(model.preferences.appearance.colorScheme)
        .task {
            // Launch and relaunch: stored settings, then the stored schedule; loading the
            // schedule recalculates leave-home times and reconciles reminders. A notification
            // response that arrives during launch joins this load instead of starting another.
            await model.loadStoredState()
        }
        .onChange(of: scenePhase) { _, phase in
            // Foregrounding re-plans leave-home times and checks the reminder adapter again.
            if phase == .active {
                model.appDidBecomeActive()
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: PrototypeTab) -> some View {
        switch tab {
        case .map:
            MapScreen(model: model)
        case .calendar:
            CalendarScreen(model: model)
        case .settings:
            SettingsScreen(model: model)
        }
    }
}

#Preview("Root - Map") {
    WaitItOutRootView(model: .preview())
}

#Preview("Root - Calendar, dark") {
    WaitItOutRootView(model: .preview(initialTab: .calendar, preferences: UserPreferences(appearance: .dark)))
}

#Preview("Root - Calendar with sample schedule") {
    WaitItOutRootView(model: .preview(initialTab: .calendar, activities: WaitItOutModel.previewSampleActivities()))
}
