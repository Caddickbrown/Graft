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

    /// Urgent, high, or inside two days of its milestone.
    private var needsYou: [GraftIssue] {
        visible.filter { issue in
            if issue.priority == "urgent" || issue.priority == "high" { return true }
            if let days = GraftDate.daysUntil(store.milestone(issue.milestoneId)?.dueDate) {
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
        let base = "\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you · \(open) open across \(projects) project\(projects == 1 ? "" : "s")"
        guard query.isNarrowing else { return base }
        return base + " · filtered from \(candidates.count)"
    }

    // MARK: - Body

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.gBg.ignoresSafeArea()

                content

                GraftFAB(label: "New issue") { showNewIssue = true }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            // Reaches the server's `q` on submit; the list itself filters
            // locally on every keystroke so it still works with no server.
            .searchable(text: $store.inboxQuery.q, prompt: "Search issues")
            .onSubmit(of: .search) {
                let snapshot = store.inboxQuery
                Task { await store.refreshIssues(matching: snapshot) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    FilterButton(query: query) { showFilters = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView().tint(Color.gAccent)
                    } else {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSortSheet(query: $store.inboxQuery)
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
                    store.inboxQuery.reset()
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

                // The summary lives here, not in `.principal`. In the toolbar it
                // competed with the large title for the same row and truncated
                // to nothing on anything narrower than a Pro Max.
                GraftScreenSubtitle(text: summary)

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
                NavigationLink(destination: IssueDetailView(issue: issue)) {
                    GraftIssueRow(issue: issue,
                                  project: store.project(issue.projectId),
                                  due: GraftDate.dueLabel(store.milestone(issue.milestoneId)?.dueDate))
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
