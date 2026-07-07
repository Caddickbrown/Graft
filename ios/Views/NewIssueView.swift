import SwiftUI

struct NewIssueView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectId: String

    @State private var title = ""
    @State private var description = ""
    @State private var status = "backlog"
    @State private var priority = "normal"
    @State private var milestoneId = ""
    @State private var assignee = ""
    @State private var labelsText = ""
    @State private var isSaving = false

    let statuses = ["backlog", "todo", "in-progress", "review", "done"]
    let priorities = ["urgent", "high", "normal", "low"]

    var projectMilestones: [GraftMilestone] {
        store.milestones.filter { $0.projectId == projectId }
    }

    var projectName: String {
        store.projects.first { $0.id == projectId }?.name ?? "Project"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("Description (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $description)
                            .frame(minHeight: 80)
                    }
                }

                Section("Project") {
                    LabeledContent("Project", value: projectName)
                }

                Section("Status & Priority") {
                    Picker("Status", selection: $status) {
                        ForEach(statuses, id: \.self) { s in
                            Text(statusLabel(s)).tag(s)
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(priorities, id: \.self) { p in
                            Text(priorityLabel(p)).tag(p)
                        }
                    }
                }

                if !projectMilestones.isEmpty {
                    Section("Milestone") {
                        Picker("Milestone", selection: $milestoneId) {
                            Text("None").tag("")
                            ForEach(projectMilestones) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                    }
                }

                Section("Assignment") {
                    TextField("Assignee", text: $assignee)
                    TextField("Labels (comma-separated)", text: $labelsText)
                }
            }
            .navigationTitle("New issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(title.isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let labels = labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? await store.createIssue(
            projectId: projectId,
            title: title,
            description: description,
            status: status,
            priority: priority,
            milestoneId: milestoneId.isEmpty ? nil : milestoneId,
            assignee: assignee,
            labels: labels
        )
        dismiss()
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "backlog": return "Backlog"
        case "todo": return "To do"
        case "in-progress": return "In progress"
        case "review": return "Review"
        case "done": return "Done"
        default: return s
        }
    }

    private func priorityLabel(_ p: String) -> String {
        switch p {
        case "urgent": return "Urgent"
        case "high": return "High"
        case "normal": return "Normal"
        case "low": return "Low"
        default: return p
        }
    }
}
