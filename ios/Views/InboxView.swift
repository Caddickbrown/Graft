import SwiftUI

/// What needs you, across every project.
///
/// The app previously opened on the project list, so the one question a phone
/// is good for — what is blocked right now — could not be asked at all. The
/// web client has had a cross-project list since the start.
///
/// The screen's worst failure was structural: it split issues into "Needs you"
/// (urgent/high, or a milestone within two days) and "In progress", and a
/// perfectly ordinary backlog — open issues, none urgent, nothing started —
/// matched neither. Both sections rendered as nothing, the generic empty state
/// was skipped because issues plainly existed, and the user got a segmented
/// control, a floating + and a blank screen under a nav bar reading "0 needs
/// you · 14 open across 3 projects". The fix is a third section that catches
/// everything the other two miss, plus per-section empty copy so a section that
/// is legitimately empty says so.
struct InboxView: View {
    @Environment(GraftStore.self) private var store
    @Environment(GraftRouter.self) private var router

    @State private var showNewIssue = false
    @State private var showFilters = false
    @State private var undo: UndoAction?

    // MARK: - Data

    /// Everything the Inbox could show, before the query narrows it. Kept apart
    /// from `visible` so "there is nothing" and "nothing matches" can be told
    /// apart — the difference between "Tap + to plant your first issue" and a
    /// filter that is quietly hiding 41 of them.
    private var candidates: [GraftIssue] {
        store.inbox()
    }

    private var query: IssueQuery { store.inboxQuery }

    private var visible: [GraftIssue] {
        store.apply(query, to: candidates)
    }

    /// Urgent, high, or inside two days of its deadline.
    ///
    /// "Its deadline" used to mean its milestone's, because that was the only
    /// date in the data. An issue can now carry its own, which is the more
    /// specific claim and wins; the milestone stays as the fallback, so nothing
    /// that was flagged before this existed quietly stopped being flagged.
    private var needsYou: [GraftIssue] {
        visible.filter { issue in
            if issue.priority == "urgent" || issue.priority == "high" { return true }
            if let days = GraftDate.daysUntil(store.dueDate(for: issue)) {
                return days <= 2
            }
            return false
        }
    }

    private var moving: [GraftIssue] {
        let flagged = Set(needsYou.map(\.id))
        return visible.filter { $0.status == "in-progress" && !flagged.contains($0.id) }
    }

    /// The catch-all. Anything the two sections above did not claim lands here,
    /// which is what stops the screen ever being blank while issues exist.
    private var backlog: [GraftIssue] {
        let claimed = Set(needsYou.map(\.id)).union(moving.map(\.id))
        return visible.filter { !claimed.contains($0.id) }
    }

    private var summary: String {
        let open = visible.count
        let projects = Set(visible.map(\.projectId)).count
        // Overdue and due-today earn a place in the one line this screen always
        // shows — but only when there are any. A permanent "0 overdue" is how a
        // number stops being read. Same rule as the web client's Today page.
        var bits: [String] = []
        let overdue = store.overdueCount(in: visible)
        let dueToday = store.dueTodayCount(in: visible)
        if overdue > 0 { bits.append("\(overdue) overdue") }
        if dueToday > 0 { bits.append("\(dueToday) due today") }
        bits.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you")
        bits.append("\(open) open across \(projects) project\(projects == 1 ? "" : "s")")
        if query.isNarrowing { bits.append("filtered from \(candidates.count)") }
        return bits.joined(separator: " · ")
    }

    // MARK: - Body

    /// The Inbox's own filter/sort state, read from the store and written back
    /// through it so every change is saved. `$store.inboxQuery` looked like it
    /// did the same and did not — writing through it mutates the query *inside*
    /// the property, which is not a change the store can see coming.
    private var queryBinding: Binding<IssueQuery> {
        Binding(get: { store.inboxQuery }, set: { store.setInboxQuery($0) })
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { store.inboxQuery.q },
            set: { newValue in
                var next = store.inboxQuery
                next.q = newValue
                store.setInboxQuery(next)
            }
        )
    }

    var body: some View {
        NavigationStack(path: router.binding(for: .inbox)) {
            ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // The header, the filter row and the search field are all
                // ordinary content now — see `Chrome.swift`. The navigation bar
                // is hidden outright rather than restyled, because from iOS 26
                // its items come wrapped in glass capsules we cannot reach.
                GraftScreenHeader(title: "Inbox", subtitle: summary) {
                    if store.isLoading {
                        ProgressView()
                            .tint(Color.gAccent)
                            .frame(width: GraftMetrics.tap, height: GraftMetrics.tap)
                    } else {
                        GraftIconButton(systemImage: "arrow.clockwise",
                                        accessibilityTitle: "Refresh") {
                            Task { await store.sync() }
                        }
                    }
                }

                HStack(spacing: GraftMetrics.spaceXS) {
                    // Reaches the server's `q` on submit; the list itself
                    // filters locally on every keystroke so it still works
                    // with no server.
                    GraftSearchField(placeholder: "Search issues",
                                     text: searchBinding) {
                        let snapshot = store.inboxQuery
                        Task { await store.refreshIssues(matching: snapshot) }
                    }
                    FilterButton(query: query) { showFilters = true }
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.spaceS)

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GraftFAB(label: "New issue") { showNewIssue = true }
            }
            // `.background` rather than a `Color` inside the stack: a child
            // that ignores the safe area drags the stack's own bounds down
            // with it, which is what used to push the + button under the bar.
            .background(Color.gBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .graftRoutes()
            .sheet(isPresented: $showFilters) {
                FilterSortSheet(query: queryBinding)
            }
            .sheet(isPresented: $showNewIssue) {
                // The Inbox spans every project, so there is no right project to
                // assume — this used to hard-code the first one and file
                // everything there. NewIssueView picks up the suggestion, offers
                // a picker, and handles having no projects at all.
                NewIssueView(projectId: store.projects.first(where: { !$0.archived })?.id ?? "")
            }
            .undoBanner($undo)
        }
    }

    // MARK: - The five states

    @ViewBuilder
    private var content: some View {
        if store.isFirstRun {
            // Not dressed up as a healthy empty state: a new install has no
            // idea Settings exists, let alone that a server can be linked.
            GraftNoServerState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if store.issues.isEmpty && store.isLoading {
            ScrollView {
                VStack(spacing: 0) {
                    SyncStrip().padding(.bottom, GraftMetrics.spaceXS)
                    GraftSkeletonList()
                }
            }

        } else if store.issues.isEmpty, let error = store.errorMessage {
            GraftErrorState(message: error) {
                Task { await store.sync() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if candidates.isEmpty {
            VStack(spacing: 0) {
                SyncStrip()
                Spacer(minLength: 0)
                GraftEmptyState(
                    title: "Nothing waiting",
                    subtitle: store.projects.isEmpty
                        ? "No projects yet. Start one and its work shows up here."
                        : "No open issues anywhere. Enjoy it.",
                    systemImage: "tray"
                )
                Spacer(minLength: 0)
            }
            .padding(.top, GraftMetrics.spaceXS)

        } else if visible.isEmpty {
            VStack(spacing: 0) {
                SyncStrip()
                Spacer(minLength: 0)
                GraftNoResults(
                    searchText: query.q,
                    activeFilters: query.badgeCount,
                    clearTitle: "Clear filters"
                ) {
                    var next = store.inboxQuery
                    next.reset()
                    store.setInboxQuery(next)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, GraftMetrics.spaceXS)

        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SyncStrip()
                    .padding(.bottom, GraftMetrics.spaceXS)

                if query.group == .none {
                    section("Needs you", needsYou,
                            empty: "Nothing urgent, and no milestone inside two days.")
                    section("In progress", moving,
                            empty: "Nothing started yet. Move an issue to In progress when you pick it up.")
                    section("Backlog", backlog,
                            empty: "Everything open is already urgent or under way.")
                } else {
                    ForEach(store.groups(visible, by: query.group)) { group in
                        section(group.title, group.issues, empty: nil)
                    }
                }

                Color.clear.frame(height: 96)
            }
            .padding(.top, GraftMetrics.spaceXS)
        }
        .refreshable {
            // `sync()` records its own failure in `errorMessage`, which the
            // strip above renders — a pull that fails used to leave no trace
            // anywhere on this screen.
            await store.sync()
        }
    }

    // MARK: - One section

    @ViewBuilder
    private func section(_ title: String, _ issues: [GraftIssue], empty: String?) -> some View {
        if !issues.isEmpty || empty != nil {
            GraftSectionHeader(title: title, count: issues.isEmpty ? nil : issues.count)

            if issues.isEmpty, let empty {
                GraftSectionEmpty(text: empty)
            }

            ForEach(issues) { issue in
                NavigationLink(value: GraftRoute.issue(issue)) {
                    GraftIssueRow(issue: issue,
                                  project: store.project(issue.projectId),
                                  due: store.dueDate(for: issue))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.spaceXS)
                // A context menu, not .swipeActions: these rows live in a
                // LazyVStack, and swipe actions are only wired up for rows of a
                // List, so the swipe here did nothing at all.
                .contextMenu {
                    Button {
                        archive(issue)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
        }
    }

    private func archive(_ issue: GraftIssue) {
        Task {
            try? await store.archiveIssue(id: issue.id)
            undo = UndoAction(message: "Issue archived") {
                try? await store.archiveIssue(id: issue.id)
            }
        }
    }
}
