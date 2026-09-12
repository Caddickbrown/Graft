import SwiftUI

@main
struct GraftApp: App {
    @State private var store = GraftStore()
    @State private var router = GraftRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .task {
                    // On first launch: try to sync if a server is configured,
                    // otherwise just load from local cache (already done in init)
                    await store.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // App foregrounded — flush any queued mutations
                        Task { await store.flushPending() }
                    }
                }
        }
    }
}

/// Which tab is showing.
///
/// A top-level enum rather than a nested one because screens deep inside a tab
/// need to name it: the "no server linked" state's only useful action is to open
/// Settings, and a pushed view has no other way to get there.
enum GraftTab: Hashable { case inbox, projects, settings }

@MainActor
@Observable
final class GraftRouter {
    var tab: GraftTab = .inbox
}

/// Three top-level destinations. Settings used to be a gear in the corner of
/// one screen, and there was no way at all to see work across projects.
struct RootView: View {
    @Environment(GraftStore.self) private var store
    @Environment(GraftRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.tab) {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(GraftTab.inbox)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(GraftTab.projects)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(GraftTab.settings)
                // Writes waiting to reach the server, on the tab that can
                // explain them. Zero draws nothing.
                .badge(store.pendingBadgeCount)
        }
        .tint(Color.gAccent)
    }
}
