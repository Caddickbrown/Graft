import SwiftUI

@main
struct GraftApp: App {
    @State private var store = GraftStore()

    var body: some Scene {
        WindowGroup {
            ProjectsView()
                .environment(store)
                .task {
                    await store.sync()
                }
        }
    }
}
