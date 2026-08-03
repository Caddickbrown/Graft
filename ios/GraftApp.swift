import SwiftUI

@main
struct GraftApp: App {
    @State private var store = GraftStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ProjectsView()
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
