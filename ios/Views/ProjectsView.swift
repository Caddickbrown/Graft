import SwiftUI

/// One area's worth of the project list.
///
/// A named struct rather than a labelled tuple because `ForEach` identifies its
/// data through a key path, and Swift has no key paths into tuples. `id` folds
/// "no area" into a real identifier so the unfiled section is stable too.
fileprivate struct AreaSection: Identifiable {
    let area: GraftArea?
    let projects: [GraftProject]
    /// The pinned section that sits above the areas. It has no `GraftArea`
    /// behind it, which is also what "no area" looks like, so the two are told
    /// apart by this rather than by `area == nil`.
    var favourites: Bool = false

    /// Also the key the collapse state is stored under.
    var id: String { favourites ? "__favourites" : (area?.id ?? "__none") }
}

struct ProjectsView: View {
    @Environment(GraftStore.self) private var store
    @State private var showNewProject = false
    @State private var showAreas = false
    @State private var searchText = ""
    @State private var pendingDelete: GraftProject?
    @State private var undo: UndoAction?
    @State private var projectSort: ProjectSortOrder = .default

    /// Issues that would go with a project, so the confirmation can say so.
    private func issueCount(_ project: GraftProject) -> Int {
        store.issues.filter { $0.projectId == project.id }.count
    }

    private func favourite(_ project: GraftProject) {
        Task { try? await store.favouriteProject(id: project.id) }
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
        let base: [GraftProject]
        if searchText.isEmpty {
            base = scopedProjects
        } else {
            base = scopedProjects.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        return projectSort.apply(base, areas: store.sortedAreas)
    }

    /// Projects grouped into their areas, real areas first in their own order
    /// and the unfiled ones last. An area with nothing in it is not drawn.
    private var sections: [AreaSection] {
        let projects = filteredProjects
        var result: [AreaSection] = []
        // Favourites are lifted to the top and *removed* from their areas. The
        // web client repeats them, because its rail and its grid are two
        // different surfaces; here there is only the one list, and a project
        // appearing twice in a single scroll reads as a sync bug.
        let pinned = projects.filter(\.isFavourite)
        if !pinned.isEmpty { result.append(AreaSection(area: nil, projects: pinned, favourites: true)) }
        let rest = projects.filter { !$0.isFavourite }
        for area in store.sortedAreas {
            let inArea = rest.filter { $0.areaKey == area.id }
            if !inArea.isEmpty { result.append(AreaSection(area: area, projects: inArea)) }
        }
        let known = Set(store.areas.map(\.id))
        // An `area_id` pointing at an area this phone has not synced yet is
        // unfiled rather than lost.
        let unfiled = rest.filter { !known.contains($0.areaKey) }
        if !unfiled.isEmpty { result.append(AreaSection(area: nil, projects: unfiled)) }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // The wordmark rather than a title: this is the one screen that
                // carries the brand. It used to live in `.principal`, centred
                // between two clusters of bar buttons; here it heads the page
                // the way it heads the web client's rail.
                GraftScreenHeader(title: "Graft",
                                  titleView: AnyView(GraftWordmark(size: 24))) {
                    Menu {
                        Picker("Sort", selection: $projectSort) {
                            ForEach(ProjectSortOrder.allCases, id: \.self) { s in
                                Text(s.label).tag(s)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(projectSort == .default ? Color.gInk2 : Color.gAccentText)
                            .frame(width: GraftMetrics.control, height: GraftMetrics.control)
                            .background(projectSort == .default ? Color.gSurface2 : Color.gAccentWash,
                                        in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                            .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Sort projects")

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

                    GraftIconButton(systemImage: "plus",
                                    tint: Color.gAccentText,
                                    accessibilityTitle: "New project") {
                        showNewProject = true
                    }
                }

                HStack(spacing: GraftMetrics.spaceXS) {
                    GraftSearchField(placeholder: "Search projects", text: $searchText)
                    scopeMenu
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.spaceS)

                SyncStrip()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GraftFAB(label: "New project") { showNewProject = true }
            }
            .background(Color.gBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
            // A chip beside the search field, not a bar button: same bordered
            // square family as the icon buttons in the header above it.
            HStack(spacing: GraftMetrics.spaceXXS) {
                Image(systemName: store.projectScope.systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(store.projectScope.label)
                    .font(GraftFont.text(GraftType.caption, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(store.projectScope == .active ? Color.gInk2 : Color.gAccentText)
            .padding(.horizontal, GraftMetrics.spaceS)
            .frame(minHeight: GraftMetrics.tap)
            .background(store.projectScope == .active ? Color.gSurface2 : Color.gAccentWash,
                        in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
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
                // heading over every project. Favourites are the exception:
                // that section is headed whatever the areas are doing, because
                // an unlabelled block of pinned projects at the top of the list
                // just looks like the sort is wrong.
                let grouping = !store.areas.isEmpty || section.favourites
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
                            // Pinning goes on the leading edge, away from
                            // Delete: it is the one swipe you make often, and
                            // it should never be a slip of the thumb from the
                            // one that destroys the project.
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    favourite(project)
                                } label: {
                                    Label(project.isFavourite ? "Unpin" : "Favourite",
                                          systemImage: project.isFavourite ? "star.slash" : "star")
                                }
                                .tint(Color.gAmber)
                            }
                        }
                        // No .onDelete here on purpose. A left swipe used to
                        // call deleteProject directly, destroying the project
                        // and cascading every issue in it with no confirmation
                        // and no way back.
                        .onDelete { _ in }
                    }
                } header: {
                    if section.favourites {
                        favouritesHeader(count: section.projects.count, collapsed: collapsed)
                    } else if !store.areas.isEmpty {
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
        .refreshable {
            await store.sync()
        }
    }

    /// An area heading that folds its section shut. The whole row is the target,
    /// and the row is a full 44pt tall.
    private func areaHeader(_ area: GraftArea?, count: Int, collapsed: Bool) -> some View {
        sectionHeader(
            id: area?.id ?? "__none",
            title: area?.name ?? "No area",
            colourHex: (area?.colour).flatMap { $0.isEmpty ? nil : $0 },
            symbol: nil,
            count: count,
            collapsed: collapsed
        )
    }

    /// The pinned section above the areas. A star rather than an area's colour
    /// dot, and it folds shut like any other section — a long list of
    /// favourites is still a long list.
    private func favouritesHeader(count: Int, collapsed: Bool) -> some View {
        sectionHeader(
            id: "__favourites",
            title: "Favourites",
            colourHex: nil,
            symbol: "star.fill",
            count: count,
            collapsed: collapsed
        )
    }

    private func sectionHeader(
        id: String,
        title: String,
        colourHex: String?,
        symbol: String?,
        count: Int,
        collapsed: Bool
    ) -> some View {
        Button {
            store.toggleArea(id)
        } label: {
            HStack(spacing: GraftMetrics.spaceXS) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.gAmber)
                }
                if let colourHex {
                    ProjectColourDot(hex: colourHex, size: 8)
                }
                Text(title.uppercased())
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .kerning(GraftType.microTracking)
                    .foregroundStyle(Color.gInk2)
                Text("\(count)")
                    .font(GraftFont.text(GraftType.micro))
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
        .accessibilityLabel("\(title), \(count) projects")
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
                            .font(GraftFont.emoji(18))
                    }
                    Text(project.name)
                        .font(GraftFont.text(GraftType.title, .semibold))
                        .foregroundStyle(Color.gInk)
                    // The badge is what tells you why this card is at the top,
                    // and it keeps saying so when the card is drawn somewhere
                    // that has no Favourites section over it — search results,
                    // or a scope with only pinned projects in it.
                    if project.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.gAmber)
                            .accessibilityLabel("Favourite")
                    }
                    Spacer()
                    Text(project.status)
                        .font(GraftFont.text(GraftType.caption, .medium))
                        .foregroundStyle(projectStatusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(projectStatusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
                }

                // Description
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(GraftFont.text(GraftType.secondary))
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
                                .font(GraftFont.text(GraftType.caption))
                                .foregroundStyle(Color.gInk2)
                                .fixedSize()
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(counts.done) of \(total) done")
                    }
                }

                // Tags
                let tagList = project.tagList
                if !tagList.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(tagList, id: \.self) { tag in
                                Text(tag)
                                    .font(GraftFont.text(GraftType.micro, .medium))
                                    .foregroundStyle(Color.gInk2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.gSurface2)
                                    .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
                            }
                        }
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

// MARK: - Project sort order

enum ProjectSortOrder: String, CaseIterable {
    case `default`   // area section order, then creation
    case name
    case area
    case status

    var label: String {
        switch self {
        case .default: return "Default"
        case .name:    return "Name"
        case .area:    return "Area"
        case .status:  return "Status"
        }
    }

    func apply(_ projects: [GraftProject], areas: [GraftArea]) -> [GraftProject] {
        switch self {
        case .default:
            return projects
        case .name:
            return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .area:
            let areaIndex: (String) -> Int = { id in
                areas.firstIndex(where: { $0.id == id }) ?? Int.max
            }
            return projects.sorted {
                let ai = areaIndex($0.areaKey), bi = areaIndex($1.areaKey)
                if ai != bi { return ai < bi }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .status:
            let rank = ["active": 0, "paused": 1, "done": 2]
            return projects.sorted {
                let ra = rank[$0.status] ?? 3, rb = rank[$1.status] ?? 3
                if ra != rb { return ra < rb }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }
}
