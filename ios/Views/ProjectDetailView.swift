import SwiftUI

struct ProjectDetailView: View {
    @Environment(GraftStore.self) private var store
    let project: GraftProject

    @State private var showNewIssue = false
    @State private var showMilestones = false
    @State private var showEditProject = false
    @State private var selectedMilestoneId: String? = nil
    @State private var groupByStatus = true

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

    var projectMilestones: [GraftMilestone] {
        store.milestones(for: project.id)
    }

    var currentProject: GraftProject {
        store.projects.first { $0.id == project.id } ?? project
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                // Project header
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: currentProject.colour) ?? .indigo)
                            .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            if !currentProject.description.isEmpty {
                                Text(currentProject.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            StatusChip(status: currentProject.status)
                        }

                        Spacer()

                        Button {
                            showMilestones = true
                        } label: {
                            Label("Milestones", systemImage: "flag")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 4)
                }

                // Milestone filter
                if !projectMilestones.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                FilterChip(title: "All", isSelected: selectedMilestoneId == nil) {
                                    selectedMilestoneId = nil
                                }
                                ForEach(projectMilestones) { milestone in
                                    FilterChip(title: milestone.name, isSelected: selectedMilestoneId == milestone.id) {
                                        selectedMilestoneId = selectedMilestoneId == milestone.id ? nil : milestone.id
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }

                // Issues grouped by status
                if projectIssues.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No issues",
                            systemImage: "tray",
                            description: Text("Tap + to add an issue")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(issuesByStatus, id: \.0) { (status, statusIssues) in
                        Section(header: Text(statusDisplayName(status)).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)) {
                            ForEach(statusIssues) { issue in
                                NavigationLink(destination: IssueDetailView(issue: issue)) {
                                    IssueRowView(issue: issue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { try? await store.deleteIssue(id: issue.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            // FAB
            Button {
                showNewIssue = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.indigo, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle(currentProject.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditProject = true
                } label: {
                    Image(systemName: "pencil")
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
    }

    func statusDisplayName(_ status: String) -> String {
        switch status {
        case "backlog": return "Backlog"
        case "todo": return "To do"
        case "in-progress": return "In progress"
        case "review": return "Review"
        case "done": return "Done"
        default: return status
        }
    }
}

// MARK: - Issue Row

struct IssueRowView: View {
    let issue: GraftIssue

    var priorityColor: Color {
        switch issue.priority {
        case "urgent": return Color(hex: "#ef4444") ?? .red
        case "high": return Color(hex: "#f97316") ?? .orange
        case "normal": return .secondary
        case "low": return .tertiary
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let milestone = issue.milestoneName {
                        Label(milestone, systemImage: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !issue.assignee.isEmpty {
                        Label(issue.assignee, systemImage: "person")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if !issue.labels.isEmpty {
                Text(issue.labels.prefix(2).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.indigo : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }
}
