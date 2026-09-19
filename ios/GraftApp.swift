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

/// Everything a tab can push.
///
/// Navigation used to be `NavigationLink(destination:)`, which pushes a view
/// the stack has no name for — so nothing could ask a stack to go back to its
/// root, which is precisely what tapping the tab you are already on should do.
/// Routes are values now, the stack holds a path of them, and "go home" is one
/// line.
///
/// The issue cases carry the record rather than its id, because two of the
/// places that push one — the replacement the server spawns when a recurring
/// issue is completed, and an archived occurrence in a series — are rows the
/// local cache may not hold. `GraftIssue` hashes on `id` alone (see
/// `GraftModels`), so a route stays itself while the row is edited under it.
enum GraftRoute: Hashable {
    case project(String)
    case issue(GraftIssue)
    case series(GraftIssue)
}

@MainActor
@Observable
final class GraftRouter {
    var tab: GraftTab = .inbox

    /// One path per tab, held here rather than in each screen so the tab bar
    /// can reach them. They are separate on purpose: each tab keeps its own
    /// history, which is the whole reason `RootView` stacks a `TabView` rather
    /// than switching on an `if`.
    var inboxPath = NavigationPath()
    var projectsPath = NavigationPath()
    var settingsPath = NavigationPath()

    func path(for tab: GraftTab) -> NavigationPath {
        switch tab {
        case .inbox: return inboxPath
        case .projects: return projectsPath
        case .settings: return settingsPath
        }
    }

    func setPath(_ path: NavigationPath, for tab: GraftTab) {
        switch tab {
        case .inbox: inboxPath = path
        case .projects: projectsPath = path
        case .settings: settingsPath = path
        }
    }

    func binding(for tab: GraftTab) -> Binding<NavigationPath> {
        Binding(get: { self.path(for: tab) }, set: { self.setPath($0, for: tab) })
    }

    /// Back to the top of a tab. Tapping the tab you are already on does this —
    /// the platform convention, and the one thing the app's own tab bar was
    /// missing: it guarded on `!selected` and a second tap did nothing at all,
    /// so getting out of a project meant walking back up by hand.
    ///
    /// Returns whether it changed anything, so the caller can tell "went home"
    /// from "was already home" and skip the haptic for the second.
    @discardableResult
    func popToRoot(_ tab: GraftTab) -> Bool {
        var path = self.path(for: tab)
        guard !path.isEmpty else { return false }
        path.removeLast(path.count)
        setPath(path, for: tab)
        return true
    }
}

/// Every destination a tab can push, registered once per stack.
///
/// A `navigationDestination` is looked up on the stack the link lives in, so
/// each of the three tabs needs its own copy — and since all three can push an
/// issue (the Inbox straight to one, Projects by way of a project), it is one
/// modifier rather than three lists.
struct GraftRoutes: ViewModifier {
    @Environment(GraftStore.self) private var store

    func body(content: Content) -> some View {
        content.navigationDestination(for: GraftRoute.self) { route in
            switch route {
            case .project(let id):
                // By id, resolved here: a project route outlives any particular
                // copy of the row, so renaming a project while its screen is
                // open does not break the way back to it.
                if let project = store.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                } else {
                    GraftEmptyState(
                        title: "Project gone",
                        subtitle: "It was deleted, here or on another device.",
                        systemImage: "questionmark.folder"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gBg.ignoresSafeArea())
                }
            case .issue(let issue):
                IssueDetailView(issue: issue)
            case .series(let issue):
                IssueSeriesView(issue: issue)
            }
        }
    }
}

extension View {
    /// Registers `GraftRoute` on this navigation stack. Applied to the root
    /// content of each tab's stack, once.
    func graftRoutes() -> some View { modifier(GraftRoutes()) }
}

/// Put the keyboard away, from anywhere.
///
/// There is no SwiftUI-native way to do this without owning the `FocusState`
/// the field is bound to, and the fields in question are scattered across
/// half a dozen screens — a search box here, a title field there. Sending the
/// action to `nil` hands it to whoever is first responder, which is exactly
/// the question being asked.
@MainActor
func graftDismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
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

            GraftTabBar(selection: $router.tab,
                        pendingCount: store.pendingBadgeCount,
                        onReselect: { tab in
                            // Tapping the tab you are on: put the keyboard away
                            // and unwind to the top of that section. Both, in
                            // that order — if a search field has focus the
                            // keyboard is what is in the way, and popping the
                            // stack out from under a focused field without
                            // dismissing it leaves the keyboard up over a
                            // screen that has nothing for it to type into.
                            graftDismissKeyboard()
                            router.popToRoot(tab)
                        })
        }
        .background(Color.gBg)
    }
}
