import SwiftUI

/// Creating an issue.
///
/// The project is a choice, not a given: the Inbox opens this sheet without any
/// project context, so a fixed, display-only project meant every issue created
/// from there was filed into whichever project happened to come back first.
struct NewIssueView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The project to start on — the one the sheet was opened from. Empty when
    /// there is no context to go on, as from the Inbox.
    let projectId: String
    var defaultStatus: String = "backlog"

    @State private var title = ""
    @State private var description = ""
    @State private var status = "backlog"
    @State private var priority = "normal"
    @State private var selectedProjectId = ""
    @State private var milestoneId = ""
    @State private var assignee = ""
    @State private var labelsText = ""
    @State private var isSaving = false
    /// `onAppear` fires again whenever the sheet comes back to the front, and
    /// re-seeding would move the issue to a different project mid-edit.
    @State private var loaded = false

    let statuses = ["backlog", "todo", "in-progress", "review", "done"]
    let priorities = ["urgent", "high", "normal", "low"]

    /// Anything typed is worth protecting from an accidental swipe-down.
    private var hasDraft: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !description.trimmingCharacters(in: .whitespaces).isEmpty
            || !assignee.trimmingCharacters(in: .whitespaces).isEmpty
            || !labelsText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Archived projects are not somewhere new work should land — but if we were
    /// opened from one, it stays offered rather than silently moving the issue.
    var availableProjects: [GraftProject] {
        store.projects.filter { !$0.archived || $0.id == projectId }
    }

    var projectMilestones: [GraftMilestone] {
        store.milestones.filter { $0.projectId == selectedProjectId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableProjects.isEmpty {
                    // The app's own empty state rather than the stock one, so
                    // this sheet does not look like a different product from
                    // the screen that opened it.
                    GraftEmptyState(
                        title: "No projects yet",
                        subtitle: "Every issue lives in a project. Make one on the Projects tab first.",
                        systemImage: "leaf"
                    )
                } else {
                    form
                }
            }
            .navigationTitle("New issue")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                status = defaultStatus
                let opened = availableProjects.contains(where: { $0.id == projectId })
                selectedProjectId = opened ? projectId : (availableProjects.first?.id ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(title.isEmpty || selectedProjectId.isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
            // Every create/edit sheet in the app used to lose in-progress text
            // to a swipe-down, with no warning and no way back.
            .interactiveDismissDisabled(hasDraft)
        }
    }

    private var form: some View {
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
                Picker("Project", selection: $selectedProjectId) {
                    ForEach(availableProjects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                // Milestones belong to one project, so a selection made before
                // switching would attach the issue to a milestone in a project
                // it is no longer in.
                .onChange(of: selectedProjectId) { _, _ in milestoneId = "" }
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
    }

    private func save() async {
        guard !selectedProjectId.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        let labels = labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? await store.createIssue(
            projectId: selectedProjectId,
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

    /// Through the design system rather than a third hand-written copy of the
    /// same switch — this one said "To do" where the rest of both clients say
    /// "Todo".
    private func statusLabel(_ s: String) -> String {
        IssueStatus(rawValue: s)?.label ?? s
    }

    private func priorityLabel(_ p: String) -> String {
        IssuePriority(rawValue: p)?.label ?? p
    }
}
