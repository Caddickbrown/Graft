import SwiftUI

/// One kanban column / list section. A struct rather than a `(String, [Issue])`
/// tuple because `ForEach` identifies its data through a key path, and Swift
/// has none into tuples.
fileprivate struct StatusBucket: Identifiable {
    let id: String
    let issues: [GraftIssue]
}

struct ProjectDetailView: View {
    @Environment(GraftStore.self) private var store
    let project: GraftProject

    @State private var showNewIssue = false
    @State private var showNewIssueInStatus: String? = nil
    @State private var showMilestones = false
    @State private var showEditProject = false
    @State private var showFilters = false
    @State private var pendingDelete: GraftIssue?
    @State private var undo: UndoAction?

    // Note what is *not* here any more: `viewMode`, `selectedMilestoneId` and
    // `showArchived` used to be plain `@State` on a pushed view, so leaving the
    // project and coming back silently reset every one of them. They live in
    // the store now, keyed by project, and survive a relaunch.

    private func archive(_ issue: GraftIssue) {
        Task {
            try? await store.archiveIssue(id: issue.id)
            undo = UndoAction(message: issue.archived ? "Issue unarchived" : "Issue archived") {
                try? await store.archiveIssue(id: issue.id)
            }
        }
    }

    enum ViewMode: String, CaseIterable {
        case board = "Board"
        case list = "List"
    }

    // MARK: - Persisted per-project state

    private var query: IssueQuery { store.projectQuery(project.id) }

    private var queryBinding: Binding<IssueQuery> {
        Binding(
            get: { store.projectQuery(project.id) },
            set: { store.setProjectQuery($0, for: project.id) }
        )
    }

    private var viewMode: ViewMode {
        ViewMode(rawValue: store.projectViewModes[project.id] ?? "") ?? .board
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { viewMode },
            set: { store.projectViewModes[project.id] = $0.rawValue }
        )
    }

    /// The single milestone chip selection, expressed through the multi-value
    /// filter the sheet and the server both use.
    private var selectedMilestoneId: String? {
        query.filters.milestoneId.first
    }

    private func selectMilestone(_ id: String?) {
        var next = query
        next.filters.milestoneId = id.map { [$0] } ?? []
        store.setProjectQuery(next, for: project.id)
    }

    // MARK: - Data

    var currentProject: GraftProject {
        store.projects.first { $0.id == project.id } ?? project
    }

    var projectMilestones: [GraftMilestone] {
        store.milestones(for: project.id)
    }

    /// Every issue in this project, archived included — the query decides what
    /// is shown. Kept separate from `projectIssues` so "this project is empty"
    /// and "nothing matches your filters" are different answers.
    private var allProjectIssues: [GraftIssue] {
        store.issues.filter { $0.projectId == project.id }
    }

    var projectIssues: [GraftIssue] {
        store.apply(query, to: allProjectIssues)
    }

    fileprivate var issuesByStatus: [StatusBucket] {
        let order = ["backlog", "todo", "in-progress", "review", "done"]
        return order.map { status in
            StatusBucket(id: status, issues: projectIssues.filter { $0.status == status })
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.gBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SyncStrip()
                        .padding(.top, GraftMetrics.spaceXS)
                        .padding(.bottom, GraftMetrics.spaceXS)

                    header

                    ProjectLinksSection(projectId: project.id)
                        .padding(.bottom, GraftMetrics.spaceS)

                    milestoneChips

                    // No `.colorScheme(.dark)` here any more. It was the only
                    // appearance override in the codebase, and in light mode it
                    // drew a dark segmented control on a white screen.
                    // Chips, not `.pickerStyle(.segmented)`: the segmented
                    // control cannot take the accent and is the most recognisable
                    // stock-iOS control there is.
                    GraftChoiceRow(label: "", options: ViewMode.allCases,
                                   selection: viewModeBinding,
                                   title: { $0.rawValue })
                        .padding(.horizontal, GraftMetrics.gutter)
                        .padding(.vertical, 10)

                    issuesContent
                }
            }
            .scrollContentBackground(.hidden)
            // Project detail had no refresh at all: the only way to pull was to
            // go back to a tab root and pull there.
            .refreshable { await store.sync() }

            GraftFAB(label: "New issue") { showNewIssue = true }
        }
        .navigationTitle(currentProject.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.gBg, for: .navigationBar)
        .searchable(text: searchBinding, prompt: "Search issues in this project")
        .onSubmit(of: .search) {
            let snapshot = query
            Task { await store.refreshIssues(matching: snapshot) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FilterButton(query: query) { showFilters = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditProject = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.gInk2)
                        .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Edit project")
            }
        }
        .sheet(isPresented: $showFilters) {
            FilterSortSheet(query: queryBinding, projectId: project.id)
        }
        .sheet(isPresented: $showNewIssue) {
            NewIssueView(projectId: project.id)
        }
        .sheet(item: $showNewIssueInStatus) { status in
            NewIssueView(projectId: project.id, defaultStatus: status)
        }
        .sheet(isPresented: $showMilestones) {
            MilestonesView(projectId: project.id)
        }
        .confirmationDialog("Delete this issue?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            if let issue = pendingDelete {
                Button("Delete permanently", role: .destructive) {
                    Task { try? await store.deleteIssue(id: issue.id) }
                    pendingDelete = nil
                }
                Button("Archive instead") {
                    archive(issue)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Archiving keeps the issue and can be undone. Deleting cannot.")
        }
        .undoBanner($undo)
        .sheet(isPresented: $showEditProject) {
            EditProjectView(project: currentProject)
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { query.q },
            set: { newValue in
                var next = query
                next.q = newValue
                store.setProjectQuery(next, for: project.id)
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GraftMetrics.spaceS) {
            if !currentProject.icon.isEmpty {
                Text(currentProject.icon)
                    .font(GraftFont.text(28))
                    .frame(width: 36, height: 36)
            } else {
                RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                    .fill(Color(hex: currentProject.colour))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 3) {
                if !currentProject.description.isEmpty {
                    Text(currentProject.description)
                        .font(GraftFont.text(GraftType.secondary))
                        .foregroundStyle(Color.gInk2)
                }
                HStack(spacing: GraftMetrics.spaceXS) {
                    projectStatusChip(currentProject.status)
                    if let area = store.area(currentProject.areaId) {
                        Text(area.name)
                            .font(GraftFont.text(GraftType.caption, .medium))
                            .foregroundStyle(Color.gInk2)
                            .padding(.horizontal, GraftMetrics.spaceXS)
                            .padding(.vertical, GraftMetrics.spaceXXS)
                            .background(Color.gSurface2)
                            .clipShape(Capsule())
                    }
                    Button {
                        showMilestones = true
                    } label: {
                        HStack(spacing: GraftMetrics.spaceXXS) {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 10))
                            Text("Milestones")
                                .font(GraftFont.text(GraftType.caption, .medium))
                        }
                        .foregroundStyle(Color.gAccentText)
                        .padding(.horizontal, GraftMetrics.spaceXS)
                        .background(Color.gAccentWash)
                        .clipShape(Capsule())
                        .frame(minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.bottom, GraftMetrics.spaceS)
    }

    // MARK: - Milestone chips

    @ViewBuilder
    private var milestoneChips: some View {
        if !projectMilestones.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GraftMetrics.spaceXS) {
                    MilestoneFilterChip(title: "All", isSelected: selectedMilestoneId == nil) {
                        selectMilestone(nil)
                    }
                    ForEach(projectMilestones) { milestone in
                        MilestoneFilterChip(
                            title: milestone.name,
                            isSelected: selectedMilestoneId == milestone.id
                        ) {
                            selectMilestone(selectedMilestoneId == milestone.id ? nil : milestone.id)
                        }
                    }
                }
                .padding(.horizontal, GraftMetrics.gutter)
            }
            Divider().background(Color.gHairline)
        }
    }

    // MARK: - Issue content, and its states

    @ViewBuilder
    private var issuesContent: some View {
        if allProjectIssues.isEmpty && store.isLoading {
            GraftSkeletonList(count: 4)
                .padding(.top, GraftMetrics.spaceS)

        } else if allProjectIssues.isEmpty {
            GraftEmptyState(
                title: "Nothing growing here",
                subtitle: "Tap + to plant your first issue.",
                systemImage: "leaf"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, GraftMetrics.spaceL)

        } else if projectIssues.isEmpty {
            // The old code showed "Tap + to plant your first issue" here, about
            // a project holding 41 of them, because a milestone filter matching
            // nothing was indistinguishable from an empty project.
            GraftNoResults(
                searchText: query.q,
                activeFilters: query.badgeCount,
                clearTitle: "Clear filters"
            ) {
                var next = query
                next.reset()
                store.setProjectQuery(next, for: project.id)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, GraftMetrics.spaceL)

        } else if query.group != .none {
            groupedListView

        } else if viewMode == .list {
            listView

        } else {
            boardView
        }
    }

    // MARK: - List view

    @ViewBuilder
    var listView: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(issuesByStatus) { bucket in
                if !bucket.issues.isEmpty {
                    Section {
                        ForEach(bucket.issues) { issue in
                            issueRow(issue)
                        }
                    } header: {
                        statusHeader(bucket.id, count: bucket.issues.count)
                    }
                }
            }
        }
        .padding(.bottom, 100)
    }

    /// The same list, grouped by whatever the filter sheet asked for.
    @ViewBuilder
    var groupedListView: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(store.groups(projectIssues, by: query.group)) { group in
                Section {
                    ForEach(group.issues) { issue in
                        issueRow(issue)
                    }
                } header: {
                    GraftSectionHeader(title: group.title, count: group.issues.count)
                        .background(Color.gBg)
                }
            }
        }
        .padding(.bottom, 100)
    }

    @ViewBuilder
    private func issueRow(_ issue: GraftIssue) -> some View {
        NavigationLink(destination: IssueDetailView(issue: issue)) {
            GraftIssueRow(
                issue: issue,
                due: GraftDate.dueLabel(store.milestone(issue.milestoneId)?.dueDate),
                showProject: false
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.vertical, GraftMetrics.spaceXXS)
        // A context menu, not .swipeActions: these rows live in a LazyVStack,
        // and swipe actions are only wired up for rows of a List, so the swipe
        // here did nothing at all. The Inbox rows use the same affordance.
        .contextMenu {
            Button {
                archive(issue)
            } label: {
                Label(issue.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                pendingDelete = issue
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func statusHeader(_ status: String, count: Int) -> some View {
        let s = IssueStatus(rawValue: status) ?? .backlog
        return HStack(spacing: GraftMetrics.spaceXS) {
            StatusRing(status: s, size: 12)
            Text(s.label)
                .font(GraftFont.text(GraftType.micro, .semibold))
                .kerning(GraftType.microTracking)
                .foregroundStyle(Color.gInk2)
            Text("\(count)")
                .font(GraftFont.text(GraftType.micro))
                .foregroundStyle(Color.gInk2)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Color.gSurface2, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.vertical, GraftMetrics.spaceXS)
        .background(Color.gBg)
    }

    // MARK: - Board view

    @ViewBuilder
    var boardView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(issuesByStatus) { bucket in
                    KanbanColumn(
                        status: bucket.id,
                        issues: bucket.issues,
                        onAddIssue: { showNewIssueInStatus = bucket.id }
                    )
                }
            }
            .padding(.horizontal, GraftMetrics.gutter)
            .padding(.bottom, 100)
            .padding(.top, GraftMetrics.spaceXS)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    func projectStatusChip(_ status: String) -> some View {
        let color: Color = {
            switch status {
            case "active": return .gAccent
            case "paused": return .gAmber
            default: return .gInk2
            }
        }()
        Text(status)
            .font(GraftFont.text(GraftType.caption, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, GraftMetrics.spaceXS)
            .padding(.vertical, GraftMetrics.spaceXXS)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Kanban Column

struct KanbanColumn: View {
    @Environment(GraftStore.self) private var store
    let status: String
    let issues: [GraftIssue]
    let onAddIssue: () -> Void

    var statusInfo: IssueStatus { IssueStatus(rawValue: status) ?? .backlog }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack(spacing: GraftMetrics.spaceXXS + 2) {
                StatusRing(status: statusInfo, size: 12)
                Text(statusInfo.label)
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .kerning(GraftType.microTracking)
                    .foregroundStyle(Color.gInk2)
                Spacer()
                Text("\(issues.count)")
                    .font(GraftFont.text(GraftType.micro))
                    .foregroundStyle(Color.gInk2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gSurface2)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            // Cards
            VStack(spacing: 6) {
                ForEach(issues) { issue in
                    KanbanCard(issue: issue)
                        .padding(.horizontal, GraftMetrics.spaceXS)
                }

                // Add button
                Button(action: onAddIssue) {
                    HStack(spacing: GraftMetrics.spaceXXS) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("Add issue")
                            .font(GraftFont.text(GraftType.secondary))
                    }
                    .foregroundStyle(Color.gInk2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 10)

            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .stroke(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }
}

// MARK: - Kanban Card

struct KanbanCard: View {
    @Environment(GraftStore.self) private var store
    let issue: GraftIssue

    @State private var showStatusPicker = false

    let allStatuses = ["backlog", "todo", "in-progress", "review", "done"]

    var body: some View {
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal
        let labels = issue.labels.filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS + 2) {
            NavigationLink(destination: IssueDetailView(issue: issue)) {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS + 2) {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(priority.color)
                            .frame(width: 3, height: 14)
                            .padding(.trailing, 6)
                        Text(issue.title)
                            .font(GraftFont.text(GraftType.secondary, .medium))
                            .foregroundStyle(Color.gInk)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }

                    if !labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(labels.prefix(2), id: \.self) { label in
                                GraftLabelChip(text: label)
                            }
                            if labels.count > 2 {
                                Text("+\(labels.count - 2)")
                                    .font(GraftFont.text(GraftType.caption, .medium))
                                    .foregroundStyle(Color.gInk3)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: GraftMetrics.spaceXXS + 2) {
                        if let milestone = issue.milestoneName {
                            MilestoneTag(name: milestone)
                        }
                        if !issue.assignee.isEmpty {
                            Text("@\(issue.assignee)")
                                .font(GraftFont.text(GraftType.caption))
                                .foregroundStyle(Color.gInk2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)

            // Status pill — tap to change without opening detail.
            //
            // Outside the NavigationLink on purpose: nested inside one, the tap
            // belonged to the link. And the visual pill is ~22pt, so it carries
            // a 44pt hit area of its own rather than being the ~16pt target it
            // used to be.
            Button {
                showStatusPicker = true
            } label: {
                HStack(spacing: GraftMetrics.spaceXXS) {
                    let s = IssueStatus(rawValue: issue.status) ?? .backlog
                    StatusRing(status: s, size: 10)
                    Text(s.label)
                        .font(GraftFont.text(GraftType.micro, .medium))
                        .foregroundStyle(s.color)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor(issue.status).opacity(0.12))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Status, \(IssueStatus(rawValue: issue.status)?.label ?? issue.status). Change")
            .confirmationDialog("Move to…", isPresented: $showStatusPicker, titleVisibility: .visible) {
                ForEach(allStatuses.filter { $0 != issue.status }, id: \.self) { s in
                    let label = IssueStatus(rawValue: s)?.label ?? s
                    Button(label) {
                        Task { try? await store.updateIssueStatus(id: issue.id, status: s) }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.gSurface2)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
    }

    func statusColor(_ status: String) -> Color {
        IssueStatus(rawValue: status)?.color ?? Color.gInk2
    }
}

// MARK: - Milestone Filter Chip

struct MilestoneFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GraftMetrics.spaceXXS) {
                if isSelected {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(GraftFont.text(GraftType.secondary, isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.gAccentText : Color.gInk2)
            .padding(.horizontal, 10)
            // The chip reads at the small control height, but the thing you can
            // hit is 44pt — it was a ~28pt target.
            .frame(minHeight: GraftMetrics.controlSmall)
            .background(
                isSelected ? Color.gAccentWash : Color.gSurface2,
                in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                    .stroke(isSelected ? Color.gAccent.opacity(0.35) : Color.gHairline,
                            lineWidth: GraftMetrics.border)
            )
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
