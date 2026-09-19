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
    /// `""` for "no date". See `GraftDateRow` for why these are strings and not
    /// `Date`s — `DatePicker` has no empty, and defaulting to today would give
    /// every issue a deadline it was never given.
    @State private var startAt = ""
    @State private var dueAt = ""
    @State private var recurrence = ""
    @State private var recurrenceAnchor = RecurrenceAnchor.schedule.rawValue
    /// Set when completing this issue made the server spawn its replacement.
    /// Worth saying out loud: the one just ticked off is now archived, and
    /// without a word about it the completion reads as the issue vanishing.
    @State private var spawned: GraftIssue?
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
    /// True while `load` is filling the eight fields below out of the store.
    /// Every one of them has an `onChange` that schedules a save, so without
    /// this simply opening an issue queued a PUT: `updated_at` moved, the issue
    /// jumped to the top of every "last updated" list, and the bar said "Saved"
    /// for an edit nobody made. The same guard the project, link and milestone
    /// forms use, under the name they use for it.
    @State private var hydrating = false

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
        store.milestones(for: issue.projectId)
    }

    /// Where back goes — named, because a chevron on its own says nothing about
    /// what you are returning to.
    private var backLabel: String {
        store.project(current.projectId)?.name ?? "Back"
    }

    var body: some View {
        VStack(spacing: 0) {
            GraftScreenHeader(title: "",
                              titleView: AnyView(EmptyView()),
                              leading: {
                                  GraftBackButton(label: backLabel) { dismiss() }
                              },
                              actions: {
                                  saveIndicator
                                  Menu {
                                      Button(role: .destructive) {
                                          showDeleteConfirm = true
                                      } label: {
                                          Label("Delete issue", systemImage: "trash")
                                      }
                                  } label: {
                                      Image(systemName: "ellipsis")
                                          .font(.system(size: 15, weight: .medium))
                                          .foregroundStyle(Color.gInk2)
                                          .frame(width: GraftMetrics.control, height: GraftMetrics.control)
                                          .background(Color.gSurface2,
                                                      in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                                          .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                          .contentShape(Rectangle())
                                  }
                                  .accessibilityLabel("More actions")
                              })

            ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    titleField
                    descriptionField
                    statusPicker
                    spawnNotice
                    properties
                    schedule
                    links
                    saveExplanation
                    metadata
                    Color.clear.frame(height: 88)
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.top, 12)
            }

            actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Guarded: `onAppear` fires again on every return to this screen,
            // and re-reading the store would overwrite an in-progress edit that
            // has not hit the debounce yet.
            guard !loaded else { return }
            loaded = true
            hydrating = true
            load(current)
            // Cleared on the next turn rather than at the end of `load`: the
            // `onChange` handlers see the new values when SwiftUI processes this
            // update, which is after this closure has returned. `save` checks
            // the rebuilt issue against the stored one as well, so a phone that
            // orders the two differently still writes nothing.
            Task { hydrating = false }
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

    /// One glyph in a slot that is always the same size.
    ///
    /// This used to be a row of *words* that changed on every edit — "Saving…",
    /// then "✓ Saved", then nothing two seconds later — and each change resized
    /// the item next to it, so the top-right corner of the screen twitched all
    /// the way through typing a title. The slot is now a fixed 34pt square
    /// whatever the state, the states cross-fade rather than swapping, and the
    /// sentence that used to be up here is left to `saveExplanation`, which
    /// says it properly under the action bar and does not move anything.
    private var saveIndicator: some View {
        ZStack {
            switch saveState {
            case .idle, .saving:
                // Deliberately nothing. A local write takes milliseconds, and a
                // spinner you can only ever catch a frame of is itself a flicker.
                Color.clear

            case .savedLocally:
                Image(systemName: "iphone")
                    .foregroundStyle(Color.gInk2)
                    .accessibilityLabel("Saved on this phone. No server is linked.")

            case .synced:
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.gAccentText)
                    .accessibilityLabel("Saved to the server.")

            case .queued:
                Button {
                    Task { await store.flushPending(); refreshSaveState() }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(Color.gAmber)
                        .frame(width: GraftMetrics.control, height: GraftMetrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Waiting to sync. Tap to try now.")

            case .failed:
                Button {
                    retrySave()
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.gRed)
                        .frame(width: GraftMetrics.control, height: GraftMetrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("This change was not saved to the server. Tap to retry.")
            }
        }
        .font(.system(size: 15, weight: .medium))
        .frame(width: GraftMetrics.control, height: GraftMetrics.control)
        .animation(.easeInOut(duration: 0.25), value: saveState)
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
            // Under the row rather than beside it: the field here is right-
            // aligned in a property row with no room for anything else, and a
            // suggestion you cannot read is not a suggestion.
            GraftTokenSuggestions(text: $labelsText,
                                  vocabulary: store.issueLabelVocabulary,
                                  showsWhenEmpty: false)
                .padding(.horizontal, 14)
            // Labels were editable in two places and rendered nowhere. The
            // parsed result is shown back here as the chips that now appear on
            // every row, so what you typed and what the list will show are
            // visibly the same thing.
            // `uniqued` because an issue written elsewhere can carry the same
            // label twice, and `id: \.self` would then hand two chips one
            // identity.
            if !current.labels.isEmpty {
                HStack(spacing: 5) {
                    ForEach(current.labels.uniqued, id: \.self) { label in
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

    /// What this issue is connected to — the PR that closes it, the document it
    /// came out of, the person it is about.
    ///
    /// This is the thing the tracker Graft replaced was genuinely good at, and
    /// the reason links stopped being project-only: "the PR that closes this"
    /// belongs to the issue, not to everything the issue is filed under.
    ///
    /// `insetByGutter: false` — the stack around it is already padded, and the
    /// section's own gutter on top of that reads as a stray indent.
    private var links: some View {
        GraftLinksSection(ownerType: "issue", ownerId: issue.id, insetByGutter: false)
    }

    // MARK: - Schedule
    //
    // Dates and the repeat rule, in the same card treatment as `properties`.
    // Both write through the same debounced save as everything else on this
    // screen, so the recurrence and the title cannot end up in two different
    // queued PUTs racing each other.

    private var schedule: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceM) {
            GraftDateRow(label: "Start", value: $startAt)
                .onChange(of: startAt) { _, _ in scheduleSave() }
            Rectangle().fill(Color.gHairline).frame(height: GraftMetrics.border)
            GraftDateRow(label: "Due", value: $dueAt)
                .onChange(of: dueAt) { _, _ in scheduleSave() }
            Rectangle().fill(Color.gHairline).frame(height: GraftMetrics.border)
            RecurrenceEditor(rule: $recurrence, anchor: $recurrenceAnchor)
                .onChange(of: recurrence) { _, _ in scheduleSave() }
                .onChange(of: recurrenceAnchor) { _, _ in scheduleSave() }

            if current.repeats || !current.recurrenceParent.isEmpty {
                NavigationLink(value: GraftRoute.series(current)) {
                    HStack(spacing: GraftMetrics.spaceXS) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13))
                        Text("See every occurrence")
                            .font(GraftFont.text(GraftType.body))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.gInk3)
                    }
                    .foregroundStyle(Color.gAccentText)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: 0.5)
        )
    }

    /// What happened when a recurring issue was completed. There is no undo
    /// offered — putting the status back would leave the replacement standing,
    /// and the user would be looking at two of the same chore with no way to
    /// tell which is real. The web client makes the same call.
    @ViewBuilder
    private var spawnNotice: some View {
        if let spawned {
            HStack(alignment: .top, spacing: GraftMetrics.spaceXS) {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gAccentText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Done — next one \(GraftDate.dueLabel(spawned.dueAt) ?? "scheduled")")
                        .font(GraftFont.text(GraftType.body, .semibold))
                        .foregroundStyle(Color.gInk)
                    Text("This one has been archived and kept as history.")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                NavigationLink(value: GraftRoute.issue(spawned)) {
                    Text("Open")
                        .font(GraftFont.text(GraftType.secondary, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .frame(minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(GraftMetrics.spaceS)
            .background(Color.gAccent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
        }
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
        startAt = i.startAt
        dueAt = i.dueAt
        recurrence = i.recurrence
        recurrenceAnchor = i.recurrenceAnchor.isEmpty
            ? RecurrenceAnchor.schedule.rawValue : i.recurrenceAnchor
    }

    /// Debounced so typing does not fire a request per keystroke.
    private func scheduleSave() {
        // The eight fields being filled in from the store is not an edit.
        guard !hydrating else { return }
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

    /// `force` is for the Retry button and nothing else: after a dropped write
    /// the local cache already holds the edit, so the rebuilt issue matches the
    /// stored one and the guard below would turn the retry into nothing.
    private func save(force: Bool = false) {
        hasUnsavedEdits = false
        var updated = current
        // A blank title used to abandon the whole save, silently taking the
        // description, labels and dates typed in the same 700ms with it. An
        // issue still has to be called something, so the previous title stands
        // until a new one is typed — the field is showing what the user emptied,
        // and the next keystroke replaces it either way.
        let typed = title.trimmingCharacters(in: .whitespaces)
        updated.title = typed.isEmpty ? current.title : title
        updated.description = description
        updated.assignee = assignee
        // De-duplicated on the way in: both ends accept "bug, bug", and a
        // repeated label is a duplicate id in every `ForEach` that renders one.
        updated.labels = labelsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .uniqued
        updated.startAt = startAt
        updated.dueAt = dueAt
        updated.recurrence = recurrence
        updated.recurrenceAnchor = recurrenceAnchor
        // Nothing actually changed, so nothing is written. Opening an issue
        // hydrates eight fields that each schedule a save; without this the
        // visit alone bumped `updated_at`, reordered every "last updated" list
        // and flashed "Saved" at somebody who had only looked.
        guard force || !identical(updated, current) else { return }
        persist(updated)
    }

    /// Whether the rebuilt issue says anything the stored one does not. Only the
    /// fields this screen's debounce writes: `updated_at` is stamped inside the
    /// store, and comparing it would make every save look like a change.
    private func identical(_ a: GraftIssue, _ b: GraftIssue) -> Bool {
        a.title == b.title
            && a.description == b.description
            && a.assignee == b.assignee
            && a.labels == b.labels
            && a.startAt == b.startAt
            && a.dueAt == b.dueAt
            && a.recurrence == b.recurrence
            && a.recurrenceAnchor == b.recurrenceAnchor
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

            // `updateIssue` awaits the flush, so by here the queue has already
            // read the response back. A spawn means this issue was recurring
            // and has just been replaced — see `GraftStore.applySpawn`.
            if let next = store.lastSpawned, next.seriesRoot == current.seriesRoot {
                spawned = next
                store.lastSpawned = nil
            }

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
        save(force: true)
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
