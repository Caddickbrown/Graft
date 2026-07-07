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

    var serverURL: String = "http://raspberrypi.local:8911" {
        didSet { saveSettings() }
    }

    var fallbackURL: String = "" {
        didSet { saveSettings() }
    }

    // MARK: - Private

    private let delegate = InsecureSessionDelegate()
    let session: URLSession
    private var api: APIService

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var dataFileURL: URL {
        documentsURL.appendingPathComponent("graft_data.json")
    }

    private var settingsFileURL: URL {
        documentsURL.appendingPathComponent("graft_settings.json")
    }

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        let sess = URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        self.session = sess
        self.api = APIService(session: sess)
        loadSettings()
        loadCachedData()
    }

    // MARK: - Sync

    func sync() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let baseURL = serverURL.isEmpty ? "http://raspberrypi.local:8911" : serverURL

        do {
            try await fetchAll(from: baseURL)
            lastSynced = Date()
            saveCachedData()
            return
        } catch {
            // try fallback
        }

        if !fallbackURL.isEmpty {
            do {
                try await fetchAll(from: fallbackURL)
                lastSynced = Date()
                saveCachedData()
                return
            } catch {
                errorMessage = "Unable to reach server. Showing cached data."
            }
        } else {
            errorMessage = "Unable to reach server. Showing cached data."
        }
    }

    private func fetchAll(from base: String) async throws {
        async let fetchedProjects: [GraftProject] = api.get("\(base)/api/projects")
        async let fetchedIssues: [GraftIssue] = api.get("\(base)/api/issues")
        async let fetchedMilestones: [GraftMilestone] = api.get("\(base)/api/milestones")

        let (p, i, m) = try await (fetchedProjects, fetchedIssues, fetchedMilestones)
        projects = p
        issues = i
        milestones = m
    }

    // MARK: - Projects CRUD

    func createProject(name: String, description: String, colour: String, status: String = "active") async throws {
        let base = activeBase
        let body: [String: String] = [
            "name": name,
            "description": description,
            "colour": colour,
            "status": status
        ]
        // icon defaults to empty on create (can be set via edit)
        let _: GraftProject = try await api.post("\(base)/api/projects", body: body)
        await sync()
    }

    func updateProject(_ project: GraftProject) async throws {
        let base = activeBase
        let body: [String: String] = [
            "name": project.name,
            "description": project.description,
            "colour": project.colour,
            "status": project.status,
            "icon": project.icon,
        ]
        let _: GraftProject = try await api.put("\(base)/api/projects/\(project.id)", body: body)
        await sync()
    }

    func deleteProject(id: String) async throws {
        let base = activeBase
        try await api.delete("\(base)/api/projects/\(id)")
        await sync()
    }

    // MARK: - Issues CRUD

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
        let base = activeBase
        var body: [String: Any] = [
            "project_id": projectId,
            "title": title,
            "description": description,
            "status": status,
            "priority": priority,
            "assignee": assignee,
            "labels": labels
        ]
        if let mid = milestoneId { body["milestone_id"] = mid }
        let data = try JSONSerialization.data(withJSONObject: body)
        let _: GraftIssue = try await postRaw("\(base)/api/issues", data: data)
        await sync()
    }

    func updateIssue(_ issue: GraftIssue) async throws {
        let base = activeBase
        var body: [String: Any] = [
            "title": issue.title,
            "description": issue.description,
            "status": issue.status,
            "priority": issue.priority,
            "assignee": issue.assignee,
            "labels": issue.labels
        ]
        if let mid = issue.milestoneId { body["milestone_id"] = mid }
        let data = try JSONSerialization.data(withJSONObject: body)
        let _: GraftIssue = try await putRaw("\(base)/api/issues/\(issue.id)", data: data)
        await sync()
    }

    func deleteIssue(id: String) async throws {
        let base = activeBase
        try await api.delete("\(base)/api/issues/\(id)")
        await sync()
    }

    // MARK: - Milestones CRUD

    func createMilestone(projectId: String, name: String, description: String, dueDate: String? = nil) async throws {
        let base = activeBase
        var body: [String: Any] = [
            "project_id": projectId,
            "name": name,
            "description": description
        ]
        if let due = dueDate { body["due_date"] = due }
        let data = try JSONSerialization.data(withJSONObject: body)
        let _: GraftMilestone = try await postRaw("\(base)/api/milestones", data: data)
        await sync()
    }

    func updateMilestone(_ milestone: GraftMilestone) async throws {
        let base = activeBase
        var body: [String: Any] = [
            "name": milestone.name,
            "description": milestone.description
        ]
        if let due = milestone.dueDate { body["due_date"] = due }
        let data = try JSONSerialization.data(withJSONObject: body)
        let _: GraftMilestone = try await putRaw("\(base)/api/milestones/\(milestone.id)", data: data)
        await sync()
    }

    func deleteMilestone(id: String) async throws {
        let base = activeBase
        try await api.delete("\(base)/api/milestones/\(id)")
        await sync()
    }

    // MARK: - Helpers

    private var activeBase: String {
        serverURL.isEmpty ? "http://raspberrypi.local:8911" : serverURL
    }

    private func postRaw<T: Decodable>(_ urlString: String, data: Data) async throws -> T {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 10
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private func putRaw<T: Decodable>(_ urlString: String, data: Data) async throws -> T {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 10
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    // MARK: - Persistence

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

    func saveCachedData() {
        let cached = GraftCachedData(projects: projects, issues: issues, milestones: milestones)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: dataFileURL)
        }
    }

    private func loadCachedData() {
        guard let data = try? Data(contentsOf: dataFileURL),
              let cached = try? JSONDecoder().decode(GraftCachedData.self, from: data) else { return }
        projects = cached.projects
        issues = cached.issues
        milestones = cached.milestones
    }

    // MARK: - Convenience

    func issues(for projectId: String) -> [GraftIssue] {
        issues.filter { $0.projectId == projectId }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func milestones(for projectId: String) -> [GraftMilestone] {
        milestones.filter { $0.projectId == projectId }
    }
}
