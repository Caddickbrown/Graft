import SwiftUI

// MARK: - The monitor
//
// What `ExternalDisplaySceneDelegate` puts on the second screen. Laid out for a
// desk rather than a hand: type sized off the panel's height, a list beside the
// issue under the selection, and a bar of the keys that work right now — with
// the phone face down, the monitor is the only place left to read them.
//
// Everything is read from the live `GraftStore` by id, so an edit made with a
// key repaints here in the same pass as on the phone.

struct ExternalDisplayRoot: View {
    @State private var model = ExternalDisplayModel.shared

    var body: some View {
        GeometryReader { geo in
            let metrics = ExternalMetrics(size: geo.size, scale: model.textSize.scale)
            VStack(spacing: 0) {
                Group {
                    if let store = model.store {
                        ExternalContentView(content: model.content, store: store, metrics: metrics)
                    } else {
                        // The app's own scene has not come up yet — a monitor
                        // that was plugged in before launch.
                        GraftWordmark(size: metrics.title * 1.4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.showsHints {
                    ExternalHintBar(hints: hints, paused: model.isPaused, metrics: metrics)
                }
            }
            .padding(metrics.padding)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.gBg.ignoresSafeArea())
        .preferredColorScheme(model.colorScheme)
        .environment(\.colorScheme, model.colorScheme)
        .animation(.easeOut(duration: 0.15), value: model.content)
    }

    private var hints: [ExternalHint] {
        if model.isPaused { return [ExternalHint("⌥⌘P", "Resume")] }
        switch model.content {
        case .idle:
            return [.init("1", "Inbox"), .init("2", "Projects"), .init("n", "New issue"),
                    .init("r", "Refresh"), .init("?", "Keys")]
        case .issues:
            return [.init("↑↓", "Move"), .init("↵", "Open"), .init("[ ]", "Status"),
                    .init("x", "Done"), .init("p", "Priority"), .init("a", "Archive"),
                    .init("n", "New"), .init("/", "Search"), .init("esc", "Back")]
        case .projects:
            return [.init("↑↓", "Move"), .init("↵", "Open"), .init("f", "Favourite"),
                    .init("n", "New project"), .init("/", "Search"), .init("1", "Inbox")]
        case .issue:
            return [.init("[ ]", "Status"), .init("x", "Done"), .init("p", "Priority"),
                    .init("t", "Title"), .init("e", "Description"), .init("a", "Archive"),
                    .init("esc", "Back")]
        }
    }
}

// MARK: - Metrics

/// Type sized for the monitor. The phone's sizes are calibrated for arm's
/// length, so everything here scales off the panel's own height — ~34pt body
/// on a 1080p desk monitor at Regular, with `ExternalTextSize` to push it up
/// for a screen across a room.
struct ExternalMetrics {
    let body: CGFloat
    let title: CGFloat
    let caption: CGFloat
    let padding: CGFloat
    let gap: CGFloat

    init(size: CGSize, scale: CGFloat = 1) {
        let height = max(size.height, 320)
        body    = min(44, max(15, height * 0.026 * scale))
        title   = body * 1.6
        caption = max(12, body * 0.62)
        // TVs overscan and monitors have bezels; keep well inside both.
        padding = max(24, min(size.width, size.height) * 0.05)
        gap     = body * 0.8
    }
}

// MARK: - Content

private struct ExternalContentView: View {
    let content: ExternalDisplayContent
    let store: GraftStore
    let metrics: ExternalMetrics

    var body: some View {
        switch content {
        case .idle:
            ExternalIdleView(store: store, metrics: metrics)

        case .issues(let title, let items, let selected):
            HStack(alignment: .top, spacing: metrics.gap * 2) {
                ExternalIssueList(title: title, items: items, selected: selected,
                                  store: store, metrics: metrics)
                    .frame(maxWidth: .infinity)
                Group {
                    if let selected, let issue = store.issues.first(where: { $0.id == selected }) {
                        ExternalIssuePanel(issue: issue, store: store, metrics: metrics, compact: true)
                    } else {
                        ExternalQuiet(text: "Nothing selected", metrics: metrics)
                    }
                }
                .frame(maxWidth: .infinity)
            }

        case .projects(let items, let selected):
            HStack(alignment: .top, spacing: metrics.gap * 2) {
                ExternalProjectList(items: items, selected: selected, store: store, metrics: metrics)
                    .frame(maxWidth: .infinity)
                Group {
                    if let selected, let project = store.project(selected) {
                        ExternalProjectPanel(project: project, store: store, metrics: metrics)
                    } else {
                        ExternalQuiet(text: "No projects", metrics: metrics)
                    }
                }
                .frame(maxWidth: .infinity)
            }

        case .issue(let id):
            if let issue = store.issues.first(where: { $0.id == id }) {
                ExternalIssuePanel(issue: issue, store: store, metrics: metrics, compact: false)
                    .frame(maxWidth: metrics.body * 34)
                    .frame(maxWidth: .infinity)
            } else {
                ExternalQuiet(text: "Issue gone", metrics: metrics)
            }
        }
    }
}

private struct ExternalQuiet: View {
    let text: String
    let metrics: ExternalMetrics

    var body: some View {
        Text(text)
            .font(GraftFont.text(metrics.body))
            .foregroundStyle(Color.gInk3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Idle

/// The day at a glance: what is late, what is due, what needs you — and the top
/// of that last list, so the monitor is worth a look even untouched.
private struct ExternalIdleView: View {
    let store: GraftStore
    let metrics: ExternalMetrics

    var body: some View {
        let open = store.inbox()
        let needsYou = open.filter { store.needsYou($0) }
        let moving = open.filter { $0.status == "in-progress" }

        VStack(alignment: .leading, spacing: metrics.gap * 1.5) {
            HStack(alignment: .firstTextBaseline) {
                GraftWordmark(size: metrics.title)
                Spacer()
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(GraftFont.text(metrics.body, .medium))
                    .foregroundStyle(Color.gInk2)
            }

            HStack(spacing: metrics.gap) {
                tile("Overdue", store.overdueCount(in: open), tint: .gRed)
                tile("Due today", store.dueTodayCount(in: open), tint: .gAmber)
                tile("Needs you", needsYou.count, tint: .gOrange)
                tile("In progress", moving.count, tint: .gAmber)
                tile("Open", open.count, tint: .gInk2)
            }

            if needsYou.isEmpty {
                ExternalQuiet(text: open.isEmpty ? "Nothing waiting. Enjoy it." : "Nothing urgent.",
                              metrics: metrics)
            } else {
                Text("NEEDS YOU")
                    .font(GraftFont.text(metrics.caption, .semibold))
                    .kerning(1)
                    .foregroundStyle(Color.gInk2)
                VStack(spacing: metrics.gap * 0.5) {
                    ForEach(needsYou.prefix(6)) { issue in
                        ExternalIssueRow(issue: issue, store: store, metrics: metrics, selected: false)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tile(_ label: String, _ value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.3) {
            Text("\(value)")
                .font(GraftFont.display(metrics.title * 1.2, .bold))
                .foregroundStyle(value > 0 ? tint : Color.gInk3)
                .monospacedDigit()
            Text(label)
                .font(GraftFont.text(metrics.caption, .medium))
                .foregroundStyle(Color.gInk2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.gap)
        .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: GraftMetrics.radiusLarge)
            .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border))
    }
}

// MARK: Lists

private struct ExternalIssueList: View {
    let title: String
    let items: [ExternalListItem]
    let selected: String?
    let store: GraftStore
    let metrics: ExternalMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(GraftFont.display(metrics.title, .bold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                Spacer()
                if let selected, let i = items.firstIndex(where: { $0.id == selected }) {
                    Text("\(i + 1) of \(items.count)")
                        .font(GraftFont.mono(metrics.caption))
                        .foregroundStyle(Color.gInk3)
                }
            }

            if items.isEmpty {
                ExternalQuiet(text: "Nothing here", metrics: metrics)
            } else {
                // Looked up once per render rather than once per row.
                let byId = Dictionary(store.issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: metrics.gap * 0.5) {
                            ForEach(items) { item in
                                if let section = item.section {
                                    Text(section.uppercased())
                                        .font(GraftFont.text(metrics.caption, .semibold))
                                        .kerning(1)
                                        .foregroundStyle(Color.gInk2)
                                        .padding(.top, metrics.gap * 0.6)
                                }
                                if let issue = byId[item.id] {
                                    ExternalIssueRow(issue: issue, store: store, metrics: metrics,
                                                     selected: item.id == selected)
                                        .id(item.id)
                                }
                            }
                        }
                    }
                    .onAppear { scroll(proxy, animated: false) }
                    .onChange(of: selected) { _, _ in scroll(proxy, animated: true) }
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selected else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selected, anchor: .center) }
        } else {
            proxy.scrollTo(selected, anchor: .center)
        }
    }
}

private struct ExternalIssueRow: View {
    /// Read again from the store on every render. `GraftIssue`'s `==` compares
    /// only the id (it is a navigation route too), so an issue passed in and
    /// edited since compares equal, SwiftUI keeps the old body, and a `]` on the
    /// phone never reached the monitor. Looking it up here makes the body depend
    /// on the store itself. The panels below do the same.
    private let passed: GraftIssue
    private var issue: GraftIssue { store.issues.first { $0.id == passed.id } ?? passed }
    let store: GraftStore
    let metrics: ExternalMetrics
    let selected: Bool

    init(issue: GraftIssue, store: GraftStore, metrics: ExternalMetrics, selected: Bool) {
        passed = issue; self.store = store; self.metrics = metrics; self.selected = selected
    }

    var body: some View {
        let done = issue.status == "done"
        HStack(alignment: .firstTextBaseline, spacing: metrics.gap * 0.6) {
            StatusRing(status: issue.status, size: metrics.body * 0.75)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + metrics.body * 0.3 }
            VStack(alignment: .leading, spacing: metrics.gap * 0.2) {
                Text(issue.title)
                    .font(GraftFont.text(metrics.body, .medium))
                    .foregroundStyle(done ? Color.gInk2 : Color.gInk)
                    .strikethrough(done, color: Color.gInk2)
                    .lineLimit(2)
                HStack(spacing: metrics.gap * 0.5) {
                    PriorityDot(priority: issue.priority, size: metrics.caption)
                    if let project = store.project(issue.projectId) {
                        ProjectColourDot(hex: project.colour, size: metrics.caption * 0.6)
                        Text(project.name)
                    }
                    if let due = GraftDate.dueLabel(store.dueDate(for: issue)) {
                        Text("· \(due)")
                            .foregroundStyle(dueTint)
                    }
                    if !issue.assignee.isEmpty { Text("· \(issue.assignee)") }
                }
                .font(GraftFont.text(metrics.caption))
                .foregroundStyle(Color.gInk2)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.gap * 0.8)
        .padding(.vertical, metrics.gap * 0.5)
        .background(selected ? Color.gAccentWash : Color.clear,
                    in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: GraftMetrics.radius)
                    .strokeBorder(Color.gAccent, lineWidth: 2)
            }
        }
    }

    private var dueTint: Color {
        guard let days = GraftDate.daysUntil(store.dueDate(for: issue)) else { return .gInk2 }
        if days < 0 { return .gRed }
        if days <= 2 { return .gAmber }
        return .gInk2
    }
}

private struct ExternalProjectList: View {
    let items: [ExternalListItem]
    let selected: String?
    let store: GraftStore
    let metrics: ExternalMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            Text("Projects")
                .font(GraftFont.display(metrics.title, .bold))
                .foregroundStyle(Color.gInk)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: metrics.gap * 0.5) {
                        ForEach(items) { item in
                            if let section = item.section {
                                Text(section.uppercased())
                                    .font(GraftFont.text(metrics.caption, .semibold))
                                    .kerning(1)
                                    .foregroundStyle(Color.gInk2)
                                    .padding(.top, metrics.gap * 0.6)
                            }
                            if let project = store.project(item.id) {
                                row(project, selected: item.id == selected)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
                .onChange(of: selected) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func row(_ project: GraftProject, selected: Bool) -> some View {
        HStack(spacing: metrics.gap * 0.6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: project.colour))
                .frame(width: 4, height: metrics.body * 1.2)
            if !project.icon.isEmpty {
                Text(project.icon).font(GraftFont.emoji(metrics.body))
            }
            Text(project.name)
                .font(GraftFont.text(metrics.body, .medium))
                .foregroundStyle(Color.gInk)
                .lineLimit(1)
            if project.isFavourite {
                Image(systemName: "star.fill")
                    .font(.system(size: metrics.caption * 0.8))
                    .foregroundStyle(Color.gAmber)
            }
            Spacer(minLength: 0)
            Text("\(store.issues(for: project.id).filter { $0.status != "done" }.count) open")
                .font(GraftFont.text(metrics.caption))
                .foregroundStyle(Color.gInk2)
        }
        .padding(.horizontal, metrics.gap * 0.8)
        .padding(.vertical, metrics.gap * 0.5)
        .background(selected ? Color.gAccentWash : Color.clear,
                    in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: GraftMetrics.radius)
                    .strokeBorder(Color.gAccent, lineWidth: 2)
            }
        }
    }
}

// MARK: Panels

/// One issue, read from across a desk. `compact` is the preview beside a list;
/// otherwise it is the whole screen and the description gets the room.
private struct ExternalIssuePanel: View {
    /// Read from the store on every render; see `ExternalIssueRow`.
    private let passed: GraftIssue
    private var issue: GraftIssue { store.issues.first { $0.id == passed.id } ?? passed }
    let store: GraftStore
    let metrics: ExternalMetrics
    let compact: Bool

    init(issue: GraftIssue, store: GraftStore, metrics: ExternalMetrics, compact: Bool) {
        passed = issue; self.store = store; self.metrics = metrics; self.compact = compact
    }

    var body: some View {
        let status = IssueStatus(rawValue: issue.status) ?? .backlog
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal
        let labels = issue.labels.filter { !$0.isEmpty }.uniqued

        VStack(alignment: .leading, spacing: metrics.gap) {
            if let project = store.project(issue.projectId) {
                HStack(spacing: metrics.gap * 0.4) {
                    ProjectColourDot(hex: project.colour, size: metrics.caption * 0.7)
                    Text(project.name)
                    if let milestone = store.milestone(issue.milestoneId)?.name ?? issue.milestoneName {
                        Text("· \(milestone)")
                    }
                }
                .font(GraftFont.text(metrics.caption, .medium))
                .foregroundStyle(Color.gInk2)
            }

            Text(issue.title)
                .font(GraftFont.display(compact ? metrics.title : metrics.title * 1.2, .bold))
                .foregroundStyle(Color.gInk)
                .fixedSize(horizontal: false, vertical: true)

            FlowRow(spacing: metrics.gap * 0.5) {
                chip(status.label, tint: status.color) {
                    StatusRing(status: status, size: metrics.caption)
                }
                chip("\(priority.label) priority", tint: priority.color) {
                    PriorityDot(priority: issue.priority, size: metrics.caption)
                }
                if let due = store.dueDate(for: issue), let label = GraftDate.dueLabel(due) {
                    chip("\(GraftDate.mediumDate(due) ?? due) · \(label)", tint: dueTint(due)) {
                        Image(systemName: "calendar")
                    }
                }
                if let start = GraftDate.mediumDate(issue.startAt) {
                    chip("Starts \(start)", tint: .gInk2) { Image(systemName: "play") }
                }
                if issue.repeats {
                    chip(Recurrence.shortText(issue.recurrence), tint: .gInk2) { Image(systemName: "repeat") }
                }
                if !issue.assignee.isEmpty {
                    chip(issue.assignee, tint: .gInk2) { Image(systemName: "person") }
                }
                ForEach(labels, id: \.self) { label in
                    chip(label, tint: .gInk2) { Image(systemName: "tag") }
                }
            }

            Rectangle().fill(Color.gHairline).frame(height: 1)

            ScrollView(showsIndicators: false) {
                Group {
                    if issue.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.")
                            .foregroundStyle(Color.gInk3)
                    } else {
                        Text(markdown(issue.description))
                            .foregroundStyle(Color.gInk)
                    }
                }
                .font(GraftFont.text(compact ? metrics.body * 0.85 : metrics.body))
                .lineSpacing(metrics.body * 0.25)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Updated \(GraftDate.relative(issue.updatedAt))")
                .font(GraftFont.text(metrics.caption))
                .foregroundStyle(Color.gInk3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chip<Glyph: View>(_ text: String, tint: Color, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: metrics.gap * 0.3) {
            glyph()
            Text(text)
        }
        .font(GraftFont.text(metrics.caption, .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, metrics.gap * 0.5)
        .padding(.vertical, metrics.gap * 0.25)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func dueTint(_ due: String) -> Color {
        guard let days = GraftDate.daysUntil(due) else { return .gInk2 }
        if days < 0 { return .gRed }
        if days <= 2 { return .gAmber }
        return .gInk2
    }

    /// Inline markdown with the line breaks kept — descriptions are written as
    /// notes, and full block parsing would fold a hand-made list into a line.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A project under the selection: its numbers and the work that is moving.
private struct ExternalProjectPanel: View {
    /// Read from the store on every render; see `ExternalIssueRow`.
    private let passed: GraftProject
    private var project: GraftProject { store.project(passed.id) ?? passed }
    let store: GraftStore
    let metrics: ExternalMetrics

    init(project: GraftProject, store: GraftStore, metrics: ExternalMetrics) {
        passed = project; self.store = store; self.metrics = metrics
    }

    var body: some View {
        let issues = store.issues(for: project.id)
        let open = issues.filter { $0.status != "done" }
        let order = ["in-progress": 0, "review": 1, "todo": 2, "backlog": 3]
        let next = open.sorted { (order[$0.status] ?? 4) < (order[$1.status] ?? 4) }

        VStack(alignment: .leading, spacing: metrics.gap) {
            HStack(spacing: metrics.gap * 0.6) {
                if !project.icon.isEmpty {
                    Text(project.icon).font(GraftFont.emoji(metrics.title))
                }
                Text(project.name)
                    .font(GraftFont.display(metrics.title, .bold))
                    .foregroundStyle(Color.gInk)
            }
            if !project.description.isEmpty {
                Text(project.description)
                    .font(GraftFont.text(metrics.body * 0.85))
                    .foregroundStyle(Color.gInk2)
            }
            HStack(spacing: metrics.gap) {
                ForEach(IssueStatus.allCases, id: \.self) { status in
                    let count = issues.filter { $0.status == status.rawValue }.count
                    HStack(spacing: metrics.gap * 0.3) {
                        StatusRing(status: status, size: metrics.caption)
                        Text("\(count)").monospacedDigit()
                    }
                    .font(GraftFont.text(metrics.caption, .medium))
                    .foregroundStyle(count > 0 ? status.color : Color.gInk3)
                }
            }
            Rectangle().fill(Color.gHairline).frame(height: 1)
            if next.isEmpty {
                ExternalQuiet(text: "Nothing open", metrics: metrics)
            } else {
                VStack(spacing: metrics.gap * 0.4) {
                    ForEach(next.prefix(8)) { issue in
                        ExternalIssueRow(issue: issue, store: store, metrics: metrics, selected: false)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Hint bar

struct ExternalHint: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key + label }
    init(_ key: String, _ label: String) { self.key = key; self.label = label }
}

private struct ExternalHintBar: View {
    let hints: [ExternalHint]
    let paused: Bool
    let metrics: ExternalMetrics

    var body: some View {
        HStack(spacing: metrics.gap) {
            if paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(GraftFont.text(metrics.caption, .semibold))
                    .foregroundStyle(Color.gAmber)
            }
            ForEach(hints) { hint in
                HStack(spacing: metrics.gap * 0.3) {
                    Text(hint.key)
                        .font(GraftFont.mono(metrics.caption * 0.9, .medium))
                        .foregroundStyle(Color.gInk)
                        .padding(.horizontal, metrics.gap * 0.35)
                        .padding(.vertical, metrics.gap * 0.1)
                        .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
                    Text(hint.label)
                        .font(GraftFont.text(metrics.caption))
                        .foregroundStyle(Color.gInk2)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.top, metrics.gap)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.gHairline).frame(height: 1)
        }
    }
}
