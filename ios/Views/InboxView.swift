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
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showNewIssue = false
    @State private var showFilters = false
    @State private var undo: UndoAction?
    /// The row the hardware keyboard is on, by id. See `graftKeyList`.
    @State private var keySelection: String?
    @State private var searchFocus = 0
    /// Done issues are left out unless this is on. Remembered, like the
    /// Inbox's filters.
    @AppStorage("graft.inbox.showDone") private var showDone = false
    /// The issue open beside the list, when there is room for both.
    @State private var selectedIssue: GraftIssue?
    /// The list and the open issue sit side by side rather than one over the
    /// other. Set from the width the screen is given, below.
    @State private var splitActive = false

    /// The width this screen needs before an issue opens beside the list
    /// instead of over it: iPad landscape does, iPad portrait with the sidebar
    /// out doesn't.
    private static let splitMinWidth: CGFloat = 700
    private static let listWidth: CGFloat = 380

    // MARK: - Data

    /// Everything the Inbox could show, before the query narrows it. Kept apart
    /// from `visible` so "there is nothing" and "nothing matches" can be told
    /// apart — the difference between "Tap + to plant your first issue" and a
    /// filter that is quietly hiding 41 of them.
    private var candidates: [GraftIssue] {
        store.inbox(includeDone: showDone)
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
        open.filter { store.needsYou($0) }
    }

    /// What the sections and the counts are about: everything but Done.
    private var open: [GraftIssue] {
        visible.filter { $0.status != "done" }
    }

    /// With the toggle on, finished issues, most recently touched first.
    private var done: [GraftIssue] {
        guard showDone else { return [] }
        return visible.filter { $0.status == "done" }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var moving: [GraftIssue] {
        let flagged = Set(needsYou.map(\.id))
        return open.filter { $0.status == "in-progress" && !flagged.contains($0.id) }
    }

    /// The catch-all. Anything the two sections above did not claim lands here,
    /// which is what stops the screen ever being blank while issues exist.
    private var backlog: [GraftIssue] {
        let claimed = Set(needsYou.map(\.id)).union(moving.map(\.id))
        return open.filter { !claimed.contains($0.id) }
    }

    /// The rows in the order they are drawn, sectioned, for the keyboard and
    /// the monitor. Empty sections are left out: there is nothing to land on.
    private var keySections: [(title: String?, ids: [String])] {
        let sections: [(String, [GraftIssue])]
        if query.group == .none {
            sections = [("Needs you", needsYou), ("In progress", moving), ("Backlog", backlog), ("Done", done)]
        } else {
            sections = store.groups(visible, by: query.group).map { ($0.title, $0.issues) }
        }
        return sections.filter { !$0.1.isEmpty }.map { (title: Optional($0.0), ids: $0.1.map(\.id)) }
    }

    private var summary: String {
        let projects = Set(open.map(\.projectId)).count
        // Overdue and due-today earn a place in the one line this screen always
        // shows — but only when there are any. A permanent "0 overdue" is how a
        // number stops being read. Same rule as the web client's Today page.
        var bits: [String] = []
        let overdue = store.overdueCount(in: open)
        let dueToday = store.dueTodayCount(in: open)
        if overdue > 0 { bits.append("\(overdue) overdue") }
        if dueToday > 0 { bits.append("\(dueToday) due today") }
        bits.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you")
        bits.append("\(open.count) open across \(projects) project\(projects == 1 ? "" : "s")")
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
            root
            .toolbar(.hidden, for: .navigationBar)
            .graftKeyList(
                ids: keySections.flatMap(\.ids),
                selection: $keySelection,
                display: { selected in
                    .issues(title: "Inbox", items: ExternalListItem.sections(keySections), selected: selected,
                            query: query.q)
                },
                onOpen: { id in
                    guard let issue = store.issues.first(where: { $0.id == id }) else { return }
                    if splitActive {
                        selectedIssue = issue
                    } else {
                        router.inboxPath.append(GraftRoute.issue(issue))
                    }
                },
                key: { k, selected in
                    switch k {
                    case "n": showNewIssue = true; return true
                    case "/": searchFocus += 1; return true
                    default:
                        guard let selected else { return false }
                        return store.handleIssueKey(k, issueId: selected) { undo = $0 }
                    }
                }
            )
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

    /// The phone: the list, exactly as it always was. Regular width: the list,
    /// and beside it the open issue once the screen is wide enough for both.
    @ViewBuilder
    private var root: some View {
        if sizeClass == .regular {
            GeometryReader { geo in
                let split = geo.size.width >= Self.splitMinWidth
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: split ? Self.listWidth : nil)
                    if split {
                        Rectangle()
                            .fill(Color.gHairline)
                            .frame(width: GraftMetrics.border)
                            .ignoresSafeArea()
                            .accessibilityHidden(true)
                        detailColumn
                    }
                }
                .onAppear { setSplit(split) }
                .onChange(of: split) { _, now in setSplit(now) }
            }
            .background(Color.gBg.ignoresSafeArea())
        } else {
            listColumn
                .onAppear { setSplit(false) }
        }
    }

    /// Narrowed with an issue open beside the list: it carries on as a pushed
    /// screen rather than vanishing.
    private func setSplit(_ now: Bool) {
        splitActive = now
        if !now, let open = selectedIssue {
            selectedIssue = nil
            router.inboxPath.append(GraftRoute.issue(open))
        }
    }

    /// The issue beside the list, or a quiet word when none is open.
    @ViewBuilder
    private var detailColumn: some View {
        if let selectedIssue {
            IssueDetailView(issue: selectedIssue, onClose: { self.selectedIssue = nil })
                // A fresh screen per issue: its fields load once, on appear.
                .id(selectedIssue.id)
        } else {
            GraftEmptyState(title: "No issue open",
                            subtitle: "Choose one from the list, or start a new one.",
                            systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gBg.ignoresSafeArea())
        }
    }

    /// The header, the filters and the list — the whole screen on the phone,
    /// the left column beside an open issue.
    private var listColumn: some View {
            ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // The header, the filter row and the search field are all
                // ordinary content now — see `Chrome.swift`. The navigation bar
                // is hidden outright rather than restyled, because from iOS 26
                // its items come wrapped in glass capsules we cannot reach.
                GraftScreenHeader(title: "Inbox", subtitle: summary) {
                    // Regular width: the + is here rather than floating, so it
                    // never sits over the open issue's Mark done.
                    if sizeClass == .regular {
                        newIssueButton
                    }
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
                                     text: searchBinding,
                                     focusRequest: searchFocus) {
                        let snapshot = store.inboxQuery
                        Task { await store.refreshIssues(matching: snapshot) }
                    }
                    FilterButton(query: query) { showFilters = true }
                    GraftIconButton(systemImage: showDone ? "checkmark.circle.fill" : "checkmark.circle",
                                    tint: showDone ? .gAccentText : .gInk2,
                                    accessibilityTitle: showDone ? "Hide done" : "Show done") {
                        showDone.toggle()
                    }
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.spaceS)

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sizeClass != .regular {
                GraftFAB(label: "New issue") { showNewIssue = true }
            }
            }
            // `.background` rather than a `Color` inside the stack: a child
            // that ignores the safe area drags the stack's own bounds down
            // with it, which is what used to push the + button under the bar.
            .background(Color.gBg.ignoresSafeArea())
    }

    /// The FAB's action as a pill in the header, for regular width.
    private var newIssueButton: some View {
        Button { showNewIssue = true } label: {
            Text("+ Issue")
                .font(GraftFont.text(GraftType.secondary, .semibold))
                .foregroundStyle(Color.gOnAccent)
                .padding(.horizontal, GraftMetrics.spaceS)
                .frame(minHeight: GraftMetrics.control)
                .background(Color.gAccent, in: Capsule())
                .frame(minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New issue")
    }

    // MARK: - The five states

    @ViewBuilder
    private var content: some View {
        if store.isFirstRun {
            // A new install chooses first: this phone on its own, or a
            // server. Answered once; after that an empty Inbox is just empty.
            GraftWelcomeState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if store.issues.isEmpty && store.isLoading {
            ScrollView {
                VStack(spacing: 0) {
                    SyncStrip().padding(.bottom, GraftMetrics.spaceXS)
                    GraftSkeletonList()
                }
            }

        } else if store.emptyBecauseUnreachable, let error = store.errorMessage {
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
        ScrollViewReader { proxy in
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
                    section("Done", done, empty: nil)
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
        .onChange(of: keySelection) { _, selected in
            guard let selected else { return }
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selected, anchor: .center) }
        }
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
                issueLink(issue)
                .id(issue.id)
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

    /// Pushed on the phone; beside the list, a tap opens it in the right pane.
    @ViewBuilder
    private func issueLink(_ issue: GraftIssue) -> some View {
        let row = GraftIssueRow(issue: issue,
                                project: store.project(issue.projectId),
                                due: store.dueDate(for: issue))
            .graftKeySelected(keySelection == issue.id || (splitActive && selectedIssue?.id == issue.id))
        if splitActive {
            Button {
                // A tap takes over from the keyboard's row, so only one
                // outline shows (and the list doesn't scroll to recentre it).
                keySelection = nil
                selectedIssue = issue
            } label: { row }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: GraftRoute.issue(issue)) { row }
                .buttonStyle(.plain)
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
