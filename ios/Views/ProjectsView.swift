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
                    HStack(spacing: 6) {
                        Image(systemName: "leaf")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
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
            .navigationTitle("Graft")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .foregroundStyle(Color.gMuted)
                    }
                }
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
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
        .preferredColorScheme(.dark)
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
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.gInk)
                    Spacer()
                    Text(projectStatusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(projectStatusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(projectStatusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Description
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gMuted)
                        .lineLimit(2)
                }

                // Issue counts
                if let counts = project.issueCounts {
                    let open = counts.backlog + counts.todo + counts.inProgress + counts.review
                    HStack(spacing: 10) {
                        if open > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "circle.dotted")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.gSage)
                                Text("\(open) open")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.gSage)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.gSage.opacity(0.10))
                            .clipShape(Capsule())
                        }
                        if counts.done > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.gTeal)
                                Text("\(counts.done) done")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.gMuted)
                            }
                        }
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
