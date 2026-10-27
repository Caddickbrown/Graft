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
    /// `""` for "no date" — what the server stores and what an empty date input
    /// sends. See `GraftDateRow` for why this is a string and not a `Date`.
    @State private var startAt = ""
    @State private var dueAt = ""
    @State private var recurrence = ""
    @State private var recurrenceAnchor = RecurrenceAnchor.schedule.rawValue
    @State private var isSaving = false
    /// `onAppear` fires again whenever the sheet comes back to the front, and
    /// re-seeding would move the issue to a different project mid-edit.
    @State private var loaded = false
    @FocusState private var focus: GraftFormField?

    /// Anything typed is worth protecting from an accidental swipe-down.
    private var hasDraft: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !description.trimmingCharacters(in: .whitespaces).isEmpty
            || !assignee.trimmingCharacters(in: .whitespaces).isEmpty
            || !labelsText.trimmingCharacters(in: .whitespaces).isEmpty
            || !startAt.isEmpty || !dueAt.isEmpty || !recurrence.isEmpty
    }

    /// Archived projects are not somewhere new work should land — but if we were
    /// opened from one, it stays offered rather than silently moving the issue.
    var availableProjects: [GraftProject] {
        store.projects.filter { !$0.archived || $0.id == projectId }
    }

    var projectMilestones: [GraftMilestone] {
        store.milestones(for: selectedProjectId)
    }

    /// The form as the monitor draws it.
    private var draft: ExternalDraft {
        let field: String? = switch focus {
        case .title: "title"
        case .description: "description"
        case .name: "assignee"
        case .label: "labels"
        default: nil
        }
        return ExternalDraft(title: title, description: description, projectId: selectedProjectId,
                             status: status, priority: priority, dueAt: dueAt, assignee: assignee,
                             labels: labelsText, field: field, noProjects: availableProjects.isEmpty)
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
                GraftSheetScaffold(title: "New issue", doneLabel: "Cancel",
                                   onDone: { dismiss() }) {
                    GraftEmptyState(
                        title: "No projects yet",
                        subtitle: "Every issue lives in a project. Make one on the Projects tab first.",
                        systemImage: "leaf"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Typing straight away is the point of pressing `n` on a keyboard.
            // Without one, the form opens as it always did, with nothing
            // popping up over it.
            if graftHardwareKeyboardAttached {
                // After the sheet has finished arriving; set during the
                // presentation, focus does not take.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    focus = .title
                }
            }
        }
        .disabled(isSaving)
        // With a monitor, the form is drawn there as it is typed, and the
        // choices below have keys, so an issue can be made without looking at
        // the phone. Return in the title adds it; ⌘↵ and esc are the header's.
        .onAppear { ExternalDisplayModel.shared.presentSheet(.newIssue(draft)) }
        .onChange(of: draft) { _, new in ExternalDisplayModel.shared.presentSheet(.newIssue(new)) }
        .onDisappear { ExternalDisplayModel.shared.dismissSheet() }
        .background { keyChoices }
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
                    .onSubmit { if canSave { Task { await save() } } }
                GraftRowDivider()
                GraftTextField(label: "Description", placeholder: "Optional",
                               text: $description, axis: .vertical, lineLimit: 3...8,
                               focused: $focus, field: .description)
                GraftRowDivider()
                // A due date at the point of capture. The full Start/Due/Repeat
                // controls are still in Schedule below and share this binding —
                // this is the shortcut, not a second source of truth.
                GraftQuickDateRow(value: $dueAt)
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

            // The same two pickers the issue screen uses. These were
            // `GraftChoiceRow` capsules with a plain coloured dot, which taught
            // the colour of a status or a priority but not its shape — and the
            // shape is what the rings and the priority marks are read by on
            // every row, card and chip in both clients. Learning them on the
            // screen where you first set them is the point.
            GraftSection(title: "Status & priority") {
                GraftStatusPicker(selection: $status)
                GraftRowDivider()
                GraftPriorityPicker(selection: $priority)
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

            GraftSection(title: "Schedule",
                         footnote: "Due is the same date as the one at the top. Leave both empty and the issue simply has no deadline — an issue with no due date is never overdue.") {
                GraftDateRow(label: "Start", value: $startAt)
                GraftRowDivider()
                GraftDateRow(label: "Due", value: $dueAt)
            }

            GraftSection(title: "Repeat") {
                RecurrenceEditor(rule: $recurrence, anchor: $recurrenceAnchor)
            }

            GraftSection(title: "Assignment",
                         footnote: "Labels are comma-separated.") {
                GraftTextField(label: "Assignee", placeholder: "Optional",
                               text: $assignee, focused: $focus, field: .name)
                GraftRowDivider()
                GraftTextField(label: "Labels", placeholder: "design, backend",
                               text: $labelsText, focused: $focus, field: .label)
                GraftTokenSuggestions(text: $labelsText,
                                      vocabulary: store.issueLabelVocabulary)
            }
        }
    }

    /// Keys for the choices that are not text, so they can be made while
    /// typing: ⌘[ ⌘] status, ⌘P priority, ⌘O project, ⌘D due. Buttons with
    /// shortcuts rather than key commands, because a focused text field is
    /// first responder, and only shortcuts inside the sheet reach past it.
    private var keyChoices: some View {
        Group {
            Button("") { status = IssueStatus.step(status, by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("") { status = IssueStatus.step(status, by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("") { priority = IssuePriority.next(after: priority) }
                .keyboardShortcut("p", modifiers: .command)
            Button("") {
                let ids = availableProjects.map(\.id)
                guard !ids.isEmpty else { return }
                let i = ids.firstIndex(of: selectedProjectId) ?? -1
                selectedProjectId = ids[(i + 1) % ids.count]
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("") { dueAt = Self.nextDue(after: dueAt) }
                .keyboardShortcut("d", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// None → today → tomorrow → a week today → none, the quick date row's
    /// three presets. A date set some other way goes back to none.
    static func nextDue(after current: String) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        let presets = [0, 1, 7].compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
            .map { GraftDate.dayString(from: $0) }
        if current.isEmpty { return presets[0] }
        guard let i = presets.firstIndex(of: current), i + 1 < presets.count else { return "" }
        return presets[i + 1]
    }

    private func save() async {
        guard !selectedProjectId.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        // `uniqued`: "bug, bug" is one label, and two of them would share a
        // `ForEach` identity everywhere the chips are drawn.
        let labels = labelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.uniqued
        try? await store.createIssue(
            projectId: selectedProjectId,
            title: title,
            description: description,
            status: status,
            priority: priority,
            milestoneId: milestoneId.isEmpty ? nil : milestoneId,
            assignee: assignee,
            labels: labels,
            startAt: startAt,
            dueAt: dueAt,
            recurrence: recurrence,
            recurrenceAnchor: recurrenceAnchor
        )
        dismiss()
    }
}
