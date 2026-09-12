import Foundation
import Observation

@MainActor
@Observable
final class GraftStore {

    // MARK: - Published State

    var projects: [GraftProject] = []
    var issues: [GraftIssue] = []
    var milestones: [GraftMilestone] = []
    var areas: [GraftArea] = []
    var links: [GraftLink] = []
    var savedViews: [GraftSavedView] = []
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

    // MARK: - Persisted view state
    //
    // Filter, sort and grouping used to be `@State` on a pushed view, so
    // leaving a project and coming back reset every choice. The web client
    // persists its equivalent, so these live in the store and on disk.

    var inboxQuery = IssueQuery() { didSet { saveViewState() } }

    /// Per-project, keyed by project id — narrowing one project's board has
    /// never meant narrowing another's.
    var projectQueries: [String: IssueQuery] = [:] { didSet { saveViewState() } }

    var projectScope: ProjectScope = .active { didSet { saveViewState() } }

    /// Board or list, per project. Not part of the saved-view blob — it is how
    /// you like to look at one project, not a query, and the web client has no
    /// equivalent to sync it with.
    var projectViewModes: [String: String] = [:] { didSet { saveViewState() } }

    /// Areas the user has folded shut on the Projects tab.
    var collapsedAreaIds: Set<String> = [] { didSet { saveViewState() } }

    /// The whole of the above, as one file.
    private struct ViewState: Codable {
        var inboxQuery: IssueQuery?
        var projectQueries: [String: IssueQuery]?
        var projectScope: String?
        var collapsedAreaIds: [String]?
        var projectViewModes: [String: String]?
    }

    // MARK: - Private

    let session: URLSession
    private var api: APIService
    private(set) var syncEngine: SyncEngine

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var dataFileURL: URL { documentsURL.appendingPathComponent("graft_data.json") }
    private var settingsFileURL: URL { documentsURL.appendingPathComponent("graft_settings.json") }
    private var viewStateFileURL: URL { documentsURL.appendingPathComponent("graft_view_state.json") }

    // MARK: - Init

    init() {
        // A plain session: no trust delegate, so certificates are validated the
        // way iOS validates them. See the note at the top of APIService.swift —
        // the Pi's mkcert root is trusted by installing it on the device, not by
        // the app waving it through.
        let config = URLSessionConfiguration.default
        let sess = URLSession(configuration: config)
        self.session = sess
        self.api = APIService(session: sess)
        self.syncEngine = SyncEngine(session: sess)
        loadSettings()
        loadCachedData()
        loadViewState()
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
        let cached = GraftCachedData(
            projects: projects,
            issues: issues,
            milestones: milestones,
            areas: areas,
            links: links,
            savedViews: savedViews
        )
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
        // Written by a build that predates these — an absent list is empty,
        // not a reason to throw the whole cache away.
        areas = cached.areas ?? []
        links = cached.links ?? []
        savedViews = cached.savedViews ?? []
    }

    // MARK: - View state persistence

    private func saveViewState() {
        let state = ViewState(
            inboxQuery: inboxQuery,
            projectQueries: projectQueries,
            projectScope: projectScope.rawValue,
            collapsedAreaIds: Array(collapsedAreaIds),
            projectViewModes: projectViewModes
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: viewStateFileURL, options: .atomic)
        }
    }

    private func loadViewState() {
        guard let data = try? Data(contentsOf: viewStateFileURL),
              let state = try? JSONDecoder().decode(ViewState.self, from: data) else { return }
        inboxQuery = state.inboxQuery ?? IssueQuery()
        projectQueries = state.projectQueries ?? [:]
        projectScope = ProjectScope(rawValue: state.projectScope ?? "") ?? .active
        collapsedAreaIds = Set(state.collapsedAreaIds ?? [])
        projectViewModes = state.projectViewModes ?? [:]
    }

    /// The saved query for one project, defaulting to "everything, manual order".
    func projectQuery(_ projectId: String) -> IssueQuery {
        projectQueries[projectId] ?? IssueQuery()
    }

    func setProjectQuery(_ query: IssueQuery, for projectId: String) {
        projectQueries[projectId] = query
    }

    func isAreaCollapsed(_ areaId: String) -> Bool {
        collapsedAreaIds.contains(areaId)
    }

    func toggleArea(_ areaId: String) {
        if collapsedAreaIds.contains(areaId) {
            collapsedAreaIds.remove(areaId)
        } else {
            collapsedAreaIds.insert(areaId)
        }
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
        // archived=1 returns archived AND live projects. Without it an archived
        // project simply vanishes on the next pull — no way to see it, and no
        // way to unarchive it from the phone. The views filter it out instead.
        async let p: [GraftProject] = api.get("\(base)/api/projects?archived=1")
        // archived=1 returns archived AND live issues. Without it
        // archivedIssues(for:) can never return anything, and the project
        // screen's "show archived" filter has nothing to show.
        async let i: [GraftIssue] = api.get("\(base)/api/issues?archived=1")
        async let m: [GraftMilestone] = api.get("\(base)/api/milestones")
        async let a: [GraftArea] = api.get("\(base)/api/areas")
        async let l: [GraftLink] = api.get("\(base)/api/links")
        async let v: [GraftSavedView] = api.get("\(base)/api/views")

        let (fp, fi, fm) = try await (p, i, m)
        projects = fp
        issues = fi
        milestones = fm

        // Areas, links and saved views are additive. A server that has not been
        // updated yet answers 404 for all three, and that must not stop the
        // projects and issues that *did* arrive from landing — nor make `sync()`
        // fall through to the fallback URL and report the Pi as unreachable.
        // Whatever is already cached stays until a real answer replaces it.
        areas = (try? await a) ?? areas
        links = (try? await l) ?? links
        savedViews = (try? await v) ?? savedViews
    }

    // MARK: - Search / filter against the server

    /// Re-pulls issues through the server's own `q`, filter and sort params.
    ///
    /// The client filters locally as well, so the list is right offline and
    /// updates as you type. This exists so a search also reaches issues the
    /// phone has *not* cached, and so the server does the work when it can. It
    /// upserts rather than replaces: a narrowed response must not delete the
    /// rest of the cache.
    func refreshIssues(matching query: IssueQuery) async {
        guard let base = activeBase else { return }
        let url = "\(base)/api/issues?\(query.serverQueryString())"
        guard let found: [GraftIssue] = try? await api.get(url) else { return }
        var merged = issues
        // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter traps on a
        // duplicate id, and a crash is not an acceptable response to a server
        // that answered twice for the same row.
        var indexById = Dictionary(
            merged.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { _, later in later }
        )
        for issue in found {
            if let idx = indexById[issue.id] {
                merged[idx] = issue
            } else {
                indexById[issue.id] = merged.count
                merged.append(issue)
            }
        }
        issues = merged
        saveCachedData()
        errorMessage = nil
    }

    // MARK: - PROJECTS CRUD (local-first)

    func createProject(
        name: String,
        description: String,
        colour: String,
        icon: String = "",
        status: String = "active",
        areaId: String = "",
        tags: [String] = []
    ) async throws {
        let ts = nowISO()
        let project = GraftProject(
            id: newId("proj_"),
            name: name,
            description: description,
            status: status,
            colour: colour,
            icon: icon,
            areaId: areaId,
            tags: tags,
            archived: false,
            createdAt: ts,
            updatedAt: ts,
            issueCounts: nil
        )
        projects.append(project)
        saveCachedData()

        let bodyDict: [String: Any] = [
            "id": project.id, "name": name, "description": description,
            "colour": colour, "status": status, "icon": icon,
            "area_id": areaId, "tags": tags,
            "created_at": ts, "updated_at": ts
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
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

        let bodyDict: [String: Any] = [
            "name": project.name, "description": project.description,
            "colour": project.colour, "status": project.status, "icon": project.icon,
            // Always sent, never omitted: the server writes only the keys the
            // payload carries, so leaving it out would make "move to No area"
            // impossible to express.
            "area_id": project.areaKey,
            "tags": project.tagList,
            "updated_at": ts
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
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
        // Explicit null, so turning "Set due date" off actually clears it. The
        // server writes only the keys the payload carries, so an omitted
        // due_date leaves the old date in place — see updateIssue's milestone_id.
        bodyDict["due_date"] = milestone.dueDate ?? NSNull()
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

    // MARK: - AREAS CRUD (local-first)

    func createArea(name: String, colour: String = "") async throws {
        let ts = nowISO()
        let area = GraftArea(
            id: newId("area_"),
            name: name,
            colour: colour,
            sortOrder: areas.count
        )
        areas.append(area)
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "id": area.id, "name": name, "colour": colour,
            "sort_order": area.sortOrder,
            "created_at": ts, "updated_at": ts
        ] as [String: Any])
        syncEngine.enqueue(method: "POST", path: "/api/areas", body: body)
        await flushPending()
    }

    func updateArea(_ area: GraftArea) async throws {
        if let idx = areas.firstIndex(where: { $0.id == area.id }) {
            areas[idx] = area
        }
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "name": area.name, "colour": area.colour,
            "sort_order": area.sortOrder,
            "updated_at": nowISO()
        ] as [String: Any])
        syncEngine.enqueue(method: "PUT", path: "/api/areas/\(area.id)", body: body)
        await flushPending()
    }

    /// Deleting an area un-files its projects; it never deletes them. The local
    /// half of that is done here so the Projects tab is right immediately,
    /// rather than only after the next pull.
    func deleteArea(id: String) async throws {
        areas.removeAll { $0.id == id }
        for idx in projects.indices where projects[idx].areaKey == id {
            projects[idx].areaId = ""
        }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/areas/\(id)")
        await flushPending()
    }

    // MARK: - LINKS CRUD (local-first)

    func createLink(projectId: String, label: String, url: String, kind: String) async throws {
        let ts = nowISO()
        let link = GraftLink(
            id: newId("link_"),
            projectId: projectId,
            label: label,
            url: url,
            kind: kind,
            sortOrder: links.filter { $0.projectId == projectId }.count
        )
        links.append(link)
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "id": link.id, "project_id": projectId,
            "label": label, "url": url, "kind": kind,
            "sort_order": link.sortOrder,
            "created_at": ts, "updated_at": ts
        ] as [String: Any])
        syncEngine.enqueue(method: "POST", path: "/api/links", body: body)
        await flushPending()
    }

    func updateLink(_ link: GraftLink) async throws {
        if let idx = links.firstIndex(where: { $0.id == link.id }) {
            links[idx] = link
        }
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "label": link.label, "url": link.url, "kind": link.kind,
            "sort_order": link.sortOrder,
            "updated_at": nowISO()
        ] as [String: Any])
        syncEngine.enqueue(method: "PUT", path: "/api/links/\(link.id)", body: body)
        await flushPending()
    }

    func deleteLink(id: String) async throws {
        links.removeAll { $0.id == id }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/links/\(id)")
        await flushPending()
    }

    // MARK: - SAVED VIEWS CRUD (local-first)

    /// The blob is stored verbatim so a view round-trips between the clients
    /// unchanged — see `GraftSavedView`.
    func createSavedView(name: String, query: IssueQuery) async throws {
        let ts = nowISO()
        let view = GraftSavedView(
            id: newId("view_"),
            name: name,
            query: query.jsonString(),
            sortOrder: savedViews.count
        )
        savedViews.append(view)
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "id": view.id, "name": name, "query": view.query,
            "sort_order": view.sortOrder,
            "created_at": ts, "updated_at": ts
        ] as [String: Any])
        syncEngine.enqueue(method: "POST", path: "/api/views", body: body)
        await flushPending()
    }

    func updateSavedView(_ view: GraftSavedView) async throws {
        if let idx = savedViews.firstIndex(where: { $0.id == view.id }) {
            savedViews[idx] = view
        }
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: [
            "name": view.name, "query": view.query,
            "sort_order": view.sortOrder,
            "updated_at": nowISO()
        ] as [String: Any])
        syncEngine.enqueue(method: "PUT", path: "/api/views/\(view.id)", body: body)
        await flushPending()
    }

    func deleteSavedView(id: String) async throws {
        savedViews.removeAll { $0.id == id }
        saveCachedData()
        syncEngine.enqueue(method: "DELETE", path: "/api/views/\(id)")
        await flushPending()
    }

    // MARK: - Convenience queries

    /// Issues that still want attention, most urgent first. Backs the Inbox.
    ///
    /// Archiving a project used to leave its issues in the Inbox forever: the
    /// project vanished from the Projects tab and its work carried on nagging
    /// from a screen with no way to act on it.
    func inbox(assignee: String? = nil) -> [GraftIssue] {
        issues
            .filter { !$0.archived && $0.status != "done" }
            .filter { !isProjectArchived($0.projectId) }
            .filter { assignee == nil || $0.assignee == assignee }
            .sorted { a, b in
                let rank = ["urgent": 0, "high": 1, "normal": 2, "low": 3]
                let ra = rank[a.priority] ?? 2, rb = rank[b.priority] ?? 2
                if ra != rb { return ra < rb }
                return a.updatedAt > b.updatedAt
            }
    }

    /// An issue whose project has not synced yet is not hidden — only one whose
    /// project is known and known to be archived.
    private func isProjectArchived(_ projectId: String) -> Bool {
        project(projectId)?.archived ?? false
    }

    func project(_ id: String) -> GraftProject? {
        projects.first { $0.id == id }
    }

    func milestone(_ id: String?) -> GraftMilestone? {
        guard let id else { return nil }
        return milestones.first { $0.id == id }
    }

    func area(_ id: String?) -> GraftArea? {
        guard let id, !id.isEmpty else { return nil }
        return areas.first { $0.id == id }
    }

    /// Areas in their stored order, with ties broken by name so the list does
    /// not shuffle when every `sort_order` is the default 0.
    var sortedAreas: [GraftArea] {
        areas.sorted {
            $0.sortOrder == $1.sortOrder
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.sortOrder < $1.sortOrder
        }
    }

    func links(for projectId: String) -> [GraftLink] {
        links
            .filter { $0.projectId == projectId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Everyone with something assigned, for the Inbox scope picker.
    var assignees: [String] {
        Array(Set(issues.filter { !$0.assignee.isEmpty }.map(\.assignee))).sorted()
    }

    /// Every label in use anywhere, for the filter sheet.
    var allLabels: [String] {
        Array(Set(issues.flatMap(\.labels).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

    /// How many issues a milestone is attached to. Deleting it strips it from
    /// every one of them, so the confirmation says the number out loud.
    func issueCount(usingMilestone id: String) -> Int {
        issues.filter { $0.milestoneId == id }.count
    }

    // MARK: - The query engine (client-side)
    //
    // The server can do all of this too, and `refreshIssues(matching:)` asks it
    // to. It is repeated here because the app is local-first: filtering has to
    // work with no server at all, and has to update on the keystroke rather
    // than on the round trip.

    func apply(_ query: IssueQuery, to source: [GraftIssue]) -> [GraftIssue] {
        let needle = query.q.trimmingCharacters(in: .whitespaces).lowercased()
        let f = query.filters

        let filtered = source.filter { issue in
            if !query.archived && issue.archived { return false }
            if !f.status.isEmpty && !f.status.contains(issue.status) { return false }
            if !f.priority.isEmpty && !f.priority.contains(issue.priority) { return false }
            if !f.assignee.isEmpty {
                // "" is the sentinel the filter sheet uses for Unassigned.
                if !f.assignee.contains(issue.assignee) { return false }
            }
            if !f.label.isEmpty && !issue.labels.contains(where: { f.label.contains($0) }) { return false }
            if !f.projectId.isEmpty && !f.projectId.contains(issue.projectId) { return false }
            if !f.milestoneId.isEmpty {
                // "none" is the contract's sentinel for "has no milestone".
                let mid = issue.milestoneId ?? ""
                let wantsNone = f.milestoneId.contains("none")
                if !(f.milestoneId.contains(mid) || (wantsNone && mid.isEmpty)) { return false }
            }
            if !f.areaId.isEmpty {
                let areaKey = project(issue.projectId)?.areaKey ?? ""
                if !f.areaId.contains(areaKey) { return false }
            }
            if !needle.isEmpty && !matches(issue, needle) { return false }
            return true
        }

        return sort(filtered, by: query.sort, dir: query.dir)
    }

    /// The same fields the server's `q` covers: title, description, assignee,
    /// labels and the issue id.
    private func matches(_ issue: GraftIssue, _ needle: String) -> Bool {
        if issue.title.lowercased().contains(needle) { return true }
        if issue.description.lowercased().contains(needle) { return true }
        if issue.assignee.lowercased().contains(needle) { return true }
        if issue.id.lowercased().contains(needle) { return true }
        return issue.labels.contains { $0.lowercased().contains(needle) }
    }

    private func sort(_ source: [GraftIssue], by mode: IssueSort, dir: IssueSortDirection) -> [GraftIssue] {
        let ascending = dir == .asc
        // Ranks, not raw strings: "urgent" sorts after "high" alphabetically,
        // which is the opposite of what priority means.
        let priorityRank = ["urgent": 0, "high": 1, "normal": 2, "low": 3]
        let statusRank = ["backlog": 0, "todo": 1, "in-progress": 2, "review": 3, "done": 4]

        let sorted = source.sorted { a, b in
            switch mode {
            case .manual:
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.id < b.id
            case .updated:
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                return a.id < b.id
            case .created:
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            case .title:
                let c = a.title.localizedCaseInsensitiveCompare(b.title)
                if c != .orderedSame { return c == .orderedAscending }
                return a.id < b.id
            case .priority:
                let ra = priorityRank[a.priority] ?? 2
                let rb = priorityRank[b.priority] ?? 2
                if ra != rb { return ra < rb }
                return a.id < b.id
            case .status:
                let ra = statusRank[a.status] ?? 0
                let rb = statusRank[b.status] ?? 0
                if ra != rb { return ra < rb }
                return a.id < b.id
            case .milestoneDue:
                // Nulls last in *ascending* order, matching the server. The
                // sentinel sorts after any real yyyy-MM-dd string.
                let da = milestone(a.milestoneId)?.dueDate ?? "~"
                let db = milestone(b.milestoneId)?.dueDate ?? "~"
                if da != db { return da < db }
                return a.id < b.id
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    /// Groups an already-filtered, already-sorted list. Group order is the
    /// natural order of the dimension (status by workflow, priority by urgency)
    /// rather than alphabetical, and the "none" bucket always comes last.
    func groups(_ issues: [GraftIssue], by grouping: IssueGrouping) -> [IssueGroup] {
        switch grouping {
        case .none:
            return [IssueGroup(id: "all", title: "", issues: issues)]

        case .status:
            return ["backlog", "todo", "in-progress", "review", "done"].compactMap { status -> IssueGroup? in
                let bucket = issues.filter { $0.status == status }
                guard !bucket.isEmpty else { return nil }
                return IssueGroup(id: status,
                                  title: IssueStatus(rawValue: status)?.label ?? status,
                                  issues: bucket)
            }

        case .priority:
            return ["urgent", "high", "normal", "low"].compactMap { priority -> IssueGroup? in
                let bucket = issues.filter { $0.priority == priority }
                guard !bucket.isEmpty else { return nil }
                return IssueGroup(id: priority,
                                  title: IssuePriority(rawValue: priority)?.label ?? priority,
                                  issues: bucket)
            }

        case .assignee:
            return bucketed(issues, key: { $0.assignee }, title: { $0.isEmpty ? "Unassigned" : $0 })

        case .milestone:
            return bucketed(issues,
                            key: { $0.milestoneId ?? "" },
                            title: { key in self.milestone(key)?.name ?? "No milestone" })

        case .project:
            return bucketed(issues,
                            key: { $0.projectId },
                            title: { key in self.project(key)?.name ?? "Unknown project" })

        case .area:
            return bucketed(issues,
                            key: { issue in self.project(issue.projectId)?.areaKey ?? "" },
                            title: { key in self.area(key)?.name ?? "No area" })
        }
    }

    /// Buckets by an arbitrary key, keeping first-seen order and pushing the
    /// empty key ("unassigned", "no milestone", "no area") to the end.
    private func bucketed(
        _ issues: [GraftIssue],
        key: (GraftIssue) -> String,
        title: (String) -> String
    ) -> [IssueGroup] {
        var order: [String] = []
        var buckets: [String: [GraftIssue]] = [:]
        for issue in issues {
            let k = key(issue)
            if buckets[k] == nil {
                buckets[k] = []
                order.append(k)
            }
            buckets[k]?.append(issue)
        }
        let empties = order.filter { $0.isEmpty }
        let named = order.filter { !$0.isEmpty }
        return (named + empties).map { k in
            IssueGroup(id: k.isEmpty ? "__none" : k, title: title(k), issues: buckets[k] ?? [])
        }
    }

    // MARK: - Telling the truth about syncing

    /// Whether a write actually went anywhere, for the surface that made it.
    enum WriteOutcome: Equatable {
        /// No server linked. The change is on this phone, and that is all.
        case localOnly
        /// Written locally and waiting in the queue for a reachable server.
        case queued(Int)
        /// The server has it.
        case synced
        /// The queue gave up on it. It is never going to be sent.
        case failed(String)
    }

    /// What became of the most recent write to `path`.
    ///
    /// `updateIssue` and friends are local-first and cannot throw, so a screen
    /// that reports "Saved" on their return is reporting that it managed to
    /// call a function. This reads the queue instead.
    func outcome(forPath path: String) -> WriteOutcome {
        if let dropped = syncEngine.droppedOps.last(where: { $0.path == path }) {
            return .failed(dropped.reason)
        }
        // "No server" is checked before "queued" on purpose. Every write is
        // enqueued whether or not a server exists, so a local-only user would
        // otherwise be told their edit is "waiting to sync" forever, when in
        // fact it is exactly where they asked it to be.
        if activeBase == nil { return .localOnly }
        if syncEngine.pendingOps.contains(where: { $0.path == path }) {
            return .queued(syncEngine.pendingCount)
        }
        return .synced
    }

    /// How the app as a whole is doing at reaching the server. Drives the sync
    /// strip and the tab badge; `errorMessage` used to be read on exactly one
    /// of five screens.
    enum ConnectionState: Equatable {
        case noServer
        case syncing
        case pending(Int)
        case failed(String)
        case unreachable(String)
        case ok
    }

    var connection: ConnectionState {
        if activeBase == nil && fallbackURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return .noServer
        }
        if isLoading { return .syncing }
        if let dropped = syncEngine.droppedOps.last { return .failed(dropped.reason) }
        if let error = errorMessage { return .unreachable(error) }
        if syncEngine.pendingCount > 0 { return .pending(syncEngine.pendingCount) }
        return .ok
    }

    var pendingCount: Int { syncEngine.pendingCount }

    /// Pending writes, for the tab-bar badge. Zero when nothing is linked: with
    /// no server those ops are not waiting on anything, and a permanently
    /// growing badge on a deliberately local-only app is noise, not news. The
    /// sync strip says "Local only" in that case instead.
    var pendingBadgeCount: Int {
        connection == .noServer ? 0 : syncEngine.pendingCount
    }

    /// True on a fresh install with nothing linked and nothing created — the
    /// one case that must not be dressed up as a healthy empty state.
    var isFirstRun: Bool {
        connection == .noServer && projects.isEmpty && issues.isEmpty
    }
}
