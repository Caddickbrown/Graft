import SwiftUI

/// Creating an issue.
///
/// The project is a choice, not a given: the Inbox opens this sheet without any
/// project context, so a fixed, display-only project meant every issue created
/// from there was filed into whichever project happened to come back first.
///
/// Built from FormKit. It was a stock `Form` of five `Picker` rows, which is the
/// screen you hit most often in the app and the one that looked least like it —
/// status and priority in particular are colour-carrying ideas everywhere else
/// in Graft and were plain grey menu rows here.
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
    @FocusState private var focus: GraftFormField?

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

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !selectedProjectId.isEmpty
    }

    var body: some View {
        Group {
            if availableProjects.isEmpty {
                // The app's own empty state rather than the stock one, so this
                // sheet does not look like a different product from the screen
                // that opened it.
                NavigationStack {
                    GraftEmptyState(
                        title: "No projects yet",
                        subtitle: "Every issue lives in a project. Make one on the Projects tab first.",
                        systemImage: "leaf"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gBg)
                    .navigationTitle("New issue")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                                .font(GraftFont.text(GraftType.body))
                                .foregroundStyle(Color.gInk2)
                        }
                    }
                }
            } else {
                form
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            status = defaultStatus
            let opened = availableProjects.contains(where: { $0.id == projectId })
            selectedProjectId = opened ? projectId : (availableProjects.first?.id ?? "")
        }
        .disabled(isSaving)
        // Every create/edit sheet in the app used to lose in-progress text to a
        // swipe-down, with no warning and no way back.
        .interactiveDismissDisabled(hasDraft)
    }

    private var form: some View {
        GraftFormScaffold(
            title: "New issue",
            confirmLabel: "Add",
            confirmDisabled: !canSave,
            isBusy: isSaving,
            onCancel: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            GraftSection(title: "Details") {
                GraftTextField(label: "Title", placeholder: "What needs doing?",
                               text: $title, focused: $focus, field: .title)
                GraftRowDivider()
                GraftTextField(label: "Description", placeholder: "Optional",
                               text: $description, axis: .vertical, lineLimit: 3...8,
                               focused: $focus, field: .description)
            }

            GraftSection(title: "Project") {
                GraftMenuRow(
                    label: "Project",
                    options: availableProjects,
                    selection: Binding(
                        get: { selectedProjectId.isEmpty ? nil : selectedProjectId },
                        set: { selectedProjectId = $0 ?? "" }
                    ),
                    title: { $0.name },
                    emptyTitle: "Choose a project"
                )
                // Milestones belong to one project, so a selection made before
                // switching would attach the issue to a milestone in a project
                // it is no longer in.
                .onChange(of: selectedProjectId) { _, _ in milestoneId = "" }
            }

            GraftSection(title: "Status & priority") {
                GraftChoiceRow(label: "Status", options: statuses, selection: $status,
                               title: statusLabel,
                               dot: { IssueStatus(rawValue: $0)?.color })
                GraftRowDivider()
                GraftChoiceRow(label: "Priority", options: priorities, selection: $priority,
                               title: priorityLabel,
                               dot: { IssuePriority(rawValue: $0)?.color })
            }

            if !projectMilestones.isEmpty {
                GraftSection(title: "Milestone") {
                    GraftMenuRow(
                        label: "Milestone",
                        options: projectMilestones,
                        selection: Binding(
                            get: { milestoneId.isEmpty ? nil : milestoneId },
                            set: { milestoneId = $0 ?? "" }
                        ),
                        title: { $0.name },
                        emptyTitle: "None"
                    )
                }
            }

            GraftSection(title: "Assignment",
                         footnote: "Labels are comma-separated.") {
                GraftTextField(label: "Assignee", placeholder: "Optional",
                               text: $assignee, focused: $focus, field: .name)
                GraftRowDivider()
                GraftTextField(label: "Labels", placeholder: "design, backend",
                               text: $labelsText, focused: $focus, field: .label)
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
