import SwiftUI

struct ProjectsView: View {
    @Environment(GraftStore.self) private var store
    @State private var showNewProject = false
    @State private var showSettings = false
    @State private var searchText = ""

    var filteredProjects: [GraftProject] {
        if searchText.isEmpty { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty && store.isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "folder",
                        description: Text("Tap + to create your first project")
                    )
                } else {
                    List {
                        ForEach(filteredProjects) { project in
                            NavigationLink(destination: ProjectDetailView(project: project)) {
                                ProjectRowView(project: project)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .onDelete { indexSet in
                            Task {
                                for index in indexSet {
                                    let project = filteredProjects[index]
                                    try? await store.deleteProject(id: project.id)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search projects")
                }
            }
            .navigationTitle("Graft")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay(alignment: .bottom) {
                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: store.errorMessage)
        }
        .fontDesign(.default)
    }
}

// MARK: - Project Row

struct ProjectRowView: View {
    let project: GraftProject

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: project.colour) ?? .indigo)
                .frame(width: 6, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body)
                    .fontWeight(.medium)

                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let counts = project.issueCounts {
                    let open = counts.backlog + counts.todo + counts.inProgress + counts.review
                    Text("\(open)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("open")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                StatusChip(status: project.status)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status Chip

struct StatusChip: View {
    let status: String

    var label: String {
        switch status {
        case "active": return "Active"
        case "paused": return "Paused"
        case "done": return "Done"
        case "backlog": return "Backlog"
        case "todo": return "To do"
        case "in-progress": return "In progress"
        case "review": return "Review"
        default: return status
        }
    }

    var color: Color {
        switch status {
        case "active": return .green
        case "paused": return .orange
        case "done": return .secondary
        case "backlog": return .gray
        case "todo": return .blue
        case "in-progress": return .indigo
        case "review": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Color Hex Extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
