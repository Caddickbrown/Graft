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
            ScrollView {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceXL) {
                    sortSection
                    groupSection
                    filterSections
                    archivedSection
                    savedViewsSection
                    resetSection
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.vertical, GraftMetrics.spaceM)
            }
            .background(Color.gBg)
            .navigationTitle("Filter & sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(GraftFont.text(GraftType.body, .semibold))
                        .foregroundStyle(Color.gAccentText)
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
        GraftSection(title: "Sort") {
            GraftChoiceRow(label: "", options: IssueSort.allCases,
                           selection: $query.sort, title: { $0.label })
            GraftRowDivider()
            GraftChoiceRow(label: "Direction", options: IssueSortDirection.allCases,
                           selection: $query.dir, title: { $0.label })
        }
    }

    // MARK: - Group

    private var groupSection: some View {
        GraftSection(title: "Group",
                     footnote: "Grouping is applied on the phone, so it works offline too.") {
            GraftChoiceRow(label: "", options: IssueGrouping.allCases,
                           selection: $query.group, title: { $0.label })
        }
    }

    // MARK: - Filters

    @ViewBuilder
    private var filterSections: some View {
        multiSection(
            title: "Status",
            options: IssueStatus.allCases.map { FilterOption($0.rawValue, $0.label) },
            selection: $query.filters.status,
            dot: { IssueStatus(rawValue: $0)?.color }
        )

        multiSection(
            title: "Priority",
            options: IssuePriority.allCases.map { FilterOption($0.rawValue, $0.label) },
            selection: $query.filters.priority,
            dot: { IssuePriority(rawValue: $0)?.color }
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
        GraftSection(title: "Archived",
                     footnote: "Archived issues stay on the phone either way — this only decides whether they are listed.") {
            GraftToggleRow(label: "Show archived", isOn: $query.archived)
        }
    }

    // MARK: - Saved views

    private var savedViewsSection: some View {
        GraftSection(title: "Saved views") {
            // Delete is a button, not a swipe: `swipeActions` only works inside
            // a `List`, and this sheet is no longer one. A hidden gesture is a
            // bad trade for a stock container anyway.
            ForEach(store.savedViews) { view in
                HStack(spacing: GraftMetrics.spaceXS) {
                    Button {
                        query = IssueQuery.from(json: view.query)
                        dismiss()
                    } label: {
                        HStack(spacing: GraftMetrics.spaceXS) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.gAccentText)
                            Text(view.name)
                                .font(GraftFont.text(GraftType.body))
                                .foregroundStyle(Color.gInk)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { try? await store.deleteSavedView(id: view.id) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.gInk3)
                            .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(view.name)")
                }

                if !store.savedViews.isEmpty { GraftRowDivider() }
            }

            Button {
                showSaveView = true
            } label: {
                HStack(spacing: GraftMetrics.spaceXS) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                    Text("Save current view…")
                        .font(GraftFont.text(GraftType.body))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.gAccentText)
                .frame(minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var resetSection: some View {
        Group {
            Button {
                query.reset()
            } label: {
                Text("Reset filters and sort")
                    .font(GraftFont.text(GraftType.body, .medium))
                    .foregroundStyle(canReset ? Color.gRed : Color.gInk3)
                    .frame(maxWidth: .infinity, minHeight: GraftMetrics.controlPrimary + 6)
                    .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
                    .overlay(
                        RoundedRectangle(cornerRadius: GraftMetrics.radius)
                            .stroke(Color.gHairline, lineWidth: GraftMetrics.border)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Grouping is deliberately not part of "reset": it is a way of
            // looking, not a way of narrowing, and losing it is a surprise.
            .disabled(!canReset)
        }
    }

    /// Grouping is deliberately not part of "reset": it is a way of looking, not
    /// a way of narrowing, and losing it is a surprise.
    private var canReset: Bool {
        query.badgeCount > 0 || query.hasSearch || query.sort != .manual || query.dir != .asc
    }

    // MARK: - Multi-select section
    //
    // Multi-value wherever the contract says multi-value: repeated params on
    // the wire, `IN (...)` on the server, a set here.

    @ViewBuilder
    private func multiSection(
        title: String,
        options: [FilterOption],
        selection: Binding<[String]>,
        dot: @escaping (String) -> Color? = { _ in nil }
    ) -> some View {
        GraftMultiChoiceRow(label: title, options: options,
                            selection: selection, dot: dot)
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
                        .font(GraftFont.text(GraftType.micro, .semibold))
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
