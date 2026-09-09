import SwiftUI

@main
struct GraftApp: App {
    @State private var store = GraftStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
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

/// Three top-level destinations. Settings used to be a gear in the corner of
/// one screen, and there was no way at all to see work across projects.
struct RootView: View {
    @Environment(GraftStore.self) private var store
    @State private var selection: Tab = .inbox

    enum Tab: Hashable { case inbox, projects, settings }

    var body: some View {
        TabView(selection: $selection) {
            InboxView()
                .tabItem { Label("Inbox", systemImage: "tray") }
                .tag(Tab.inbox)

            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(Tab.projects)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Color.gAmber)
    }
}
