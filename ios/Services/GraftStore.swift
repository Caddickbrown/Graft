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

    /// The replacement the server made the last time a recurring issue was
    /// completed. Set by `applySpawn`, read by whichever screen is showing so
    /// it can say "next one due Sunday" rather than leaving the completion
    /// looking like the issue simply vanished. Cleared once said.
    var lastSpawned: GraftIssue?

    /// Pi server URL. Empty = local-only mode.
    var serverURL: String = "" {
        didSet {
            saveSettings()
            // Unlinking a server has to take its notifications with it. They
            // are about rows on a machine this phone no longer talks to, and
            // nothing else would ever cancel them: `reschedule` returns early
            // with no base, so the pending set would simply keep firing for as
            // long as iOS held it. `clearAll` is documented as the answer to
            // exactly this; nothing called it.
            if serverURL.trimmingCharacters(in: .whitespaces).isEmpty,
               !oldValue.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { await self.notifications.clearAll() }
            }
        }
    }

    var fallbackURL: String = "" {
        didSet { saveSettings() }
    }

    // MARK: - Persisted view state
    //
    // Filter, sort and grouping used to be `@State` on a pushed view, so
    // leaving a project and coming back reset every choice. The web client
    // persists its equivalent, so these live in the store and on disk.

    // Every one of these is `private(set)`, and every change to one goes
    // through a method below that writes the file afterwards. They used to be
    // freely settable with a `didSet { saveViewState() }` on each, which looks
    // like it says the same thing and does not: an observer is reached by
    // assigning the *whole* property, and half of these are never assigned
    // whole. `projectViewModes[id] = "List"`, `collapsedAreaIds.insert(id)`
    // and `inboxQuery.q = text` are in-place mutations of the value inside the
    // property, and under `@Observable` — where the property is no longer a
    // plain stored one — that is not a path anything can rely on the observer
    // seeing. The board/list choice was the visible half of it: chosen, shown,
    // and gone by the next launch.
    //
    // Closing that off entirely is worth more than the convenience: with the
    // setter private there is no way to change one of these and forget to save
    // it, which is the bug rather than any particular missing call.

    private(set) var inboxQuery = IssueQuery()

    /// Per-project, keyed by project id — narrowing one project's board has
    /// never meant narrowing another's.
    private(set) var projectQueries: [String: IssueQuery] = [:]

    private(set) var projectScope: ProjectScope = .active

    /// Board or list, per project. Not part of the saved-view blob — it is how
    /// you like to look at one project, not a query, and the web client has no
    /// equivalent to sync it with.
    private(set) var projectViewModes: [String: String] = [:]

    /// The last board/list choice made anywhere, used for a project you have
    /// not expressed one for. Opening a new project on the board when you work
    /// in the list all day is the same complaint as the choice not sticking,
    /// one project along.
    private(set) var lastViewMode: String = ""

    /// Areas the user has folded shut on the Projects tab.
    private(set) var collapsedAreaIds: Set<String> = []

    /// The whole of the above, as one file.
    private struct ViewState: Codable {
        var inboxQuery: IssueQuery?
        var projectQueries: [String: IssueQuery]?
        var projectScope: String?
        var collapsedAreaIds: [String]?
        var projectViewModes: [String: String]?
        var lastViewMode: String?
    }

    // MARK: - Private

    let session: URLSession
    private var api: APIService
    private(set) var syncEngine: SyncEngine
    /// Local notifications, rebuilt on every successful pull. Owned here
    /// because it needs the same base URL and the same `APIService`, and
    /// because the digest line it schedules is written from this cache.
    private(set) var notifications = NotificationScheduler()

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
        // The queue now hands back what the server said. The only answer this
        // app reads is the one a completed recurring issue carries; see
        // `applyMutation`. `[weak self]` because the engine is owned by the
        // store, and a strong capture here is a cycle that never drains.
        syncEngine.onResponse = { [weak self] op, data in
            self?.applyMutation(op, data)
        }
    }

    // MARK: - ID generation (client-side, matches server format)

    private func newId(_ prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    /// A timestamp in the server's own format: naive UTC with microseconds and
    /// no zone designator, which is what `datetime.utcnow().isoformat()` writes.
    ///
    /// `ISO8601DateFormatter` writes `2026-09-18T12:34:56Z`, and the POST and
    /// PUT handlers store whatever the client sends them verbatim, so one column
    /// ended up holding two formats. Everything that orders by `created_at` or
    /// `updated_at` — the Inbox, "last updated", the series view — compares them
    /// as text, and `…T12:34:56Z` sorts *after* `…T12:34:57.000001`, so a row
    /// written on the phone jumped ahead of one written a second later on the
    /// web. Built per call rather than held in a `static`: a `DateFormatter` is
    /// not `Sendable`, and this is the shape the rest of the app uses too.
    private func nowISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f.string(from: Date())
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
            projectViewModes: projectViewModes,
            lastViewMode: lastViewMode
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
        lastViewMode = state.lastViewMode ?? ""
    }

    /// Write the view state out now, whatever has happened to it.
    ///
    /// Called when the app leaves the foreground. Everything below saves as it
    /// goes, so this is belt and braces — but it is cheap, it is the one moment
    /// the system will tell us about before the app is taken away, and "it did
    /// not survive me leaving the app" is exactly the report this is here to
    /// make impossible.
    func flushViewState() { saveViewState() }

    /// The saved query for one project, defaulting to "everything, manual order".
    func projectQuery(_ projectId: String) -> IssueQuery {
        projectQueries[projectId] ?? IssueQuery()
    }

    func setProjectQuery(_ query: IssueQuery, for projectId: String) {
        projectQueries[projectId] = query
        saveViewState()
    }

    func setInboxQuery(_ query: IssueQuery) {
        inboxQuery = query
        saveViewState()
    }

    func setProjectScope(_ scope: ProjectScope) {
        projectScope = scope
        saveViewState()
    }

    // MARK: Board or list

    /// How this project was last looked at: its own choice, or the last one
    /// made anywhere, or the board.
    func viewMode(for projectId: String) -> String {
        if let chosen = projectViewModes[projectId], !chosen.isEmpty { return chosen }
        return lastViewMode
    }

    func setViewMode(_ mode: String, for projectId: String) {
        projectViewModes[projectId] = mode
        lastViewMode = mode
        saveViewState()
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
        saveViewState()
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
        // After flush, pull latest from server to reconcile — but only once the
        // queue is empty, or the pull would overwrite writes still waiting to
        // go out.
        guard syncEngine.pendingCount == 0 else { return }
        do {
            try await fetchAll(from: base)
            // Stamped only on the pull that actually landed. `try?` used to
            // swallow the failure and set it anyway, so Settings reported a
            // successful sync at a moment when the phone and the Pi had not
            // spoken — which is precisely the question that line answers.
            lastSynced = Date()
            saveCachedData()
        } catch {
            // Nothing to report here: the caller of a background flush has no
            // banner, and `connection` already reads the queue and the last
            // flush error for the sync strip.
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

        // And pull only if that emptied the queue.
        //
        // A pull replaces projects, issues, milestones and the rest wholesale,
        // so running one over un-flushed writes puts the server's version of a
        // row the phone has already changed back on screen: the optimistic edit
        // vanishes under the user, and the obvious response is to tap it again —
        // which cancels the queued toggle and leaves the two ends disagreeing
        // for good. `flushPending` has always had this guard; `sync()` did not.
        //
        // Nothing is said here that the sync strip does not already say: it
        // reads the queue itself and offers a Retry that flushes. The last
        // flush error is handed over, so an unreachable server still reads as
        // unreachable rather than as a queue that is merely taking its time.
        if syncEngine.pendingCount > 0 {
            errorMessage = syncEngine.lastFlushError
            return
        }

        // Then pull
        let bases: [String] = [activeBase, fallbackURL.isEmpty ? nil : fallbackURL].compactMap { $0 }
        for base in bases {
            do {
                try await fetchAll(from: base)
                lastSynced = Date()
                saveCachedData()
                errorMessage = nil
                // After the pull, not before: the digest line is written from
                // the issues that just landed, and a notification set built
                // from yesterday's cache would name yesterday's work.
                await rescheduleNotifications(base: base)
                return
            } catch { }
        }

        if activeBase != nil {
            errorMessage = "Can't reach server — showing local data."
        }
    }

    // MARK: - Local notifications

    /// Rebuilds the pending notification set. Rebuild, not append: a due date
    /// that moved has to take its notification with it.
    func rescheduleNotifications(base: String? = nil) async {
        guard let target = base ?? activeBase else { return }
        await notifications.reschedule(base: target, api: api, digestBody: digestLine)
    }

    /// What the daily digest notification says, written from the cache the
    /// phone already has. The server's digest row carries no issue of its own,
    /// and "your summary is ready" is not worth waking a phone for.
    var digestLine: String {
        let open = inbox()
        let overdue = overdueCount(in: open)
        let today = dueTodayCount(in: open)
        var bits: [String] = []
        if overdue > 0 { bits.append("\(overdue) overdue") }
        if today > 0 { bits.append("\(today) due today") }
        if bits.isEmpty {
            return open.isEmpty ? "Nothing waiting." : "\(open.count) open, nothing due."
        }
        return bits.joined(separator: " · ")
    }

    /// A freshly pulled list, with any row this phone has changed and not yet
    /// managed to send left alone.
    ///
    /// A pull replaces `projects`, `issues` and the rest wholesale, and both
    /// callers check the queue is empty before starting one. That check happens
    /// *before* six HTTP requests, though, and the user can tap something while
    /// they are in the air — which is exactly what pinning a project on a phone
    /// with a slow or absent connection looks like. The star flipped, the PATCH
    /// queued, and then the in-flight pull landed and put the server's older row
    /// back: the pin vanished under the user, while the queued write went on to
    /// pin it on the server, so the *next* pull pinned it again out of nowhere.
    ///
    /// The rule is the one a local-first app needs everywhere: while a write
    /// against a row is still queued, this phone's copy of that row is the
    /// newer one, and the server's answer is stale by definition. Rows created
    /// here and not yet sent are kept for the same reason — they are not
    /// missing from the server's answer, they have simply never been offered
    /// to it.
    private func reconcile<T: Identifiable>(
        _ fromServer: [T],
        with local: [T],
        pathPrefix: String
    ) -> [T] where T.ID == String {
        let pending = syncEngine.pendingPaths
        guard !pending.isEmpty else { return fromServer }

        func isPending(_ id: String) -> Bool {
            let path = pathPrefix + id
            return pending.contains { $0 == path || $0.hasPrefix(path + "/") }
        }

        let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = fromServer.map { row in
            isPending(row.id) ? (localById[row.id] ?? row) : row
        }
        // Anything held back locally that the server has never heard of — a
        // create still sitting in the queue. A POST goes to the collection
        // (`/api/projects`), not to the row, so there is no per-id path to
        // match on and the test has to be "is any create of this kind queued".
        // Appended rather than inserted: where it belongs is whatever the
        // list's own sort says.
        let createsQueued = pending.contains(String(pathPrefix.dropLast()))
        let known = Set(fromServer.map(\.id))
        merged.append(contentsOf: local.filter {
            !known.contains($0.id) && (createsQueued || isPending($0.id))
        })
        return merged
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
        // Read *after* the awaits, deliberately: those six requests are the
        // window in which a local write can arrive, and it is the state as it
        // stands now — cache plus anything tapped while the pull was in the
        // air — that the server's answer has to be reconciled against.
        projects = reconcile(fp, with: projects, pathPrefix: "/api/projects/")
        issues = reconcile(fi, with: issues, pathPrefix: "/api/issues/")
        milestones = reconcile(fm, with: milestones, pathPrefix: "/api/milestones/")

        // Areas, links and saved views are additive. A server that has not been
        // updated yet answers 404 for all three, and that must not stop the
        // projects and issues that *did* arrive from landing — nor make `sync()`
        // fall through to the fallback URL and report the Pi as unreachable.
        // Whatever is already cached stays until a real answer replaces it.
        areas = (try? await a).map { reconcile($0, with: areas, pathPrefix: "/api/areas/") } ?? areas
        links = (try? await l).map { reconcile($0, with: links, pathPrefix: "/api/links/") } ?? links
        savedViews = (try? await v).map { reconcile($0, with: savedViews, pathPrefix: "/api/views/") } ?? savedViews
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
        guard let found = try? await api.issues(base: base, matching: query) else { return }
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

    /// Pin or unpin a project.
    ///
    /// The flip happens here, on this phone's copy, and the request that goes
    /// out afterwards *states the value* rather than asking the server to flip
    /// whatever it has — `PATCH .../favourite` takes a body now, see the
    /// handler. That is what makes pinning work with no signal: a bare toggle
    /// queued on Monday and sent on Thursday lands wherever the server happens
    /// to be by then, whereas "this project is pinned" is true whenever it
    /// arrives and however many times it is retried.
    func favouriteProject(id: String) async throws {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].isFavourite.toggle()
        let wanted = projects[idx].isFavourite
        saveCachedData()
        let body = try JSONSerialization.data(withJSONObject: ["favourite": wanted ? 1 : 0])
        syncEngine.enqueue(method: "PATCH", path: "/api/projects/\(id)/favourite", body: body)
        await flushPending()
    }

    /// Deleting a project takes its issues, milestones and links with it, here
    /// as well as on the server — which drops the orphans for the same reason
    /// it does on `DELETE /api/issues/:id`: nothing reaps them, and a link whose
    /// owner is gone renders as a blank row. Doing it locally too is what keeps
    /// the screen honest between now and the next pull.
    func deleteProject(id: String) async throws {
        let ownedIssues = Set(issues.filter { $0.projectId == id }.map(\.id))
        projects.removeAll { $0.id == id }
        issues.removeAll { $0.projectId == id }
        milestones.removeAll { $0.projectId == id }
        links.removeAll { link in
            (link.ownerType == "project" && link.ownerId == id)
                || (link.ownerType == "issue" && ownedIssues.contains(link.ownerId))
        }
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
        labels: [String] = [],
        startAt: String = "",
        dueAt: String = "",
        recurrence: String = "",
        recurrenceAnchor: String = "schedule"
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
            startAt: startAt,
            dueAt: dueAt,
            recurrence: recurrence,
            recurrenceAnchor: recurrenceAnchor,
            sortOrder: issues.filter { $0.projectId == projectId }.count,
            archived: false,
            createdAt: ts,
            updatedAt: ts
        )
        issues.append(issue)
        // Creating an issue with a name on it is an assignment like any other,
        // and the server records one — see `updateIssue`.
        if !assignee.isEmpty { notifications.noteOwnAssignment(issueId: issue.id) }
        saveCachedData()

        var bodyDict: [String: Any] = [
            "id": issue.id, "project_id": projectId,
            "title": title, "description": description,
            "status": status, "priority": priority,
            "assignee": assignee, "labels": labels,
            // Sent even when empty. The server's rule for a create is
            // absent-means-keep, so omitting them would be right here and wrong
            // on a replay; sending what this client believes is true is right
            // both times.
            "start_at": startAt, "due_at": dueAt,
            "recurrence": recurrence, "recurrence_anchor": recurrenceAnchor,
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
            // The server writes an `assigned` notification row for every
            // assignee change, because nothing downstream can reconstruct the
            // event — but it cannot tell who made the change. This is the one
            // place that knows, so it says so, and the scheduler keeps quiet
            // about a name the user typed on this phone a moment ago. The
            // debounced field on the issue screen writes two or three times,
            // which was two or three buzzes.
            if issues[idx].assignee != updated.assignee {
                notifications.noteOwnAssignment(issueId: issue.id)
            }
            issues[idx] = updated
        }
        saveCachedData()

        let body = try JSONSerialization.data(withJSONObject: issueWriteBody(updated, at: ts))
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

        let body = try JSONSerialization.data(withJSONObject: issueWriteBody(updated, at: updated.updatedAt))
        syncEngine.enqueue(method: "PUT", path: "/api/issues/\(id)", body: body)
        await flushPending()
    }

    /// Move an issue to a status, and to a position inside that status.
    ///
    /// This is what dragging a card on the board does. Both halves are needed:
    /// dropping into another column changes the status, dropping between two
    /// cards changes the order, and dropping into another column *between* two
    /// cards does both.
    ///
    /// `before` names the card the dragged one was dropped on top of, or `nil`
    /// for the end of the column. A position rather than an index because the
    /// board draws a filtered, sorted slice of the project and the index in
    /// that slice is not the index in the project.
    ///
    /// The whole project is renumbered from zero rather than just the cards
    /// that moved. Board order is one sequence across all five columns —
    /// `sort_order` has no per-status namespace on either side of the wire — so
    /// patching one column's numbers in isolation is how two cards end up
    /// claiming the same slot.
    func moveIssue(id: String, toStatus status: String, before target: String?) async throws {
        guard let moving = issues.first(where: { $0.id == id }) else { return }
        guard target != id else { return }
        let projectId = moving.projectId
        let statusChanged = moving.status != status

        // The project's own order, which is what `sort_order` means. Archived
        // issues are in it: they hold numbers too, and skipping them would make
        // every renumber shuffle them to the front.
        var order = issues
            .filter { $0.projectId == projectId }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
            .map(\.id)
        order.removeAll { $0 == id }

        if let target, let at = order.firstIndex(of: target) {
            order.insert(id, at: at)
        } else if let last = order.lastIndex(where: { issueStatus($0) == status }) {
            // Dropped on the column itself: after whatever is already in it.
            order.insert(id, at: last + 1)
        } else {
            order.append(id)
        }

        let ts = nowISO()
        var renumbered: [[String: Any]] = []
        for (position, issueId) in order.enumerated() {
            guard let idx = issues.firstIndex(where: { $0.id == issueId }) else { continue }
            if issues[idx].sortOrder != position {
                issues[idx].sortOrder = position
                renumbered.append(["id": issueId, "sort_order": position])
            }
        }

        if statusChanged, let idx = issues.firstIndex(where: { $0.id == id }) {
            issues[idx].status = status
            issues[idx].updatedAt = ts
        }
        saveCachedData()

        if statusChanged, let updated = issues.first(where: { $0.id == id }) {
            let body = try JSONSerialization.data(withJSONObject: issueWriteBody(updated, at: ts))
            syncEngine.enqueue(method: "PUT", path: "/api/issues/\(id)", body: body)
        }
        if !renumbered.isEmpty {
            let body = try JSONSerialization.data(withJSONObject: ["issues": renumbered])
            syncEngine.enqueue(method: "PATCH", path: "/api/issues/reorder", body: body)
        }
        await flushPending()
    }

    private func issueStatus(_ id: String) -> String {
        issues.first(where: { $0.id == id })?.status ?? ""
    }

    /// The body of every `PUT /api/issues/:id`, whoever is writing.
    ///
    /// It names every editable field, including the ones the screen making the
    /// call has no opinion about, and that is the point. `SyncEngine.enqueue`
    /// drops an earlier queued PUT to the same path on the floor — "the newest
    /// one carries everything the earlier ones said" — which is only true while
    /// every PUT body is a *complete* record. A status change that omitted
    /// `recurrence` would supersede, and silently discard, a recurrence rule
    /// still sitting in the queue behind it. The server's absent-means-keep rule
    /// does not save us: the earlier op is gone before it is ever sent.
    private func issueWriteBody(_ issue: GraftIssue, at ts: String) -> [String: Any] {
        var body: [String: Any] = [
            "title": issue.title, "description": issue.description,
            "status": issue.status, "priority": issue.priority,
            "assignee": issue.assignee, "labels": issue.labels,
            // `""` rather than null for the dates: it is what the server stores
            // for "no date", and a cleared picker must clear the stored value
            // rather than read as absent.
            "start_at": issue.startAt, "due_at": issue.dueAt,
            "recurrence": issue.recurrence,
            "recurrence_anchor": issue.recurrenceAnchor,
            "updated_at": ts
        ]
        // Explicit null, so clearing a milestone actually clears it.
        body["milestone_id"] = issue.milestoneId ?? NSNull()
        return body
    }

    // MARK: - A completion that spawned its replacement

    /// Reads the body of a successful queued write. Only `PUT /api/issues/:id`
    /// says anything this client needs, and only when it completed a recurring
    /// issue.
    private func applyMutation(_ op: PendingOperation, _ data: Data) {
        guard op.method == "PUT",
              op.path.hasPrefix("/api/issues/"),
              // Not a sub-resource: `/api/issues/x/series` is a GET, but
              // `/archive` is a PATCH on a path shaped the same way.
              op.path.dropFirst("/api/issues/".count).contains("/") == false,
              let mutation = try? JSONDecoder().decode(GraftIssueMutation.self, from: data)
        else { return }
        applySpawn(mutation)
    }

    /// Folds a completed recurring issue and its replacement into the cache.
    ///
    /// The server archives the one you finished and creates the next occurrence
    /// in the same request, so without this the board keeps showing the finished
    /// one and the new occurrence stays invisible until a full pull. Mirrors the
    /// web client's `_applySpawn`.
    @discardableResult
    func applySpawn(_ mutation: GraftIssueMutation) -> GraftIssue? {
        guard let spawned = mutation.spawned else { return nil }
        // The server only archives when the series actually continues — a COUNT
        // or UNTIL that has run out leaves the last one sitting there, done — so
        // take the flag from the response rather than assuming it.
        if let idx = issues.firstIndex(where: { $0.id == mutation.issue.id }) {
            issues[idx].archived = mutation.issue.archived
            issues[idx].updatedAt = mutation.issue.updatedAt
        }
        if !issues.contains(where: { $0.id == spawned.id }) {
            issues.append(spawned)
        }
        saveCachedData()
        lastSpawned = spawned
        return spawned
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
        // The server deletes the issue's links with it; without this the phone
        // kept showing them until the next pull.
        links.removeAll { $0.ownerType == "issue" && $0.ownerId == id }
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
            // On the end of this project's list, which is where a new one
            // belongs: a milestone you have just written down is the next
            // thing you thought of, not the next thing that happens.
            sortOrder: milestones.filter { $0.projectId == projectId }.count,
            createdAt: ts,
            updatedAt: ts
        )
        milestones.append(milestone)
        saveCachedData()

        var bodyDict: [String: Any] = [
            "id": milestone.id, "project_id": projectId,
            "name": name, "description": description,
            "sort_order": milestone.sortOrder,
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
            // Always sent, for the reason `issueWriteBody` spells out: the
            // queue drops an earlier PUT to the same path, so every PUT has to
            // be a complete record or a reorder still waiting to go out would
            // be superseded by an edit that never mentioned it.
            "sort_order": milestone.sortOrder,
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

    /// Put this project's milestones in a new order.
    ///
    /// One PUT per milestone rather than a batch endpoint: a project has a
    /// handful of them, each PUT carries the whole record so the queue's
    /// newest-supersedes rule stays honest, and the paths are distinct so two
    /// milestones moved in the same drag cannot collapse into one another. The
    /// numbers are reassigned from zero every time, so gaps left by a deleted
    /// milestone never accumulate.
    func reorderMilestones(projectId: String, orderedIds: [String]) async throws {
        var rank: [String: Int] = [:]
        for (position, id) in orderedIds.enumerated() { rank[id] = position }

        var moved: [GraftMilestone] = []
        for idx in milestones.indices where milestones[idx].projectId == projectId {
            guard let position = rank[milestones[idx].id],
                  milestones[idx].sortOrder != position else { continue }
            milestones[idx].sortOrder = position
            moved.append(milestones[idx])
        }
        guard !moved.isEmpty else { return }
        saveCachedData()

        let ts = nowISO()
        for milestone in moved {
            var bodyDict: [String: Any] = [
                "name": milestone.name, "description": milestone.description,
                "sort_order": milestone.sortOrder,
                "updated_at": ts
            ]
            bodyDict["due_date"] = milestone.dueDate ?? NSNull()
            let body = try JSONSerialization.data(withJSONObject: bodyDict)
            syncEngine.enqueue(method: "PUT", path: "/api/milestones/\(milestone.id)", body: body)
        }
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

    func createLink(ownerType: String, ownerId: String, label: String, url: String, kind: String) async throws {
        let ts = nowISO()
        let link = GraftLink(
            id: newId("link_"),
            ownerType: ownerType,
            ownerId: ownerId,
            label: label,
            url: url,
            kind: kind,
            sortOrder: links.filter { $0.ownerType == ownerType && $0.ownerId == ownerId }.count
        )
        links.append(link)
        saveCachedData()

        // project_id goes out alongside the owner pair rather than instead of
        // it, so a body that has been sitting in the offline queue still lands
        // correctly on a server that has not been updated yet — there it reads
        // as the project link it used to be, and the two extra keys are ignored.
        let body = try JSONSerialization.data(withJSONObject: [
            "id": link.id,
            "owner_type": ownerType, "owner_id": ownerId,
            "project_id": link.projectId,
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

    /// A project's own links — never the links on its issues, which is what
    /// the server's `?project_id=` has always meant and what the project screen
    /// has always shown.
    func links(for projectId: String) -> [GraftLink] {
        links(ownerType: "project", ownerId: projectId)
    }

    /// What this issue is connected to: the PR that closes it, the doc it came
    /// out of, the person it is about.
    func links(forIssue issueId: String) -> [GraftLink] {
        links(ownerType: "issue", ownerId: issueId)
    }

    func links(ownerType: String, ownerId: String) -> [GraftLink] {
        links
            .filter { $0.ownerType == ownerType && $0.ownerId == ownerId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Dates

    /// The deadline to show for an issue.
    ///
    /// A milestone's due date used to be the only real deadline in the data, so
    /// "overdue" meant the issue was unfinished and its milestone had passed. An
    /// issue can now carry its own due date, which is the more specific claim
    /// and wins; the milestone stays as the fallback rather than being replaced,
    /// so nothing that was overdue before this existed quietly stopped being so.
    /// The web client's `issueDue` does exactly this.
    func dueDate(for issue: GraftIssue) -> String? {
        if !issue.dueAt.isEmpty { return issue.dueAt }
        return milestone(issue.milestoneId)?.dueDate
    }

    /// Open issues past their due date. Counts, not lists — the summary lines
    /// are the only caller and they only ever say a number.
    func overdueCount(in source: [GraftIssue]) -> Int {
        source.filter { issue in
            guard let days = GraftDate.daysUntil(dueDate(for: issue)) else { return false }
            return days < 0
        }.count
    }

    func dueTodayCount(in source: [GraftIssue]) -> Int {
        source.filter { GraftDate.daysUntil(dueDate(for: $0)) == 0 }.count
    }

    // MARK: - Recurring series

    /// Every occurrence of one issue's series, oldest first.
    ///
    /// Server-only: a completed occurrence is archived, and while the phone does
    /// cache archived rows, it only has the ones some earlier pull happened to
    /// bring back. The endpoint is the one thing that knows the series is
    /// complete. Returns nil when there is no server or it cannot be reached,
    /// which the view renders as its own state rather than as an empty series.
    func series(forIssue id: String) async -> GraftIssueSeries? {
        guard let base = activeBase else { return nil }
        return try? await api.series(base: base, issueId: id)
    }

    /// What the phone already knows about a series, for the offline case.
    func cachedSeries(root: String) -> [GraftIssue] {
        issues
            .filter { $0.id == root || $0.recurrenceParent == root }
            .sorted { a, b in
                // Undated last, matching the endpoint's ORDER BY.
                if a.dueAt.isEmpty != b.dueAt.isEmpty { return b.dueAt.isEmpty }
                if a.dueAt != b.dueAt { return a.dueAt < b.dueAt }
                return a.createdAt < b.createdAt
            }
    }

    /// `GET /api/digest` — what a daily summary would say, for one day.
    func digest(date: String? = nil, assignee: String? = nil) async -> GraftDigest? {
        guard let base = activeBase else { return nil }
        return try? await api.digest(base: base, date: date, assignee: assignee)
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
        milestones.filter { $0.projectId == projectId }.sortedForDisplay
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
            // The two date-shaped filters. Mirrored here rather than left to
            // the server for the same reason every other filter is: this has to
            // work offline, and it has to be right on the keystroke.
            if !f.due.matches(issue.dueAt) { return false }
            if !f.repeats.matches(issue) { return false }
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

    // MARK: - What has been typed before
    //
    // Tags and labels are free text on both sides of the wire, which is the
    // right call — nobody wants to administer a taxonomy for their own to-do
    // list — and also how you end up with `ios`, `iOS` and `i-os` all meaning
    // the same thing. The fix is not validation, it is offering what is
    // already there while the user types.

    /// Every tag on every project, most-used first.
    var projectTagVocabulary: [String] {
        Self.rank(projects.flatMap(\.tagList))
    }

    /// Every label on every issue, most-used first. Archived issues count: a
    /// label is no less real for having been used on work that is finished.
    var issueLabelVocabulary: [String] {
        Self.rank(issues.flatMap(\.labels))
    }

    /// Ranked by how often each one appears, ties broken alphabetically so the
    /// list is stable between keystrokes. Case-insensitively deduplicated, with
    /// the most common spelling winning — which is the one thing that actually
    /// pulls `iOS` and `ios` back together over time.
    private static func rank(_ all: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for raw in all {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            counts[key, default: 0] += 1
            spellings[key, default: [:]][value, default: 0] += 1
        }
        return counts.keys
            .sorted { a, b in
                counts[a] == counts[b]
                    ? a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                    : counts[a]! > counts[b]!
            }
            .compactMap { key in
                spellings[key]?.max { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
                }?.key
            }
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
