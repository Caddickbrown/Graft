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

    /// The theme the user picked, or `.system`. Read here so the whole window
    /// carries it — every colour in the app resolves through the trait
    /// collection, so this one modifier repaints all of it.
    @AppStorage(GraftTheme.storageKey) private var themeRaw = GraftTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .preferredColorScheme(GraftTheme(rawValue: themeRaw)?.colorScheme)
                .task {
                    // On first launch: try to sync if a server is configured,
                    // otherwise just load from local cache (already done in init)
                    await store.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // App foregrounded — flush any queued mutations, then
                        // rebuild the reminder set. Rebuilt here and on `sync`
                        // only: `flushPending` runs after every single write,
                        // and a full notification rebuild per keystroke-debounce
                        // would be two network calls for nothing.
                        Task {
                            await store.flushPending()
                            await store.rescheduleNotifications()
                        }
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
//
// Most of this is now belt and braces: the app draws its own header and tab bar
// (see `Chrome.swift`) and hides both system bars, because from iOS 26 their
// items arrive wrapped in floating glass capsules that no appearance proxy can
// reach. What is left here still matters for the bars we do not draw — the
// keyboard accessory row, and anything UIKit puts up on its own.

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

        // Still a `TabView`, with its bar hidden and ours stacked under it.
        // Switching on `router.tab` with an `if` would have been simpler and
        // wrong: the two tabs that are not showing would be torn down, taking
        // each one's navigation stack and scroll position with them.
        //
        // A `VStack` rather than `safeAreaInset`: the inset is honoured by the
        // TabView's own chrome but not passed down to the screen inside it, so
        // the + button on two of the three tabs sat half-under the bar. Stacked,
        // the TabView is simply given the height that is left.
        VStack(spacing: 0) {
            TabView(selection: $router.tab) {
                InboxView()
                    .tag(GraftTab.inbox)
                    .toolbar(.hidden, for: .tabBar)

                ProjectsView()
                    .tag(GraftTab.projects)
                    .toolbar(.hidden, for: .tabBar)

                SettingsView()
                    .tag(GraftTab.settings)
                    .toolbar(.hidden, for: .tabBar)
            }
            .tint(Color.gAccent)

            GraftTabBar(selection: $router.tab, pendingCount: store.pendingBadgeCount)
        }
        .background(Color.gBg)
    }
}
