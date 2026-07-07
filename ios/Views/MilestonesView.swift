import SwiftUI

struct MilestonesView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectId: String

    @State private var showNewMilestone = false
    @State private var editingMilestone: GraftMilestone? = nil

    var milestones: [GraftMilestone] {
        store.milestones(for: projectId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if milestones.isEmpty {
                    ContentUnavailableView(
                        "No milestones",
                        systemImage: "flag",
                        description: Text("Tap + to add a milestone")
                    )
                } else {
                    List {
                        ForEach(milestones) { milestone in
                            Button {
                                editingMilestone = milestone
                            } label: {
                                MilestoneRowView(milestone: milestone)
                            }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { try? await store.deleteMilestone(id: milestone.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Milestones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewMilestone = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewMilestone) {
                MilestoneFormView(projectId: projectId, milestone: nil)
            }
            .sheet(item: $editingMilestone) { milestone in
                MilestoneFormView(projectId: projectId, milestone: milestone)
            }
        }
    }
}

// MARK: - Milestone Row

struct MilestoneRowView: View {
    let milestone: GraftMilestone

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.fill")
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text(milestone.name)
                    .font(.body)
                    .fontWeight(.medium)

                if !milestone.description.isEmpty {
                    Text(milestone.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let due = milestone.dueDate, !due.isEmpty {
                    Label(due, systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
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
    @State private var dueDate = ""
    @State private var isSaving = false

    var isEditing: Bool { milestone != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Milestone details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Due date") {
                    TextField("YYYY-MM-DD (optional)", text: $dueDate)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
            .navigationTitle(isEditing ? "Edit milestone" : "New milestone")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let m = milestone {
                    name = m.name
                    description = m.description
                    dueDate = m.dueDate ?? ""
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
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let due = dueDate.isEmpty ? nil : dueDate

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
