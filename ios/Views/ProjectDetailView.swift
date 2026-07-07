import SwiftUI

struct ProjectDetailView: View {
    @Environment(GraftStore.self) private var store
    let project: GraftProject

    @State private var showNewIssue = false
    @State private var showMilestones = false
    @State private var showEditProject = false
    @State private var selectedMilestoneId: String? = nil
    @State private var viewMode: ViewMode = .list

    enum ViewMode: String, CaseIterable {
        case list = "List"
        case board = "Board"
    }

    var currentProject: GraftProject {
        store.projects.first { $0.id == project.id } ?? project
    }

    var projectMilestones: [GraftMilestone] {
        store.milestones(for: project.id)
    }

    var projectIssues: [GraftIssue] {
        var all = store.issues(for: project.id)
        if let mid = selectedMilestoneId {
            all = all.filter { $0.milestoneId == mid }
        }
        return all
    }

    var issuesByStatus: [(String, [GraftIssue])] {
        let order = ["backlog", "todo", "in-progress", "review", "done"]
        return order.compactMap { status in
            let filtered = projectIssues.filter { $0.status == status }
            return filtered.isEmpty ? nil : (status, filtered)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.gBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Project header card
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: currentProject.colour))
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            if !currentProject.description.isEmpty {
                                Text(currentProject.description)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.gMuted)
                            }
                            HStack(spacing: 8) {
                                projectStatusChip(currentProject.status)
                                Button {
                                    showMilestones = true
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "leaf.fill")
                                            .font(.system(size: 10))
                                        Text("Milestones")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundStyle(Color.gSage)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gSage.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    // Milestone filter chips
                    if !projectMilestones.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                MilestoneFilterChip(title: "All", isSelected: selectedMilestoneId == nil) {
                                    selectedMilestoneId = nil
                                }
                                ForEach(projectMilestones) { milestone in
                                    MilestoneFilterChip(
                                        title: milestone.name,
                                        isSelected: selectedMilestoneId == milestone.id
                                    ) {
                                        selectedMilestoneId = selectedMilestoneId == milestone.id ? nil : milestone.id
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        Divider()
                            .background(Color.gHairline)
                    }

                    // View mode toggle
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .colorScheme(.dark)

                    Divider()
                        .background(Color.gHairline)

                    // Issues content
                    if projectIssues.isEmpty {
                        GraftEmptyState(
                            title: "Nothing growing here",
                            subtitle: "Tap + to plant your first issue.",
                            systemImage: "leaf"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if viewMode == .list {
                        listView
                    } else {
                        boardView
                    }
                }
            }
            .scrollContentBackground(.hidden)

            // FAB
            Button {
                showNewIssue = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "leaf")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.gAmber, in: Capsule())
                .shadow(color: Color.gAmber.opacity(0.4), radius: 8, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 28)
        }
        .navigationTitle(currentProject.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.gBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditProject = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.gMuted)
                }
            }
        }
        .sheet(isPresented: $showNewIssue) {
            NewIssueView(projectId: project.id)
        }
        .sheet(isPresented: $showMilestones) {
            MilestonesView(projectId: project.id)
        }
        .sheet(isPresented: $showEditProject) {
            EditProjectView(project: currentProject)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - List view

    @ViewBuilder
    var listView: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(issuesByStatus, id: \.0) { (status, statusIssues) in
                Section {
                    ForEach(statusIssues) { issue in
                        NavigationLink(destination: IssueDetailView(issue: issue)) {
                            IssueRowView(issue: issue)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { try? await store.deleteIssue(id: issue.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        let s = IssueStatus(rawValue: status) ?? .backlog
                        Image(systemName: s.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(s.color)
                        Text(s.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.gMuted)
                        Text("·")
                            .foregroundStyle(Color.gHairline)
                        Text("\(statusIssues.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.gMuted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.gBg)
                }
            }
        }
        .padding(.bottom, 100)
    }

    // MARK: - Board view

    @ViewBuilder
    var boardView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(issuesByStatus, id: \.0) { (status, statusIssues) in
                    VStack(alignment: .leading, spacing: 8) {
                        let s = IssueStatus(rawValue: status) ?? .backlog

                        // Column header
                        HStack(spacing: 6) {
                            Image(systemName: s.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(s.color)
                            Text(s.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.gMuted)
                            Spacer()
                            Text("\(statusIssues.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.gMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gSurface2)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)

                        // Issues
                        ForEach(statusIssues) { issue in
                            NavigationLink(destination: IssueDetailView(issue: issue)) {
                                BoardIssueCard(issue: issue)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(width: 230)
                    .background(Color.gSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gHairline, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    func projectStatusChip(_ status: String) -> some View {
        let color: Color = {
            switch status {
            case "active": return .gSage
            case "paused": return .gAmber
            case "done": return .gTeal
            default: return .gMuted
            }
        }()
        let label: String = {
            switch status {
            case "active": return "active"
            case "paused": return "paused"
            case "done": return "done"
            default: return status
            }
        }()
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Issue Row

struct IssueRowView: View {
    let issue: GraftIssue

    var body: some View {
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal
        let status = IssueStatus(rawValue: issue.status) ?? .backlog

        HStack(spacing: 0) {
            // Priority colour border
            RoundedRectangle(cornerRadius: 2)
                .fill(priority.color)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(issue.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(2)
                    Spacer()
                    StatusBadge(status: issue.status)
                }

                HStack(spacing: 8) {
                    if let milestone = issue.milestoneName {
                        MilestoneTag(name: milestone)
                    }
                    if !issue.assignee.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                            Text(issue.assignee)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.gMuted)
                    }
                    if !issue.labels.isEmpty {
                        ForEach(issue.labels.prefix(2), id: \.self) { label in
                            Text(label)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.gMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.gSurface2)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gHairline, lineWidth: 0.5))
    }
}

// MARK: - Board Issue Card

struct BoardIssueCard: View {
    let issue: GraftIssue

    var body: some View {
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(priority.color)
                    .frame(width: 3, height: 14)
                    .padding(.trailing, 6)
                Text(issue.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 6) {
                if let milestone = issue.milestoneName {
                    MilestoneTag(name: milestone)
                }
                if !issue.assignee.isEmpty {
                    Text("@\(issue.assignee)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.gMuted)
                }
            }
        }
        .padding(10)
        .background(Color.gSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }
}

// MARK: - Milestone Filter Chip

struct MilestoneFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.gSage : Color.gMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.gSage.opacity(0.15) : Color.gSurface2,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.gSage.opacity(0.3) : Color.gHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
