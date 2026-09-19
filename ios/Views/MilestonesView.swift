import SwiftUI

/// Milestones for one project.
///
/// This screen was the odd one out: the only `.insetGrouped` list in the app,
/// the only one using stock `.body`/`.caption2` type and `.primary`/`.secondary`
/// colours, and the only one showing a raw stored `"2026-03-14"` where every
/// other surface runs a date through `GraftDate.dueLabel`. It looked like a
/// different app, so it is built out of the same pieces as the rest now.
struct MilestonesView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectId: String

    @State private var showNewMilestone = false
    @State private var editingMilestone: GraftMilestone? = nil
    @State private var pendingDelete: GraftMilestone? = nil
    /// Drag-to-reorder is a mode rather than always-on, because the rows are
    /// buttons: a long press has to be able to mean "open this one" as well as
    /// "pick this one up", and on a list of three items being able to open one
    /// matters more.
    @State private var reordering = false

    var milestones: [GraftMilestone] {
        store.milestones(for: projectId)
    }

    var body: some View {
        GraftSheetScaffold(
            title: "Milestones",
            trailingAccessory: AnyView(
                HStack(spacing: GraftMetrics.spaceXXS) {
                    if milestones.count > 1 {
                        GraftIconButton(
                            systemImage: reordering ? "checkmark" : "arrow.up.arrow.down",
                            tint: reordering ? Color.gAccentText : Color.gInk2,
                            accessibilityTitle: reordering ? "Done reordering" : "Reorder milestones"
                        ) {
                            withAnimation(.snappy(duration: 0.2)) { reordering.toggle() }
                        }
                    }
                    if !reordering {
                        GraftIconButton(systemImage: "plus",
                                        tint: Color.gAccentText,
                                        accessibilityTitle: "New milestone") {
                            showNewMilestone = true
                        }
                    }
                }
            ),
            onDone: { dismiss() }
        ) {
            ZStack {
                Color.gBg

                if milestones.isEmpty {
                    GraftEmptyState(
                        title: "No milestones",
                        subtitle: "A milestone is a date a group of issues is aiming at. Add one and it shows up on every issue that joins it.",
                        systemImage: "flag",
                        actionTitle: "Add a milestone",
                        action: { showNewMilestone = true }
                    )
                } else if reordering {
                    reorderList
                } else {
                    ScrollView {
                        LazyVStack(spacing: GraftMetrics.spaceXS) {
                            ForEach(milestones) { milestone in
                                Button {
                                    editingMilestone = milestone
                                } label: {
                                    MilestoneRowView(
                                        milestone: milestone,
                                        issueCount: store.issueCount(usingMilestone: milestone.id)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        editingMilestone = milestone
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = milestone
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, GraftMetrics.gutter)
                        .padding(.vertical, GraftMetrics.spaceS)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .sheet(isPresented: $showNewMilestone) {
                MilestoneFormView(projectId: projectId, milestone: nil)
            }
            .sheet(item: $editingMilestone) { milestone in
                MilestoneFormView(projectId: projectId, milestone: milestone)
            }
            // Deleting a milestone was one swipe, unconfirmed, un-undoable, and
            // it cascades: every issue using it loses it. It was the only
            // destructive action in the app with no confirmation at all, and
            // the web client has always named the affected issue count.
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete milestone?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let milestone = pendingDelete {
                    let count = store.issueCount(usingMilestone: milestone.id)
                    Button(count == 0
                           ? "Delete milestone"
                           : "Delete and unlink \(count) issue\(count == 1 ? "" : "s")",
                           role: .destructive) {
                        Task { try? await store.deleteMilestone(id: milestone.id) }
                        pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let milestone = pendingDelete {
                    let count = store.issueCount(usingMilestone: milestone.id)
                    Text(count == 0
                         ? "Nothing is using this milestone. This cannot be undone."
                         : "\(count) issue\(count == 1 ? "" : "s") will lose this milestone. The issues themselves are kept. This cannot be undone.")
                }
            }
        }
    }

    // MARK: - Reorder mode

    /// A `List` purely for `.onMove` — it is the only thing in SwiftUI that
    /// does drag-to-reorder, and the rest of this screen is a `LazyVStack`
    /// because the rows are buttons. Styled back down to the app's own surfaces
    /// so swapping between the two modes does not look like swapping apps.
    private var reorderList: some View {
        VStack(spacing: 0) {
            Text("Drag to set the order milestones appear in, here and on the project.")
                .font(GraftFont.text(GraftType.caption))
                .foregroundStyle(Color.gInk2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.spaceXS)

            List {
                ForEach(milestones) { milestone in
                    MilestoneRowView(
                        milestone: milestone,
                        issueCount: store.issueCount(usingMilestone: milestone.id),
                        showsChevron: false
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Always editing: there is no second mode inside this one, and an
            // Edit button to reach the grabbers would be a mode within a mode.
            .environment(\.editMode, .constant(.active))
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = milestones.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        // Written through straight away rather than on leaving the mode: the
        // sheet can be swiped away at any point, and a drag that was not saved
        // because of how you left the screen is the worst kind of lost work.
        Task { try? await store.reorderMilestones(projectId: projectId, orderedIds: ids) }
    }
}

// MARK: - Milestone Row

struct MilestoneRowView: View {
    let milestone: GraftMilestone
    var issueCount: Int = 0
    /// Off in reorder mode: the row does not open anything while it is being
    /// dragged, and a chevron promising otherwise is a lie in a small space.
    var showsChevron: Bool = true

    var body: some View {
        // Through `dueLabel`, like every other surface in the app — this was
        // the one place that printed the stored "2026-03-14" at the reader.
        let due = GraftDate.dueLabel(milestone.dueDate)
        let overdue = (due?.contains("overdue")) == true

        HStack(spacing: GraftMetrics.spaceS) {
            Image(systemName: "flag.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.gInk2)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS) {
                Text(milestone.name)
                    .font(GraftFont.text(GraftType.title, .medium))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.leading)

                if !milestone.description.isEmpty {
                    Text(milestone.description)
                        .font(GraftFont.text(GraftType.secondary))
                        .foregroundStyle(Color.gInk2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: GraftMetrics.spaceXS) {
                    if let due {
                        Text(due)
                            .font(GraftFont.text(GraftType.caption))
                            .foregroundStyle(overdue ? Color.gRed : Color.gInk2)
                    } else {
                        Text("no due date")
                            .font(GraftFont.text(GraftType.caption))
                            .foregroundStyle(Color.gInk3)
                    }
                    Text("·")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk3)
                    Text("\(issueCount) issue\(issueCount == 1 ? "" : "s")")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                }
            }

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
            }
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        .padding(.vertical, GraftMetrics.spaceS)
        .frame(minHeight: GraftMetrics.tap)
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }
}

// MARK: - Milestone Form

struct MilestoneFormView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectId: String
    let milestone: GraftMilestone?

    @State private var name = ""
    @State private var description = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false
    @State private var loaded = false
    @FocusState private var focus: GraftFormField?

    var isEditing: Bool { milestone != nil }

    /// Whether there is anything in here worth not throwing away on a swipe.
    private var hasDraft: Bool {
        if isEditing {
            guard let milestone else { return false }
            let due: String? = hasDueDate ? GraftDate.dayString(from: dueDate) : nil
            return name != milestone.name
                || description != milestone.description
                || due != milestone.dueDate
        }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            || !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GraftFormScaffold(
            title: isEditing ? "Edit milestone" : "New milestone",
            confirmLabel: isEditing ? "Save" : "Add",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            onCancel: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            GraftSection(title: "Milestone details") {
                GraftTextField(label: "Name", placeholder: "What is the milestone?",
                               text: $name, focused: $focus, field: .name)
                GraftRowDivider()
                GraftTextField(label: "Description", placeholder: "Optional",
                               text: $description, axis: .vertical, lineLimit: 3...6,
                               focused: $focus, field: .description)
            }

            GraftSection(title: "Due date") {
                GraftToggleRow(label: "Set due date", isOn: $hasDueDate.animation())
                if hasDueDate {
                    GraftRowDivider()
                    // The wheel itself stays the system's — it is a good control
                    // and nobody gains from a hand-rolled calendar.
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .font(GraftFont.text(GraftType.body))
                        .foregroundStyle(Color.gInk)
                        .tint(Color.gAccent)
                        .frame(minHeight: GraftMetrics.tap)
                }
            }
        }
            .onAppear {
                // Guarded: re-hydrating on a second `onAppear` would discard
                // whatever has been typed since the first one.
                guard !loaded else { return }
                loaded = true
                if let m = milestone {
                    name = m.name
                    description = m.description
                    // Read in the local calendar, the same one `save()` writes
                    // in. Reading UTC midnight and writing local time moved the
                    // date a day earlier at negative offsets, every save.
                    if let due = m.dueDate, !due.isEmpty,
                       let parsed = GraftDate.day(from: due) {
                        hasDueDate = true
                        dueDate = parsed
                    }
                }
            }
        .disabled(isSaving)
        // A swipe-down used to throw an in-progress milestone away without a
        // word. None of the app's sheets guarded against that.
        .interactiveDismissDisabled(hasDraft)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let due: String? = hasDueDate ? GraftDate.dayString(from: dueDate) : nil

        if var existing = milestone {
            existing.name = name
            existing.description = description
            existing.dueDate = due
            try? await store.updateMilestone(existing)
        } else {
            try? await store.createMilestone(projectId: projectId, name: name, description: description, dueDate: due)
        }
        dismiss()
    }
}
