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

    var milestones: [GraftMilestone] {
        store.milestones(for: projectId)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.gBg.ignoresSafeArea()

                if milestones.isEmpty {
                    GraftEmptyState(
                        title: "No milestones",
                        subtitle: "A milestone is a date a group of issues is aiming at. Add one and it shows up on every issue that joins it.",
                        systemImage: "flag",
                        actionTitle: "Add a milestone",
                        action: { showNewMilestone = true }
                    )
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
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .frame(minHeight: GraftMetrics.tap)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewMilestone = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("New milestone")
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
}

// MARK: - Milestone Row

struct MilestoneRowView: View {
    let milestone: GraftMilestone
    var issueCount: Int = 0

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
                    .font(.system(size: GraftType.title, weight: .medium))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.leading)

                if !milestone.description.isEmpty {
                    Text(milestone.description)
                        .font(.system(size: GraftType.secondary))
                        .foregroundStyle(Color.gInk2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: GraftMetrics.spaceXS) {
                    if let due {
                        Text(due)
                            .font(.system(size: GraftType.caption))
                            .foregroundStyle(overdue ? Color.gRed : Color.gInk2)
                    } else {
                        Text("no due date")
                            .font(.system(size: GraftType.caption))
                            .foregroundStyle(Color.gInk3)
                    }
                    Text("·")
                        .font(.system(size: GraftType.caption))
                        .foregroundStyle(Color.gInk3)
                    Text("\(issueCount) issue\(issueCount == 1 ? "" : "s")")
                        .font(.system(size: GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.gInk3)
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
        NavigationStack {
            Form {
                Section("Milestone details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Due date") {
                    Toggle("Set due date", isOn: $hasDueDate.animation())
                        .tint(Color.gAccent)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit milestone" : "New milestone")
            .navigationBarTitleDisplayMode(.inline)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
            // A swipe-down used to throw an in-progress milestone away without
            // a word. None of the app's sheets guarded against that.
            .interactiveDismissDisabled(hasDraft)
        }
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
