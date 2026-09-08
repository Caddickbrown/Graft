import SwiftUI

struct ProjectsView: View {
    @Environment(GraftStore.self) private var store
    @State private var showNewProject = false
    @State private var searchText = ""
    @State private var pendingDelete: GraftProject?
    @State private var undo: UndoAction?

    /// Issues that would go with a project, so the confirmation can say so.
    private func issueCount(_ project: GraftProject) -> Int {
        store.issues.filter { $0.projectId == project.id }.count
    }

    private func archive(_ project: GraftProject) {
        Task {
            try? await store.archiveProject(id: project.id)
            undo = UndoAction(message: project.archived ? "Project unarchived" : "Project archived") {
                try? await store.archiveProject(id: project.id)
            }
        }
    }

    var filteredProjects: [GraftProject] {
        if searchText.isEmpty { return store.projects }
        return store.projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color.gBg.ignoresSafeArea()

                Group {
                    if store.projects.isEmpty && store.isLoading {
                        ProgressView()
                            .tint(Color.gSage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.projects.isEmpty {
                        GraftEmptyState(
                            title: "No projects yet",
                            subtitle: "Time to get grafting.",
                            systemImage: "leaf"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(filteredProjects) { project in
                                NavigationLink(destination: ProjectDetailView(project: project)) {
                                    ProjectCardView(project: project)
                                }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = project
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        archive(project)
                                    } label: {
                                        Label(project.archived ? "Unarchive" : "Archive",
                                              systemImage: "archivebox")
                                    }
                                    .tint(Color.gSage)
                                }
                            }
                            // No .onDelete here on purpose. A left swipe used to
                            // call deleteProject directly, destroying the project
                            // and cascading every issue in it with no confirmation
                            // and no way back.
                            .onDelete { _ in }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .searchable(text: $searchText, prompt: "Search projects")
                        .refreshable {
                            await store.sync()
                        }
                    }
                }

                // FAB
                Button {
                    showNewProject = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.gOnAccent)
                        .frame(width: 56, height: 56)
                        .background(Color.gAmber, in: Circle())
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                }
                .accessibilityLabel("New project")
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Graft")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                            .tint(Color.gAmber)
                    } else {
                        Button {
                            Task { await store.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.gAmber)
                        }
                    }
                }
            }
            .sheet(isPresented: $showNewProject) {
                NewProjectView()
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete project?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let project = pendingDelete {
                    Button("Delete project and \(issueCount(project)) issues", role: .destructive) {
                        Task { try? await store.deleteProject(id: project.id) }
                        pendingDelete = nil
                    }
                    Button("Archive instead") {
                        archive(project)
                        pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let project = pendingDelete {
                    Text("This cannot be undone. Archiving keeps \(project.name) and its \(issueCount(project)) issues, just out of the way.")
                }
            }
            .undoBanner($undo)
            .overlay(alignment: .bottom) {
                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.gInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.gRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: store.errorMessage)
        }
    }
}

// MARK: - Project Card

struct ProjectCardView: View {
    let project: GraftProject

    var projectStatusColor: Color {
        switch project.status {
        case "active": return .gSage
        case "paused": return .gAmber
        case "done": return .gTeal
        default: return .gMuted
        }
    }

    var projectStatusLabel: String {
        switch project.status {
        case "active": return "active"
        case "paused": return "paused"
        case "done": return "done"
        default: return project.status
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left colour strip
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: project.colour))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Name + status
                HStack(alignment: .firstTextBaseline) {
                    if !project.icon.isEmpty {
                        Text(project.icon)
                            .font(.system(size: 18))
                    }
                    Text(project.name)
                        .font(.system(size: GraftType.title, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Spacer()
                    Text(projectStatusLabel)
                        .font(.system(size: GraftType.caption, weight: .medium))
                        .foregroundStyle(projectStatusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(projectStatusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Description
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.system(size: GraftType.secondary))
                        .foregroundStyle(Color.gMuted)
                        .lineLimit(2)
                }

                // Progress — "how far along" rather than two raw numbers
                if let counts = project.issueCounts {
                    let open = counts.backlog + counts.todo + counts.inProgress + counts.review
                    let total = open + counts.done
                    if total > 0 {
                        HStack(spacing: 10) {
                            GeometryReader { geo in
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.gTeal)
                                        .frame(width: geo.size.width * CGFloat(counts.done) / CGFloat(total))
                                    Rectangle().fill(Color.gAmber)
                                        .frame(width: geo.size.width * CGFloat(counts.inProgress) / CGFloat(total))
                                    Rectangle().fill(Color.gSurface2)
                                }
                            }
                            .frame(height: 6)
                            .clipShape(Capsule())

                            Text("\(open) open · \(counts.done) done")
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(Color.gMuted)
                                .fixedSize()
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(counts.done) of \(total) done")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gHairline, lineWidth: 0.5)
        )
    }
}
