import SwiftUI

/// What needs you, across every project.
///
/// The app previously opened on the project list, so the one question a phone
/// is good for — what is blocked right now — could not be asked at all. The
/// web client has had a cross-project list since the start.
struct InboxView: View {
    @Environment(GraftStore.self) private var store

    @State private var scope: Scope = .everyone
    @State private var showNewIssue = false
    @State private var undo: UndoAction?

    enum Scope: String, CaseIterable, Identifiable {
        case everyone = "Everyone"
        case unassigned = "Unassigned"
        var id: String { rawValue }
    }

    private var visible: [GraftIssue] {
        let all = store.inbox()
        switch scope {
        case .everyone: return all
        case .unassigned: return all.filter { $0.assignee.isEmpty }
        }
    }

    /// Urgent, high, or inside two days of its milestone.
    private var needsYou: [GraftIssue] {
        visible.filter { issue in
            if issue.priority == "urgent" || issue.priority == "high" { return true }
            if let days = GraftDate.daysUntil(store.milestone(issue.milestoneId)?.dueDate) {
                return days <= 2
            }
            return false
        }
    }

    private var moving: [GraftIssue] {
        let flagged = Set(needsYou.map(\.id))
        return visible.filter { $0.status == "in-progress" && !flagged.contains($0.id) }
    }

    private var summary: String {
        let open = visible.count
        let projects = Set(visible.map(\.projectId)).count
        return "\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you · \(open) open across \(projects) project\(projects == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.gBg.ignoresSafeArea()

                if store.issues.isEmpty && store.isLoading {
                    ProgressView().tint(Color.gSage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    GraftEmptyState(
                        title: "Nothing waiting",
                        subtitle: scope == .unassigned
                            ? "Everything open has someone on it."
                            : "No open issues anywhere. Enjoy it.",
                        systemImage: "tray"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Picker("Scope", selection: $scope) {
                                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, GraftMetrics.gutter)
                            .padding(.bottom, 14)

                            section("Needs you", needsYou)
                            section("In progress", moving)

                            Color.clear.frame(height: 96)
                        }
                        .padding(.top, 8)
                    }
                    .refreshable { await store.sync() }
                }

                Button {
                    showNewIssue = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.gOnAccent)
                        .frame(width: 56, height: 56)
                        .background(Color.gAmber, in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .accessibilityLabel("New issue")
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(summary)
                        .font(.system(size: GraftType.caption))
                        .foregroundStyle(Color.gMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView().tint(Color.gAmber)
                    } else {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .sheet(isPresented: $showNewIssue) {
                if let first = store.projects.first(where: { !$0.archived }) {
                    NewIssueView(projectId: first.id)
                }
            }
            .undoBanner($undo)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ issues: [GraftIssue]) -> some View {
        if !issues.isEmpty {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.gMuted)
                Text("\(issues.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.gSurface2, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, GraftMetrics.gutter)
            .padding(.top, 6)
            .padding(.bottom, 8)

            ForEach(issues) { issue in
                NavigationLink(destination: IssueDetailView(issue: issue)) {
                    InboxRow(issue: issue,
                             project: store.project(issue.projectId),
                             due: GraftDate.dueLabel(store.milestone(issue.milestoneId)?.dueDate))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, 8)
                .swipeActions(edge: .trailing) {
                    Button {
                        archive(issue)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(Color.gSage)
                }
            }
        }
    }

    private func archive(_ issue: GraftIssue) {
        Task {
            try? await store.archiveIssue(id: issue.id)
            undo = UndoAction(message: "Issue archived") {
                try? await store.archiveIssue(id: issue.id)
            }
        }
    }
}

// MARK: - Row

struct InboxRow: View {
    let issue: GraftIssue
    let project: GraftProject?
    let due: String?

    var body: some View {
        let status = IssueStatus(rawValue: issue.status) ?? .backlog
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal
        let overdue = (due?.contains("overdue")) == true

        HStack(spacing: 0) {
            if priority == .urgent || priority == .high {
                Rectangle()
                    .fill(priority.color)
                    .frame(width: 3)
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(status.color)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.title)
                        .font(.system(size: GraftType.title, weight: .medium))
                        .foregroundStyle(Color.gInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        PriorityBadge(priority: issue.priority)
                        if let due {
                            Text(due)
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(overdue ? Color.gRed : Color.gMuted)
                        }
                        if let milestone = issue.milestoneName {
                            MilestoneTag(name: milestone)
                        }
                        if let project {
                            Text(project.name)
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(Color.gMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        GraftAvatar(name: issue.assignee, size: 24)
                    }
                }
            }
            .padding(12)
        }
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: 0.5)
        )
    }
}
