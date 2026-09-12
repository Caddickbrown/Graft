import SwiftUI

/// One area's worth of the project list.
///
/// A named struct rather than a labelled tuple because `ForEach` identifies its
/// data through a key path, and Swift has no key paths into tuples. `id` folds
/// "no area" into a real identifier so the unfiled section is stable too.
fileprivate struct AreaSection: Identifiable {
    let area: GraftArea?
    let projects: [GraftProject]

    /// Also the key the collapse state is stored under.
    var id: String { area?.id ?? "__none" }
}

struct ProjectsView: View {
    @Environment(GraftStore.self) private var store
    @State private var showNewProject = false
    @State private var showAreas = false
    @State private var searchText = ""
    @State private var pendingDelete: GraftProject?
    @State private var undo: UndoAction?

    /// Issues that would go with a project, so the confirmation can say so.
    private func issueCount(_ project: GraftProject) -> Int {
        store.issues.filter { $0.projectId == project.id }.count
    }

    private func archive(_ project: GraftProject) {
        Task {
            try? await store.archiveProject(id: project.id)
            undo = UndoAction(message: project.archived ? "Project unarchived" : "Project archived") {
                try? await store.archiveProject(id: project.id)
            }
        }
    }

    // MARK: - What the tab is showing
    //
    // "Active" now means `status == "active"`, as it always has on the web.
    // On iOS it meant `archived == false`, so a paused or finished project
    // filed under Active and there was no way to ask for either.

    private var scopedProjects: [GraftProject] {
        store.projects.filter { store.projectScope.matches($0) }
    }

    private var filteredProjects: [GraftProject] {
        guard !searchText.isEmpty else { return scopedProjects }
        return scopedProjects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Projects grouped into their areas, real areas first in their own order
    /// and the unfiled ones last. An area with nothing in it is not drawn.
    private var sections: [AreaSection] {
        let projects = filteredProjects
        var result: [AreaSection] = []
        for area in store.sortedAreas {
            let inArea = projects.filter { $0.areaKey == area.id }
            if !inArea.isEmpty { result.append(AreaSection(area: area, projects: inArea)) }
        }
        let known = Set(store.areas.map(\.id))
        // An `area_id` pointing at an area this phone has not synced yet is
        // unfiled rather than lost.
        let unfiled = projects.filter { !known.contains($0.areaKey) }
        if !unfiled.isEmpty { result.append(AreaSection(area: nil, projects: unfiled)) }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.gBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    SyncStrip()
                        .padding(.top, GraftMetrics.spaceXS)
                    content
                }

                GraftFAB(label: "New project") { showNewProject = true }
            }
            .navigationTitle("Graft")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    scopeMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView().tint(Color.gAccent)
                    } else {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.gAccentText)
                                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectView()
            }
            .sheet(isPresented: $showAreas) {
                AreasView()
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete project?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let project = pendingDelete {
                    Button("Delete project and \(issueCount(project)) issues", role: .destructive) {
                        Task { try? await store.deleteProject(id: project.id) }
                        pendingDelete = nil
                    }
                    Button("Archive instead") {
                        archive(project)
                        pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let project = pendingDelete {
                    Text("This cannot be undone. Archiving keeps \(project.name) and its \(issueCount(project)) issues, just out of the way.")
                }
            }
            .undoBanner($undo)
        }
    }

    // MARK: - Scope

    private var scopeMenu: some View {
        Menu {
            Picker("Show", selection: Binding(
                get: { store.projectScope },
                set: { store.projectScope = $0 }
            )) {
                ForEach(ProjectScope.allCases, id: \.self) { scope in
                    Label(scope.label, systemImage: scope.systemImage).tag(scope)
                }
            }
            Divider()
            Button {
                showAreas = true
            } label: {
                Label("Manage areas…", systemImage: "square.stack.3d.up")
            }
        } label: {
            HStack(spacing: GraftMetrics.spaceXXS) {
                Image(systemName: store.projectScope.systemImage)
                Text(store.projectScope.label)
                    .font(.system(size: GraftType.caption, weight: .medium))
            }
            .foregroundStyle(Color.gAccentText)
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Showing \(store.projectScope.label) projects")
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if store.isFirstRun {
            GraftNoServerState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if store.projects.isEmpty && store.isLoading {
            ScrollView { GraftSkeletonList(count: 4) }

        } else if store.projects.isEmpty, let error = store.errorMessage {
            GraftErrorState(message: error) {
                Task { await store.sync() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if scopedProjects.isEmpty {
            GraftEmptyState(
                title: emptyTitle,
                subtitle: emptySubtitle,
                systemImage: store.projectScope.systemImage,
                actionTitle: showAllAction == nil ? nil : "Show all live projects",
                action: showAllAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            // Note that a search matching nothing does *not* swap the list out:
            // the search field belongs to the list, so replacing it would take
            // the field away mid-search. The "no matches" copy is a row inside
            // it instead.
            projectList
        }
    }

    /// "Nothing paused" is only useful if it comes with a way out of the
    /// narrower scope — there is no such thing for Active, which is the default.
    private var showAllAction: (() -> Void)? {
        guard store.projectScope != .active, store.projectScope != .all else { return nil }
        return { store.projectScope = .all }
    }

    private var emptyTitle: String {
        switch store.projectScope {
        case .archived: return "Nothing archived"
        case .active: return store.projects.isEmpty ? "No projects yet" : "Nothing active"
        case .paused: return "Nothing paused"
        case .done: return "Nothing finished"
        case .all: return "No projects yet"
        }
    }

    private var emptySubtitle: String {
        switch store.projectScope {
        case .archived: return "Archived projects wait here until you want them back."
        case .active: return store.projects.isEmpty
            ? "Time to get grafting."
            : "Every project is paused, finished or archived."
        case .paused: return "Nothing is on hold right now."
        case .done: return "No project has been marked done yet."
        case .all: return "Time to get grafting."
        }
    }

    // MARK: - The list

    private var projectList: some View {
        List {
            if filteredProjects.isEmpty {
                // A search matching nothing used to render a completely blank
                // list with no message at all.
                GraftNoResults(
                    searchText: searchText,
                    activeFilters: 0,
                    clearTitle: "Clear search"
                ) {
                    searchText = ""
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(sections) { section in
                // With no areas defined at all there is nothing to group by, so
                // the list stays flat rather than growing a permanent "NO AREA"
                // heading over every project.
                let grouping = !store.areas.isEmpty
                let collapsed = grouping && store.isAreaCollapsed(section.id)
                Section {
                    if !collapsed {
                        ForEach(section.projects) { project in
                            NavigationLink(destination: ProjectDetailView(project: project)) {
                                ProjectCardView(project: project)
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    archive(project)
                                } label: {
                                    Label(project.archived ? "Unarchive" : "Archive",
                                          systemImage: "archivebox")
                                }
                                .tint(Color.gAccent)
                            }
                        }
                        // No .onDelete here on purpose. A left swipe used to
                        // call deleteProject directly, destroying the project
                        // and cascading every issue in it with no confirmation
                        // and no way back.
                        .onDelete { _ in }
                    }
                } header: {
                    if grouping {
                        areaHeader(section.area, count: section.projects.count, collapsed: collapsed)
                    }
                }
                .listRowBackground(Color.clear)
                // The header does its own casing; without this SwiftUI would
                // uppercase an already-uppercased string and lose the kerning.
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search projects")
        .refreshable {
            await store.sync()
        }
    }

    /// An area heading that folds its section shut. The whole row is the target,
    /// and the row is a full 44pt tall.
    private func areaHeader(_ area: GraftArea?, count: Int, collapsed: Bool) -> some View {
        Button {
            store.toggleArea(area?.id ?? "__none")
        } label: {
            HStack(spacing: GraftMetrics.spaceXS) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                if let area, !area.colour.isEmpty {
                    ProjectColourDot(hex: area.colour, size: 8)
                }
                Text((area?.name ?? "No area").uppercased())
                    .font(.system(size: GraftType.micro, weight: .semibold))
                    .kerning(GraftType.microTracking)
                    .foregroundStyle(Color.gInk2)
                Text("\(count)")
                    .font(.system(size: GraftType.micro))
                    .foregroundStyle(Color.gInk2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.gSurface2, in: Capsule())
                Spacer(minLength: 0)
            }
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(area?.name ?? "No area"), \(count) projects")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Project Card

struct ProjectCardView: View {
    let project: GraftProject

    var projectStatusColor: Color {
        switch project.status {
        case "active": return .gAccent
        case "paused": return .gAmber
        case "done": return .gInk2
        default: return .gInk2
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left colour strip
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: project.colour))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS + 2) {
                // Name + status
                HStack(alignment: .firstTextBaseline) {
                    if !project.icon.isEmpty {
                        Text(project.icon)
                            .font(.system(size: 18))
                    }
                    Text(project.name)
                        .font(.system(size: GraftType.title, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Spacer()
                    Text(project.status)
                        .font(.system(size: GraftType.caption, weight: .medium))
                        .foregroundStyle(projectStatusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(projectStatusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
                }

                // Description
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.system(size: GraftType.secondary))
                        .foregroundStyle(Color.gInk2)
                        .lineLimit(2)
                }

                // Progress — "how far along" rather than two raw numbers
                if let counts = project.issueCounts {
                    let open = counts.backlog + counts.todo + counts.inProgress + counts.review
                    let total = open + counts.done
                    if total > 0 {
                        HStack(spacing: 10) {
                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.gAccent)
                                        .frame(width: geo.size.width * CGFloat(counts.done) / CGFloat(total))
                                    Rectangle().fill(Color.gAmber)
                                        .frame(width: geo.size.width * CGFloat(counts.inProgress) / CGFloat(total))
                                    Rectangle().fill(Color.gSurface2)
                                }
                            }
                            .frame(height: 6)
                            .clipShape(Capsule())

                            Text("\(open) open · \(counts.done) done")
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(Color.gInk2)
                                .fixedSize()
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(counts.done) of \(total) done")
                    }
                }
            }
            .padding(.horizontal, GraftMetrics.spaceS)
            .padding(.vertical, GraftMetrics.spaceS)
        }
        .frame(minHeight: GraftMetrics.tap)
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .stroke(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }
}
