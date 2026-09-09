import Foundation
import Observation

@MainActor
@Observable
final class GraftStore {

    // MARK: - Published State

    var projects: [GraftProject] = []
    var issues: [GraftIssue] = []
    var milestones: [GraftMilestone] = []
    var isLoading = false
    var lastSynced: Date?
    var errorMessage: String?

    /// Pi server URL. Empty = local-only mode.
    var serverURL: String = "" {
        didSet { saveSettings() }
    }

    var fallbackURL: String = "" {
        didSet { saveSettings() }
    }

    // MARK: - Private

    private let delegate = InsecureSessionDelegate()
    let session: URLSession
    private var api: APIService
    private(set) var syncEngine: SyncEngine

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var dataFileURL: URL { documentsURL.appendingPathComponent("graft_data.json") }
    private var settingsFileURL: URL { documentsURL.appendingPathComponent("graft_settings.json") }

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        let sess = URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        self.session = sess
        self.api = APIService(session: sess)
        self.syncEngine = SyncEngine(session: sess)
        loadSettings()
        loadCachedData()
    }

    // MARK: - ID generation (client-side, matches server format)

    private func newId(_ prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    private func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Persistence helpers

    func saveCachedData() {
        let cached = GraftCachedData(projects: projects, issues: issues, milestones: milestones)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: dataFileURL, options: .atomic)
        }
    }

    private func loadCachedData() {
        guard let data = try? Data(contentsOf: dataFileURL),
              let cached = try? JSONDecoder().decode(GraftCachedData.self, from: data) else { return }
        projects = cached.projects
        issues = cached.issues
        milestones = cached.milestones
    }

    func saveSettings() {
        let settings = GraftSettings(serverURL: serverURL, fallbackURL: fallbackURL)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsFileURL)
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let settings = try? JSONDecoder().decode(GraftSettings.self, from: data) else { return }
        serverURL = settings.serverURL
        fallbackURL = settings.fallbackURL
    }

    // MARK: - Active base URL (nil = no server configured)

    private var activeBase: String? {
        let url = serverURL.trimmingCharacters(in: .whitespaces)
        return url.isEmpty ? nil : url
    }

    // MARK: - Flush pending ops to server

    func flushPending() async {
        guard let base = activeBase else { return }
        await syncEngine.flush(to: base)
        // After flush, pull latest from server to reconcile
        if syncEngine.pendingCount == 0 {
            try? await fetchAll(from: base)
            lastSynced = Date()
            saveCachedData()
        }
    }

    // MARK: - Full server sync (pull only — used when coming back online)

    func sync() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // First flush any pending writes
        if let base = activeBase {
            await syncEngine.flush(to: base)
        }

        // Then pull
        let bases: [String] = [activeBase, fallbackURL.isEmpty ? nil : fallbackURL].compactMap { $0 }
        for base in bases {
            do {
                try await fetchAll(from: base)
                lastSynced = Date()
                saveCachedData()
                errorMessage = nil
                return
            } catch { }
        }

        if activeBase != nil {
            errorMessage = "Can't reach server — showing local data."
        }
    }

    private func fetchAll(from base: String) async throws {
        async let p: [GraftProject] = api.get("\(base)/api/projects")
        // archived=1 returns archived AND live issues. Without it
        // archivedIssues(for:) can never return anything, and the project
        // screen's "show archived" filter has nothing to show.
        async let i: [GraftIssue] = api.get("\(base)/api/issues?archived=1")
        async let m: [GraftMilestone] = api.get("\(base)/api/milestones")
        let (fp, fi, fm) = try await (p, i, m)
        projects = fp
        issues = fi
        milestones = fm
    }

    // MARK: - PROJECTS CRUD (local-first)

    func createProject(name: String, description: String, colour: String, icon: String = "", status: String = "active") async throws {
        let ts = nowISO()
        let project = GraftProject(
            id: newId("proj_"),
            name: name,
            description: description,
            status: status,
            colour: colour,
            icon: icon,
            archived: false,
            createdAt: ts,
            updatedAt: ts,
            issueCounts: nil
        )
        projects.append(project)
        saveCachedData()

        let body = try JSONEncoder().encode([
            "id": project.id, "name": name, "description": description,
            "colour": colour, "status": status, "icon": icon,
            "created_at": ts, "updated_at": ts
        ])
        syncEngine.enqueue(method: "POST", path: "/api/projects", body: body)
        await flushPending()
    }

    func updateProject(_ project: GraftProject) async throws {
        let ts = nowISO()
        var updated = project
        updated.updatedAt = ts
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = updated
        }
        saveCachedData()

        let bodyDict: [String: String] = [
            "name": project.name, "description": project.description,
            "colour": project.colour, "status": project.status, "icon": project.icon,
            "updated_at": ts
        ]
        let body = try JSONEncoder().encode(bodyDict)
        syncEngine.enqueue(method: "PUT", path: "/api/projects/\(project.id)", body: body)
        await flushPending()
    }

    func archiveProject(id: String) async throws {
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].archived.toggle()
        }
        saveCachedData()
        syncEngine.enqueue(method: "PATCH", path: "/api/projects/\(id)/archive")
        await flushPending()
    }

    func deleteProject(id: String) async throws {
        projects.removeAll { $0.id == id }
        issues.removeAll { $0.projectId == id }
        milestones.removeAll { $0.projectId == id }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/projects/\(id)")
        await flushPending()
    }

    // MARK: - ISSUES CRUD (local-first)

    func createIssue(
        projectId: String,
        title: String,
        description: String,
        status: String = "backlog",
        priority: String = "normal",
        milestoneId: String? = nil,
        assignee: String = "",
        labels: [String] = []
    ) async throws {
        let ts = nowISO()
        let issue = GraftIssue(
            id: newId("iss_"),
            projectId: projectId,
            milestoneId: milestoneId,
            milestoneName: milestones.first(where: { $0.id == milestoneId })?.name,
            title: title,
            description: description,
            status: status,
            priority: priority,
            labels: labels,
            assignee: assignee,
            sortOrder: issues.filter { $0.projectId == projectId }.count,
            archived: false,
            createdAt: ts,
            updatedAt: ts
        )
        issues.append(issue)
        saveCachedData()

        var bodyDict: [String: Any] = [
            "id": issue.id, "project_id": projectId,
            "title": title, "description": description,
            "status": status, "priority": priority,
            "assignee": assignee, "labels": labels,
            "sort_order": issue.sortOrder,
            "created_at": ts, "updated_at": ts
        ]
        if let mid = milestoneId { bodyDict["milestone_id"] = mid }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        syncEngine.enqueue(method: "POST", path: "/api/issues", body: body)
        await flushPending()
    }

    func updateIssue(_ issue: GraftIssue) async throws {
        let ts = nowISO()
        var updated = issue
        updated.updatedAt = ts
        // Update milestone name for display
        updated.milestoneName = milestones.first(where: { $0.id == issue.milestoneId })?.name
        if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
            issues[idx] = updated
        }
        saveCachedData()

        var bodyDict: [String: Any] = [
            "title": issue.title, "description": issue.description,
            "status": issue.status, "priority": issue.priority,
            "assignee": issue.assignee, "labels": issue.labels,
            "updated_at": ts
        ]
        // Explicit null, so clearing a milestone actually clears it.
        bodyDict["milestone_id"] = issue.milestoneId ?? NSNull()
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        syncEngine.enqueue(method: "PUT", path: "/api/issues/\(issue.id)", body: body)
        await flushPending()
    }

    func updateIssueStatus(id: String, status: String) async throws {
        guard let idx = issues.firstIndex(where: { $0.id == id }) else { return }
        var updated = issues[idx]
        updated.status = status
        updated.updatedAt = nowISO()
        issues[idx] = updated
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "title": updated.title, "description": updated.description,
            "status": status, "priority": updated.priority,
            "assignee": updated.assignee, "labels": updated.labels,
            "updated_at": updated.updatedAt
        ] as [String: Any])
        syncEngine.enqueue(method: "PUT", path: "/api/issues/\(id)", body: body)
        await flushPending()
    }

    func archiveIssue(id: String) async throws {
        if let idx = issues.firstIndex(where: { $0.id == id }) {
            issues[idx].archived.toggle()
        }
        saveCachedData()
        syncEngine.enqueue(method: "PATCH", path: "/api/issues/\(id)/archive")
        await flushPending()
    }

    func deleteIssue(id: String) async throws {
        issues.removeAll { $0.id == id }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/issues/\(id)")
        await flushPending()
    }

    // MARK: - MILESTONES CRUD (local-first)

    func createMilestone(projectId: String, name: String, description: String, dueDate: String? = nil) async throws {
        let ts = nowISO()
        let milestone = GraftMilestone(
            id: newId("ms_"),
            projectId: projectId,
            name: name,
            description: description,
            dueDate: dueDate,
            createdAt: ts,
            updatedAt: ts
        )
        milestones.append(milestone)
        saveCachedData()

        var bodyDict: [String: Any] = [
            "id": milestone.id, "project_id": projectId,
            "name": name, "description": description,
            "created_at": ts, "updated_at": ts
        ]
        if let due = dueDate { bodyDict["due_date"] = due }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        syncEngine.enqueue(method: "POST", path: "/api/milestones", body: body)
        await flushPending()
    }

    func updateMilestone(_ milestone: GraftMilestone) async throws {
        let ts = nowISO()
        var updated = milestone
        updated.updatedAt = ts
        if let idx = milestones.firstIndex(where: { $0.id == milestone.id }) {
            milestones[idx] = updated
        }
        saveCachedData()

        var bodyDict: [String: Any] = [
            "name": milestone.name, "description": milestone.description,
            "updated_at": ts
        ]
        if let due = milestone.dueDate { bodyDict["due_date"] = due }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        syncEngine.enqueue(method: "PUT", path: "/api/milestones/\(milestone.id)", body: body)
        await flushPending()
    }

    func deleteMilestone(id: String) async throws {
        milestones.removeAll { $0.id == id }
        // Unlink issues
        for idx in issues.indices where issues[idx].milestoneId == id {
            issues[idx].milestoneId = nil
            issues[idx].milestoneName = nil
        }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/milestones/\(id)")
        await flushPending()
    }

    // MARK: - Convenience queries

    /// Issues that still want attention, most urgent first. Backs the Inbox.
    func inbox(assignee: String? = nil) -> [GraftIssue] {
        issues
            .filter { !$0.archived && $0.status != "done" }
            .filter { assignee == nil || $0.assignee == assignee }
            .sorted { a, b in
                let rank = ["urgent": 0, "high": 1, "normal": 2, "low": 3]
                let ra = rank[a.priority] ?? 2, rb = rank[b.priority] ?? 2
                if ra != rb { return ra < rb }
                return a.updatedAt > b.updatedAt
            }
    }

    func project(_ id: String) -> GraftProject? {
        projects.first { $0.id == id }
    }

    func milestone(_ id: String?) -> GraftMilestone? {
        guard let id else { return nil }
        return milestones.first { $0.id == id }
    }

    /// Everyone with something assigned, for the Inbox scope picker.
    var assignees: [String] {
        Array(Set(issues.filter { !$0.assignee.isEmpty }.map(\.assignee))).sorted()
    }

    func issues(for projectId: String) -> [GraftIssue] {
        issues.filter { $0.projectId == projectId && !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func archivedIssues(for projectId: String) -> [GraftIssue] {
        issues.filter { $0.projectId == projectId && $0.archived }
    }

    func milestones(for projectId: String) -> [GraftMilestone] {
        milestones.filter { $0.projectId == projectId }
    }
}
