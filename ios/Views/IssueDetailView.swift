import SwiftUI

struct IssueDetailView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let issue: GraftIssue

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var status: String = ""
    @State private var priority: String = ""
    @State private var milestoneId: String = ""
    @State private var assignee: String = ""
    @State private var labelsText: String = ""
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    var currentIssue: GraftIssue {
        store.issues.first { $0.id == issue.id } ?? issue
    }

    var projectMilestones: [GraftMilestone] {
        store.milestones.filter { $0.projectId == issue.projectId }
    }

    let statuses = ["backlog", "todo", "in-progress", "review", "done"]
    let priorities = ["urgent", "high", "normal", "low"]

    var body: some View {
        Form {
            // Title & Description
            Section("Details") {
                TextField("Title", text: $title)
                    .font(.body)

                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Description")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                }
            }

            // Status & Priority
            Section("Status & Priority") {
                Picker("Status", selection: $status) {
                    ForEach(statuses, id: \.self) { s in
                        Text(statusLabel(s)).tag(s)
                    }
                }

                Picker("Priority", selection: $priority) {
                    ForEach(priorities, id: \.self) { p in
                        HStack {
                            Circle()
                                .fill(priorityColor(p))
                                .frame(width: 8, height: 8)
                            Text(priorityLabel(p))
                        }
                        .tag(p)
                    }
                }
            }

            // Milestone
            Section("Milestone") {
                Picker("Milestone", selection: $milestoneId) {
                    Text("None").tag("")
                    ForEach(projectMilestones) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }

            // Assignee & Labels
            Section("Assignment") {
                HStack {
                    Label("Assignee", systemImage: "person")
                    Spacer()
                    TextField("Assignee", text: $assignee)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Labels", systemImage: "tag")
                    Spacer()
                    TextField("label1, label2", text: $labelsText)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            }

            // Metadata
            Section("Info") {
                LabeledContent("Created", value: formatDate(currentIssue.createdAt))
                LabeledContent("Updated", value: formatDate(currentIssue.updatedAt))
                LabeledContent("Project", value: store.projects.first { $0.id == issue.projectId }?.name ?? issue.projectId)
            }

            // Delete
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Delete issue", systemImage: "trash")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(title.isEmpty ? "Issue" : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isSaving || title.isEmpty)
            }
        }
        .onAppear {
            loadFromIssue(currentIssue)
        }
        .disabled(isSaving)
        .confirmationDialog("Delete this issue?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await store.deleteIssue(id: issue.id)
                    dismiss()
                }
            }
        }
    }

    private func loadFromIssue(_ i: GraftIssue) {
        title = i.title
        description = i.description
        status = i.status
        priority = i.priority
        milestoneId = i.milestoneId ?? ""
        assignee = i.assignee
        labelsText = i.labels.joined(separator: ", ")
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var updated = currentIssue
        updated.title = title
        updated.description = description
        updated.status = status
        updated.priority = priority
        updated.milestoneId = milestoneId.isEmpty ? nil : milestoneId
        updated.assignee = assignee
        updated.labels = labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? await store.updateIssue(updated)
    }

    private func formatDate(_ str: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: str) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return str
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

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "urgent": return Color(hex: "#ef4444")
        case "high": return Color(hex: "#f97316")
        case "normal": return .secondary
        case "low": return .gray.opacity(0.4)
        default: return .secondary
        }
    }
}
