import SwiftUI

/// The issue screen, in the app's own surfaces rather than a stock Form.
///
/// Two things changed beyond looks. Edits used to sit in @State until you
/// tapped Save, so swiping back — the standard gesture on this screen — threw
/// them away silently; they now save as you go, with the state shown in the
/// bar. And `try? await` used to swallow failures, so a save that never
/// happened looked exactly like one that did.
///
/// The third thing is the state itself. "Saved", in green, with a tick, was
/// shown for an edit sitting in a queue against a server that could not be
/// reached — because `store.updateIssue` is local-first and cannot throw, so
/// the `.failed` branch was unreachable code and every write "succeeded". The
/// states below are read back out of the sync queue instead, and say which of
/// the four things actually happened.
struct IssueDetailView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let issue: GraftIssue

    @State private var title = ""
    @State private var description = ""
    @State private var assignee = ""
    @State private var labelsText = ""
    @State private var saveState: SaveState = .idle
    @State private var showDeleteConfirm = false
    @State private var undo: UndoAction?
    @State private var saveTask: Task<Void, Never>?
    /// True between an edit and the debounced save that writes it out.
    @State private var hasUnsavedEdits = false
    /// `onAppear` fires again on every return to this screen — from a sheet,
    /// from the background — and re-reading the store would overwrite whatever
    /// has been typed since.
    @State private var loaded = false

    enum SaveState: Equatable {
        case idle
        /// The write is being made locally.
        case saving
        /// Written, and no server is linked. This phone is where it lives.
        case savedLocally
        /// Written locally and sitting in the queue for a server that is not
        /// answering. Not the same thing as saved.
        case queued(Int)
        /// The server has it.
        case synced
        /// The queue gave up. This one is never going to be sent.
        case failed(String)
    }

    /// Where this issue's write lands in the queue.
    private var issuePath: String { "/api/issues/\(issue.id)" }

    private var current: GraftIssue {
        store.issues.first { $0.id == issue.id } ?? issue
    }

    private var projectMilestones: [GraftMilestone] {
        store.milestones.filter { $0.projectId == issue.projectId }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.gBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    titleField
                    descriptionField
                    statusPicker
                    properties
                    saveExplanation
                    metadata
                    Color.clear.frame(height: 88)
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.top, 12)
            }

            actionBar
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { saveIndicator }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete issue", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .onAppear {
            // Guarded: `onAppear` fires again on every return to this screen,
            // and re-reading the store would overwrite an in-progress edit that
            // has not hit the debounce yet.
            guard !loaded else { return }
            loaded = true
            load(current)
            // If a previous visit left a write stuck in the queue, say so on
            // arrival rather than waiting for the next edit. Only those two —
            // "saved on phone" on a screen nobody has edited is just noise.
            switch store.outcome(forPath: issuePath) {
            case .queued, .failed: refreshSaveState()
            case .localOnly, .synced: break
            }
        }
        .onDisappear { flushPendingSave() }
        .confirmationDialog("Delete this issue?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task { try? await store.deleteIssue(id: issue.id); dismiss() }
            }
            Button("Archive instead") { archive(); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Archiving keeps the issue and can be undone. Deleting cannot.")
        }
        .undoBanner($undo)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()

        case .saving:
            Text("Saving…")
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gInk2)

        case .savedLocally:
            Label("Saved on phone", systemImage: "iphone")
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gInk2)
                .accessibilityLabel("Saved on this phone. No server is linked.")

        case .synced:
            Label("Saved", systemImage: "checkmark")
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gAccentText)

        case .queued(let count):
            Button {
                Task { await store.flushPending(); refreshSaveState() }
            } label: {
                Label(count > 1 ? "Queued (\(count))" : "Queued",
                      systemImage: "arrow.up.circle")
                    .font(GraftFont.text(GraftType.secondary))
                    .foregroundStyle(Color.gAmber)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Waiting to sync. Tap to try now.")

        case .failed:
            Button {
                retrySave()
            } label: {
                Label("Retry", systemImage: "exclamationmark.triangle")
                    .font(GraftFont.text(GraftType.secondary))
                    .foregroundStyle(Color.gRed)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("This change was not saved to the server. Tap to retry.")
        }
    }

    /// The one-line explanation under the action bar, for the two states that
    /// genuinely need words rather than a glyph.
    @ViewBuilder
    private var saveExplanation: some View {
        switch saveState {
        case .queued:
            explanation(
                "Saved on this phone. Waiting for the server.",
                icon: "arrow.up.circle",
                tint: Color.gAmber
            )
        case .failed(let why):
            explanation(
                "Not saved to the server — \(why)",
                icon: "exclamationmark.triangle",
                tint: Color.gRed
            )
        default:
            EmptyView()
        }
    }

    private func explanation(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(GraftFont.text(GraftType.caption))
                .foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        .padding(.vertical, GraftMetrics.spaceXS)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
    }

    private var identity: some View {
        HStack(spacing: 8) {
            Text(issue.id.replacingOccurrences(of: "iss_", with: "#"))
                .font(GraftFont.mono(GraftType.caption))
                .foregroundStyle(Color.gInk2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: 5))
            if let project = store.project(issue.projectId) {
                Text(project.name)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
            }
            Spacer()
        }
    }

    private var titleField: some View {
        TextField("Issue title", text: $title, axis: .vertical)
            .font(GraftFont.text(24, .semibold))
            .foregroundStyle(Color.gInk)
            .textFieldStyle(.plain)
            .onChange(of: title) { _, _ in scheduleSave() }
    }

    private var descriptionField: some View {
        ZStack(alignment: .topLeading) {
            if description.isEmpty {
                Text("Add a description…")
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk3)
                    .padding(.top, 8)
                    .padding(.leading, 5)
            }
            TextEditor(text: $description)
                .font(GraftFont.text(GraftType.body))
                .foregroundStyle(Color.gInk2)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
                .onChange(of: description) { _, _ in scheduleSave() }
        }
    }

    /// Five tappable glyphs rather than a Picker that hides the current value
    /// behind a tap.
    private var statusPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Status")
            HStack(spacing: 6) {
                ForEach(IssueStatus.allCases, id: \.self) { status in
                    let selected = current.status == status.rawValue
                    Button {
                        setStatus(status.rawValue)
                    } label: {
                        VStack(spacing: GraftMetrics.spaceXXS) {
                            // The ring, not an SF Symbol: this is the one
                            // component that has to be identical to the web
                            // client, and a picker is where people learn it.
                            StatusRing(status: status, size: GraftMetrics.ring)
                            Text(status.label)
                                .font(GraftFont.text(GraftType.micro, selected ? .bold : .regular))
                                .foregroundStyle(selected ? status.color : Color.gInk2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap)
                        .background(selected ? status.color.opacity(0.14) : Color.gSurface2,
                                    in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                                .strokeBorder(selected ? status.color : Color.gHairline,
                                              lineWidth: GraftMetrics.border)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(status.label)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
    }

    private var properties: some View {
        VStack(spacing: 0) {
            propertyRow("Priority") {
                Menu {
                    ForEach(IssuePriority.allCases, id: \.self) { p in
                        Button(p.label) { setPriority(p.rawValue) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        let p = IssuePriority(rawValue: current.priority) ?? .normal
                        // The shape, not a symbol: priority reads by shape as
                        // well as colour everywhere else in the system.
                        PriorityDot(priority: p.rawValue, size: 12)
                        Text(p.label).font(GraftFont.text(GraftType.body))
                    }
                    .foregroundStyle((IssuePriority(rawValue: current.priority) ?? .normal).color)
                }
            }
            divider
            propertyRow("Milestone") {
                Menu {
                    Button("None") { setMilestone(nil) }
                    ForEach(projectMilestones) { m in
                        Button(m.name) { setMilestone(m.id) }
                    }
                } label: {
                    Text(store.milestone(current.milestoneId)?.name ?? "None")
                        .font(GraftFont.text(GraftType.body))
                        .foregroundStyle(current.milestoneId == nil ? Color.gInk2 : Color.gAccentText)
                }
            }
            divider
            propertyRow("Assignee") {
                TextField("Unassigned", text: $assignee)
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: assignee) { _, _ in scheduleSave() }
            }
            divider
            propertyRow("Labels") {
                TextField("bug, frontend", text: $labelsText)
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: labelsText) { _, _ in scheduleSave() }
            }
            // Labels were editable in two places and rendered nowhere. The
            // parsed result is shown back here as the chips that now appear on
            // every row, so what you typed and what the list will show are
            // visibly the same thing.
            if !current.labels.isEmpty {
                HStack(spacing: 5) {
                    ForEach(current.labels, id: \.self) { label in
                        GraftLabelChip(text: label)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, GraftMetrics.spaceS)
            }
        }
        .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: 0.5)
        )
    }

    private var metadata: some View {
        HStack(spacing: 14) {
            Text("Created \(GraftDate.relative(current.createdAt))")
            Text("Updated \(GraftDate.relative(current.updatedAt))")
            Spacer()
        }
        .font(GraftFont.text(GraftType.caption))
        .foregroundStyle(Color.gInk3)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                archive()
            } label: {
                Label(current.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    .font(GraftFont.text(GraftType.body, .semibold))
                    .foregroundStyle(Color.gInk2)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
            }
            .buttonStyle(.plain)

            Button {
                setStatus(current.status == "done" ? "todo" : "done")
            } label: {
                Label(current.status == "done" ? "Reopen" : "Mark done",
                      systemImage: current.status == "done" ? "arrow.uturn.backward" : "checkmark")
                    .font(GraftFont.text(GraftType.body, .bold))
                    .foregroundStyle(Color.gOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(current.status == "done" ? Color.gInk2 : Color.gAccent,
                                in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(GraftFont.text(12, .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.gInk2)
    }

    private var divider: some View {
        Rectangle().fill(Color.gHairline).frame(height: 0.5).padding(.leading, 14)
    }

    private func propertyRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(GraftFont.text(GraftType.body))
                .foregroundStyle(Color.gInk2)
                .frame(width: 88, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }

    private func load(_ i: GraftIssue) {
        title = i.title
        description = i.description
        assignee = i.assignee
        labelsText = i.labels.joined(separator: ", ")
    }

    /// Debounced so typing does not fire a request per keystroke.
    private func scheduleSave() {
        hasUnsavedEdits = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Leaving inside the debounce window used to cancel the timer outright,
    /// throwing the edit away silently — the very thing this screen was changed
    /// to stop doing. The write itself is an unstructured Task in `persist`, so
    /// it outlives the view.
    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedEdits else { return }
        save()
    }

    private func save() {
        hasUnsavedEdits = false
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var updated = current
        updated.title = title
        updated.description = description
        updated.assignee = assignee
        updated.labels = labelsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        persist(updated)
    }

    private func setStatus(_ status: String) {
        var updated = current
        updated.status = status
        persist(updated)
    }

    private func setPriority(_ priority: String) {
        var updated = current
        updated.priority = priority
        persist(updated)
    }

    private func setMilestone(_ id: String?) {
        var updated = current
        updated.milestoneId = id
        persist(updated)
    }

    private func persist(_ updated: GraftIssue) {
        Task {
            saveState = .saving
            // Deliberately not `do/catch`: this call is local-first and does
            // not fail in any way worth reporting. What matters is what the
            // queue did with it afterwards, which is what `outcome` reads.
            try? await store.updateIssue(updated)
            refreshSaveState()

            // The two good outcomes fade back to nothing; "queued" and "failed"
            // stay on screen, because they are still true.
            let shown = saveState
            if shown == .synced || shown == .savedLocally {
                try? await Task.sleep(for: .seconds(2))
                if saveState == shown { saveState = .idle }
            }
        }
    }

    private func refreshSaveState() {
        switch store.outcome(forPath: issuePath) {
        case .localOnly: saveState = .savedLocally
        case .queued(let count): saveState = .queued(count)
        case .synced: saveState = .synced
        case .failed(let why): saveState = .failed(why)
        }
    }

    /// Re-enqueues the write and forgets that this one was given up on, so the
    /// indicator can leave the failed state if the retry works.
    private func retrySave() {
        store.syncEngine.clearDropped(forPath: issuePath)
        hasUnsavedEdits = true
        save()
    }

    private func archive() {
        Task {
            // Captured first: `current` is a live lookup into the store, so
            // reading it after the toggle describes the new state and the
            // banner said the opposite of what just happened.
            let wasArchived = current.archived
            try? await store.archiveIssue(id: issue.id)
            undo = UndoAction(message: wasArchived ? "Issue unarchived" : "Issue archived") {
                try? await store.archiveIssue(id: issue.id)
            }
        }
    }
}
