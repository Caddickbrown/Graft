import SwiftUI

@main
struct GraftApp: App {
    @State private var store = GraftStore()
    @State private var router = GraftRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // `App.init` is nonisolated but does run on the main thread, and the
        // appearance proxies are main-actor isolated.
        MainActor.assumeIsolated { GraftChrome.apply() }
    }

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

// MARK: - UIKit chrome
//
// The navigation and tab bars are UIKit underneath, so SwiftUI's `.font()`
// never reaches their labels: a screen title stayed in SF while everything
// below it had moved to Geist, which is most of what made the app read as a
// stock SwiftUI shell with a custom body.
//
// Set on the appearance proxy at launch, before any bar is created.

@MainActor
enum GraftChrome {
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Color.gBg)
        nav.shadowColor = .clear   // the design carries its own hairlines
        // Bricolage for the large title — it has the personality at 34pt.
        // Inline titles are small enough that Geist reads cleaner.
        if let large = UIFont(name: "BricolageGrotesque-Bold", size: 34) {
            nav.largeTitleTextAttributes = [.font: large, .foregroundColor: UIColor(Color.gInk)]
        }
        if let inline = UIFont(name: "Geist-SemiBold", size: 17) {
            nav.titleTextAttributes = [.font: inline, .foregroundColor: UIColor(Color.gInk)]
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        // Bar button items — "Cancel" / "Save" on every sheet.
        if let button = UIFont(name: "Geist-Medium", size: 17) {
            UIBarButtonItem.appearance().setTitleTextAttributes([.font: button], for: .normal)
        }

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Color.gSidebar)
        if let item = UIFont(name: "Geist-Medium", size: 10) {
            for layout in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
                layout.normal.titleTextAttributes = [.font: item]
                layout.selected.titleTextAttributes = [.font: item]
            }
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
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
