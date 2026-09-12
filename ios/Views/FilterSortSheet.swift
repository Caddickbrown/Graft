import SwiftUI

// MARK: - Filter, sort and group
//
// iOS had almost none of this: a two-way Everyone/Unassigned picker on the
// Inbox and a project-name search on the Projects tab, against a web client
// with a command palette, five-dimension filtering and bulk actions. This is
// the whole of the missing half, in one sheet, over the state the store
// persists — so a filter set on a project is still set when you come back.

/// One row of a multi-select filter section.
///
/// A named struct rather than a `(value, label)` tuple because `ForEach` needs
/// a key path to identify its data, and Swift has no key paths into tuples.
struct FilterOption: Identifiable, Hashable {
    let id: String
    let label: String

    init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }
}

struct FilterSortSheet: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Binding var query: IssueQuery

    /// Set when the sheet is opened from inside one project. Filtering by
    /// project or area is meaningless there, so those sections are hidden.
    var projectId: String? = nil

    @State private var showSaveView = false
    @State private var newViewName = ""

    private var isProjectScoped: Bool { projectId != nil }

    /// Milestones to offer: this project's when scoped, otherwise all of them.
    private var milestoneOptions: [GraftMilestone] {
        guard let projectId else { return store.milestones }
        return store.milestones(for: projectId)
    }

    var body: some View {
        NavigationStack {
            Form {
                sortSection
                groupSection
                filterSections
                archivedSection
                savedViewsSection
                resetSection
            }
            .navigationTitle("Filter & sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Save this view", isPresented: $showSaveView) {
                TextField("Name", text: $newViewName)
                Button("Cancel", role: .cancel) { newViewName = "" }
                Button("Save") {
                    let name = newViewName.trimmingCharacters(in: .whitespaces)
                    newViewName = ""
                    guard !name.isEmpty else { return }
                    let snapshot = query
                    Task { try? await store.createSavedView(name: name, query: snapshot) }
                }
            } message: {
                Text("Saved views sync with the web client, so this one opens there too.")
            }
        }
    }

    // MARK: - Sort

    private var sortSection: some View {
        Section("Sort") {
            Picker("Sort by", selection: $query.sort) {
                ForEach(IssueSort.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("Direction", selection: $query.dir) {
                ForEach(IssueSortDirection.allCases, id: \.self) { dir in
                    Text(dir.label).tag(dir)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Group

    private var groupSection: some View {
        Section {
            Picker("Group by", selection: $query.group) {
                ForEach(IssueGrouping.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } header: {
            Text("Group")
        } footer: {
            Text("Grouping is applied on the phone, so it works offline too.")
        }
    }

    // MARK: - Filters

    @ViewBuilder
    private var filterSections: some View {
        multiSection(
            title: "Status",
            options: IssueStatus.allCases.map { FilterOption($0.rawValue, $0.label) },
            selection: $query.filters.status
        )

        multiSection(
            title: "Priority",
            options: IssuePriority.allCases.map { FilterOption($0.rawValue, $0.label) },
            selection: $query.filters.priority
        )

        multiSection(title: "Assignee", options: assigneeOptions, selection: $query.filters.assignee)

        if !store.allLabels.isEmpty {
            multiSection(
                title: "Label",
                options: store.allLabels.map { FilterOption($0, $0) },
                selection: $query.filters.label
            )
        }

        multiSection(
            title: "Milestone",
            // "none" is the contract's sentinel for "has no milestone" and is
            // understood by the server's `milestone_id` param too.
            options: [FilterOption("none", "No milestone")]
                + milestoneOptions.map { FilterOption($0.id, $0.name) },
            selection: $query.filters.milestoneId
        )

        if !isProjectScoped {
            let live = store.projects.filter { !$0.archived }
            if !live.isEmpty {
                multiSection(
                    title: "Project",
                    options: live.map { FilterOption($0.id, $0.name) },
                    selection: $query.filters.projectId
                )
            }
            if !store.areas.isEmpty {
                multiSection(
                    title: "Area",
                    options: [FilterOption("", "No area")]
                        + store.sortedAreas.map { FilterOption($0.id, $0.name) },
                    selection: $query.filters.areaId
                )
            }
        }
    }

    /// `""` is Unassigned — the same sentinel the store's filter uses.
    private var assigneeOptions: [FilterOption] {
        [FilterOption("", "Unassigned")] + store.assignees.map { FilterOption($0, $0) }
    }

    private var archivedSection: some View {
        Section {
            Toggle("Show archived", isOn: $query.archived)
                .tint(Color.gAccent)
        } footer: {
            Text("Archived issues stay on the phone either way — this only decides whether they are listed.")
        }
    }

    // MARK: - Saved views

    private var savedViewsSection: some View {
        Section("Saved views") {
            ForEach(store.savedViews) { view in
                Button {
                    query = IssueQuery.from(json: view.query)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "bookmark")
                            .foregroundStyle(Color.gAccentText)
                        Text(view.name)
                            .foregroundStyle(Color.gInk)
                        Spacer()
                    }
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { try? await store.deleteSavedView(id: view.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button {
                showSaveView = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Save current view…")
                    Spacer()
                }
                .foregroundStyle(Color.gAccentText)
                .frame(minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                query.reset()
            } label: {
                Text("Reset filters and sort")
                    .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
            // Grouping is deliberately not part of "reset": it is a way of
            // looking, not a way of narrowing, and losing it is a surprise.
            .disabled(query.badgeCount == 0 && !query.hasSearch
                      && query.sort == .manual && query.dir == .asc)
        }
    }

    // MARK: - Multi-select section
    //
    // Multi-value wherever the contract says multi-value: repeated params on
    // the wire, `IN (...)` on the server, a set here.

    @ViewBuilder
    private func multiSection(
        title: String,
        options: [FilterOption],
        selection: Binding<[String]>
    ) -> some View {
        Section {
            ForEach(options) { option in
                let isOn = selection.wrappedValue.contains(option.id)
                Button {
                    var next = selection.wrappedValue
                    if let idx = next.firstIndex(of: option.id) {
                        next.remove(at: idx)
                    } else {
                        next.append(option.id)
                    }
                    selection.wrappedValue = next
                } label: {
                    HStack {
                        Text(option.label)
                            .foregroundStyle(Color.gInk)
                        Spacer()
                        if isOn {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.gAccentText)
                        }
                    }
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !selection.wrappedValue.isEmpty {
                    Button("Clear") { selection.wrappedValue = [] }
                        .font(.system(size: GraftType.micro, weight: .semibold))
                        .foregroundStyle(Color.gAccentText)
                }
            }
        }
    }
}

// MARK: - The button that opens it
//
// Carries the count so the state is legible without opening the sheet — the
// single worst thing a filter can do is be on and invisible.

struct FilterButton: View {
    let query: IssueQuery
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GraftMetrics.spaceXXS) {
                Image(systemName: query.badgeCount > 0
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                if query.badgeCount > 0 {
                    Text("\(query.badgeCount)")
                        .font(.system(size: GraftType.micro, weight: .semibold))
                }
            }
            .foregroundStyle(query.badgeCount > 0 ? Color.gAccentText : Color.gInk2)
            .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(query.badgeCount > 0
                            ? "Filter and sort, \(query.badgeCount) active"
                            : "Filter and sort")
    }
}
