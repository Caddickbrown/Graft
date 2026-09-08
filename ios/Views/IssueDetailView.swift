import SwiftUI

/// The issue screen, in the app's own surfaces rather than a stock Form.
///
/// Two things changed beyond looks. Edits used to sit in @State until you
/// tapped Save, so swiping back — the standard gesture on this screen — threw
/// them away silently; they now save as you go, with the state shown in the
/// bar. And `try? await` used to swallow failures, so a save that never
/// happened looked exactly like one that did.
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

    enum SaveState: Equatable { case idle, saving, saved, failed }

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
        .onAppear { load(current) }
        .onDisappear { saveTask?.cancel() }
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

    private var saveIndicator: some View {
        Group {
            switch saveState {
            case .idle:
                EmptyView()
            case .saving:
                Text("Saving…")
                    .font(.system(size: GraftType.secondary))
                    .foregroundStyle(Color.gMuted)
            case .saved:
                Label("Saved", systemImage: "checkmark")
                    .font(.system(size: GraftType.secondary))
                    .foregroundStyle(Color.gTeal)
            case .failed:
                Button {
                    save()
                } label: {
                    Label("Retry", systemImage: "exclamationmark.triangle")
                        .font(.system(size: GraftType.secondary))
                        .foregroundStyle(Color.gRed)
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            Text(issue.id.replacingOccurrences(of: "iss_", with: "#"))
                .font(.system(size: GraftType.caption, design: .monospaced))
                .foregroundStyle(Color.gMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: 5))
            if let project = store.project(issue.projectId) {
                Text(project.name)
                    .font(.system(size: GraftType.caption))
                    .foregroundStyle(Color.gMuted)
            }
            Spacer()
        }
    }

    private var titleField: some View {
        TextField("Issue title", text: $title, axis: .vertical)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(Color.gInk)
            .textFieldStyle(.plain)
            .onChange(of: title) { _, _ in scheduleSave() }
    }

    private var descriptionField: some View {
        ZStack(alignment: .topLeading) {
            if description.isEmpty {
                Text("Add a description…")
                    .font(.system(size: GraftType.body))
                    .foregroundStyle(Color.gFaint)
                    .padding(.top, 8)
                    .padding(.leading, 5)
            }
            TextEditor(text: $description)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gMuted)
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
                        VStack(spacing: 4) {
                            Image(systemName: status.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(status.color)
                            Text(status.label)
                                .font(.system(size: 10, weight: selected ? .bold : .regular))
                                .foregroundStyle(selected ? status.color : Color.gMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap)
                        .background(selected ? status.color.opacity(0.14) : Color.gSurface2,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected ? status.color : Color.gHairline,
                                              lineWidth: selected ? 1 : 0.5)
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
                        Image(systemName: p.icon).font(.system(size: 13))
                        Text(p.label).font(.system(size: GraftType.body))
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
                        .font(.system(size: GraftType.body))
                        .foregroundStyle(current.milestoneId == nil ? Color.gMuted : Color.gSage)
                }
            }
            divider
            propertyRow("Assignee") {
                TextField("Unassigned", text: $assignee)
                    .font(.system(size: GraftType.body))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: assignee) { _, _ in scheduleSave() }
            }
            divider
            propertyRow("Labels") {
                TextField("bug, frontend", text: $labelsText)
                    .font(.system(size: GraftType.body))
                    .foregroundStyle(Color.gInk)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: labelsText) { _, _ in scheduleSave() }
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
        .font(.system(size: GraftType.caption))
        .foregroundStyle(Color.gFaint)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                archive()
            } label: {
                Label(current.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    .font(.system(size: GraftType.body, weight: .semibold))
                    .foregroundStyle(Color.gMuted)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
            }
            .buttonStyle(.plain)

            Button {
                setStatus(current.status == "done" ? "todo" : "done")
            } label: {
                Label(current.status == "done" ? "Reopen" : "Mark done",
                      systemImage: current.status == "done" ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: GraftType.body, weight: .bold))
                    .foregroundStyle(Color.gOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(current.status == "done" ? Color.gMuted : Color.gTeal,
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
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.gMuted)
    }

    private var divider: some View {
        Rectangle().fill(Color.gHairline).frame(height: 0.5).padding(.leading, 14)
    }

    private func propertyRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gMuted)
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
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
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
            do {
                try await store.updateIssue(updated)
                saveState = .saved
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = .idle }
            } catch {
                saveState = .failed
            }
        }
    }

    private func archive() {
        Task {
            try? await store.archiveIssue(id: issue.id)
            undo = UndoAction(message: current.archived ? "Issue unarchived" : "Issue archived") {
                try? await store.archiveIssue(id: issue.id)
            }
        }
    }
}
