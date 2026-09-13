import Foundation

// MARK: - Flexible Bool

/// Decodes a boolean from either a JSON bool (`true`/`false`) or an integer
/// (`0`/`1`). The Graft backend stores flags in SQLite and serialises them as
/// integers, so a plain `Bool` would fail to decode.
@propertyWrapper
struct FlexibleBool: Codable, Hashable {
    var wrappedValue: Bool

    init(wrappedValue: Bool) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            wrappedValue = bool
        } else if let int = try? container.decode(Int.self) {
            wrappedValue = int != 0
        } else {
            wrappedValue = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// MARK: - GraftProject

struct GraftProject: Codable, Identifiable {
    let id: String
    var name: String
    var description: String
    var status: String // active/paused/done
    var colour: String // hex string
    var icon: String
    /// The area this project is filed under, `nil`/`""` meaning unfiled.
    ///
    /// Optional rather than a plain `String` on purpose: a synthesised decoder
    /// treats a missing key as an error for a non-optional, so a server that
    /// has not run the `area_id` migration yet would fail the *whole* projects
    /// array and empty the app. An optional simply decodes as `nil`.
    var areaId: String?
    var tags: [String]?
    @FlexibleBool var archived: Bool
    var createdAt: String
    var updatedAt: String
    var issueCounts: IssueCounts?

    struct IssueCounts: Codable {
        var backlog: Int
        var todo: Int
        var inProgress: Int
        var review: Int
        var done: Int
        var total: Int

        enum CodingKeys: String, CodingKey {
            case backlog, todo, review, done, total
            case inProgress = "in_progress"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, colour, icon, archived, tags
        case areaId = "area_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case issueCounts = "issue_counts"
    }

    var tagList: [String] { tags ?? [] }

    var openIssueCount: Int {
        guard let counts = issueCounts else { return 0 }
        return counts.backlog + counts.todo + counts.inProgress + counts.review
    }

    /// `areaId` normalised for dictionary keys and comparisons — the server
    /// writes `''` for unfiled and older rows decode as `nil`, and those two
    /// must not read as different areas.
    var areaKey: String { areaId ?? "" }
}

// MARK: - GraftMilestone

struct GraftMilestone: Codable, Identifiable {
    let id: String
    var projectId: String
    var name: String
    var description: String
    var dueDate: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case projectId = "project_id"
        case dueDate = "due_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - GraftIssue

struct GraftIssue: Codable, Identifiable {
    let id: String
    var projectId: String
    var milestoneId: String?
    var milestoneName: String?
    var title: String
    var description: String
    var status: String // backlog/todo/in-progress/review/done
    var priority: String // urgent/high/normal/low
    var labels: [String]
    var assignee: String
    /// `yyyy-MM-dd`, `""` for "no date". The server stores `''` rather than
    /// NULL for both dates — see the migration note in `app.py` — so `""` is
    /// the only empty this ever has to recognise.
    var startAt: String
    var dueAt: String
    /// An RRULE subset, `""` for "does not repeat". See `Recurrence`.
    var recurrence: String
    /// `schedule` or `completion`. Never a third state on a real row: an issue
    /// that recurs always has an anchor, and the column defaults to `schedule`.
    var recurrenceAnchor: String
    /// The id of the series root; `""` on the root itself.
    var recurrenceParent: String
    var sortOrder: Int
    @FlexibleBool var archived: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, labels, assignee, archived, recurrence
        case projectId = "project_id"
        case milestoneId = "milestone_id"
        case milestoneName = "milestone_name"
        case startAt = "start_at"
        case dueAt = "due_at"
        case recurrenceAnchor = "recurrence_anchor"
        case recurrenceParent = "recurrence_parent"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        projectId: String,
        milestoneId: String? = nil,
        milestoneName: String? = nil,
        title: String,
        description: String,
        status: String,
        priority: String,
        labels: [String],
        assignee: String,
        startAt: String = "",
        dueAt: String = "",
        recurrence: String = "",
        recurrenceAnchor: String = "schedule",
        recurrenceParent: String = "",
        sortOrder: Int,
        archived: Bool,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.projectId = projectId
        self.milestoneId = milestoneId
        self.milestoneName = milestoneName
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.labels = labels
        self.assignee = assignee
        self.startAt = startAt
        self.dueAt = dueAt
        self.recurrence = recurrence
        self.recurrenceAnchor = recurrenceAnchor
        self.recurrenceParent = recurrenceParent
        self.sortOrder = sortOrder
        self._archived = FlexibleBool(wrappedValue: archived)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Hand-written for the same reason `GraftArea.init(from:)` is, but with the
    /// whole app at stake rather than one tab.
    ///
    /// This was the synthesised decoder, which treats an absent key as an error
    /// for any non-optional property. The moment the scheduling fields were
    /// added as non-optional `String`s, every response from a server that has
    /// not run the migration — and every `graft_data.json` written by the build
    /// before this one — would fail to decode *as a whole array*, and the issues
    /// list would go empty with nothing on screen to explain it. Only `id` is
    /// required below; everything else falls back.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        /// `decodeIfPresent` throws on an explicit `null` for a non-optional
        /// type, so the new columns — which a hand-edited or pre-default row
        /// can hold as NULL — go through `try?` as well as `??`.
        func text(_ key: CodingKeys, _ fallback: String) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? fallback
        }
        id = try c.decode(String.self, forKey: .id)
        projectId = text(.projectId, "")
        milestoneId = (try? c.decodeIfPresent(String.self, forKey: .milestoneId)) ?? nil
        milestoneName = (try? c.decodeIfPresent(String.self, forKey: .milestoneName)) ?? nil
        title = text(.title, "")
        description = text(.description, "")
        status = text(.status, "backlog")
        priority = text(.priority, "normal")
        labels = ((try? c.decodeIfPresent([String].self, forKey: .labels)) ?? nil) ?? []
        assignee = text(.assignee, "")
        startAt = text(.startAt, "")
        dueAt = text(.dueAt, "")
        recurrence = text(.recurrence, "")
        recurrenceAnchor = text(.recurrenceAnchor, "schedule")
        recurrenceParent = text(.recurrenceParent, "")
        sortOrder = ((try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? nil) ?? 0
        _archived = ((try? c.decodeIfPresent(FlexibleBool.self, forKey: .archived)) ?? nil)
            ?? FlexibleBool(wrappedValue: false)
        createdAt = text(.createdAt, "")
        updatedAt = text(.updatedAt, "")
    }

    /// True when this issue carries a rule. A spawned occurrence carries it
    /// too, so the series is visible from any member of it — which is what the
    /// server's `?recurring=true` means as well.
    var repeats: Bool { !recurrence.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The series this issue belongs to. `recurrence_parent` is `""` on the
    /// root, so the root is its own series.
    var seriesRoot: String { recurrenceParent.isEmpty ? id : recurrenceParent }
}

// MARK: - Issue mutation response
//
// `PUT /api/issues/:id` answered with the issue and nothing else. A PUT that
// moves a *recurring* issue to `done` now answers with the issue **plus** a
// `spawned` key carrying its replacement, because the server archives the one
// you finished and creates the next occurrence in the same request.
//
// Decoding that straight into `GraftIssue` would not throw — Codable ignores
// keys it has no property for — but it would drop the new occurrence on the
// floor, and the board would keep showing the finished one until a full pull.
// So the decode target is this, and it tolerates `spawned` being absent, null
// or something this build cannot read, because none of those are a reason for
// a completion to read as a failed write.

struct GraftIssueMutation: Decodable {
    /// The issue as it now stands — archived, when a replacement was spawned.
    let issue: GraftIssue
    /// The next occurrence, when this write completed a recurring issue.
    let spawned: GraftIssue?

    private enum SpawnKeys: String, CodingKey { case spawned }

    init(from decoder: Decoder) throws {
        issue = try GraftIssue(from: decoder)
        let c = try decoder.container(keyedBy: SpawnKeys.self)
        spawned = ((try? c.decodeIfPresent(GraftIssue.self, forKey: .spawned)) ?? nil)
    }
}

// MARK: - GraftIssueSeries
//
// `GET /api/issues/:id/series`. Archived rows are included and not optional —
// a completed occurrence *is* archived, so a series that hid them would be
// almost entirely empty and would answer the opposite of the question asked.

struct GraftIssueSeries: Decodable {
    let root: String
    let count: Int
    let completed: Int
    let issues: [GraftIssue]

    enum CodingKeys: String, CodingKey { case root, count, completed, issues }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        issues = try c.decodeIfPresent([GraftIssue].self, forKey: .issues) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? issues.count
        completed = try c.decodeIfPresent(Int.self, forKey: .completed)
            ?? issues.filter { $0.status == "done" }.count
    }
}

// MARK: - GraftNotification
//
// One row of `GET /api/notifications`: what a client should be telling the user
// and when. The server ranks nothing — it returns everything in `fire_at`
// order — because only the client knows about iOS's 64-pending cap. The ranking
// lives in `NotificationScheduler`.
//
// `fire_at` is UTC, and whole-day dates have had a 09:00 (08:00 for the digest)
// time attached server-side. Scheduling it as written would fire at the wrong
// hour everywhere but Greenwich.

struct GraftNotification: Decodable, Identifiable, Hashable {
    let id: String
    /// `""` on a digest row, which is about the day rather than any one issue.
    var issueId: String
    /// due | starting | overdue | assigned | digest
    var kind: String
    var fireAt: String
    var deliveredAt: String?
    var dismissedAt: String?
    /// Joined from the issue by the server, so the scheduler can write a useful
    /// body without the issue being cached. Absent on a digest row.
    var issueTitle: String?
    var issueStatus: String?
    var issuePriority: String?
    var issueProjectId: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case issueId = "issue_id"
        case fireAt = "fire_at"
        case deliveredAt = "delivered_at"
        case dismissedAt = "dismissed_at"
        case issueTitle = "issue_title"
        case issueStatus = "issue_status"
        case issuePriority = "issue_priority"
        case issueProjectId = "issue_project_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)
        }
        id = try c.decode(String.self, forKey: .id)
        issueId = text(.issueId) ?? ""
        kind = text(.kind) ?? ""
        fireAt = text(.fireAt) ?? ""
        deliveredAt = text(.deliveredAt)
        dismissedAt = text(.dismissedAt)
        issueTitle = text(.issueTitle)
        issueStatus = text(.issueStatus)
        issuePriority = text(.issuePriority)
        issueProjectId = text(.issueProjectId)
    }

    var isHandled: Bool { deliveredAt != nil || dismissedAt != nil }
}

// MARK: - GraftDigest
//
// `GET /api/digest`. A plain read with no side effects: it answers "what does
// today look like", which is a question about issues, and asking it must not
// rewrite the notifications table.

struct GraftDigest: Decodable {
    var date: String
    var assignee: String
    var dueToday: [GraftIssue]
    var startingToday: [GraftIssue]
    var overdue: [GraftIssue]
    var inReview: [GraftIssue]
    /// Empty unless `?assignee=` was sent — without a "you" there is nobody to
    /// be waiting on anyone, and the server returns nothing rather than guess.
    var waitingOnYou: [GraftIssue]
    var counts: Counts

    struct Counts: Decodable {
        var dueToday: Int = 0
        var startingToday: Int = 0
        var overdue: Int = 0
        var inReview: Int = 0
        var waitingOnYou: Int = 0

        enum CodingKeys: String, CodingKey {
            case overdue
            case dueToday = "due_today"
            case startingToday = "starting_today"
            case inReview = "in_review"
            case waitingOnYou = "waiting_on_you"
        }

        init() { }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dueToday = try c.decodeIfPresent(Int.self, forKey: .dueToday) ?? 0
            startingToday = try c.decodeIfPresent(Int.self, forKey: .startingToday) ?? 0
            overdue = try c.decodeIfPresent(Int.self, forKey: .overdue) ?? 0
            inReview = try c.decodeIfPresent(Int.self, forKey: .inReview) ?? 0
            waitingOnYou = try c.decodeIfPresent(Int.self, forKey: .waitingOnYou) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case date, assignee, overdue, counts
        case dueToday = "due_today"
        case startingToday = "starting_today"
        case inReview = "in_review"
        case waitingOnYou = "waiting_on_you"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        dueToday = try c.decodeIfPresent([GraftIssue].self, forKey: .dueToday) ?? []
        startingToday = try c.decodeIfPresent([GraftIssue].self, forKey: .startingToday) ?? []
        overdue = try c.decodeIfPresent([GraftIssue].self, forKey: .overdue) ?? []
        inReview = try c.decodeIfPresent([GraftIssue].self, forKey: .inReview) ?? []
        waitingOnYou = try c.decodeIfPresent([GraftIssue].self, forKey: .waitingOnYou) ?? []
        counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
    }
}

// MARK: - GraftArea
//
// The project grouping. A project belongs to at most one area; `""` is
// "No area" and is not a row — it is the absence of one.

struct GraftArea: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var colour: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, colour
        case sortOrder = "sort_order"
    }

    init(id: String, name: String, colour: String = "", sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colour = colour
        self.sortOrder = sortOrder
    }

    /// Hand-written so that only `id` and `name` are actually required. Every
    /// other column has a server-side default, and a single absent key must not
    /// take the whole areas list — and with it the Projects tab's grouping —
    /// down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colour = try c.decodeIfPresent(String.self, forKey: .colour) ?? ""
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

// MARK: - GraftLink
//
// A related URL, hanging off an owner: a project, or — since links stopped
// being project-only — an issue. This replaces the half-built
// `projects.repo_url`, which the server still stores but neither client shows.

struct GraftLink: Codable, Identifiable, Hashable {
    let id: String
    /// The project this link is pinned to, or `""` when an issue owns it.
    /// Kept because the column is still what the server writes for a project
    /// link and what an older build reads; `ownerType`/`ownerId` are the pair
    /// to reason with.
    var projectId: String
    /// `project` or `issue`. Not an enum on purpose, for the same reason `kind`
    /// is not one: a server that grows a third owner must not make this client
    /// fail to decode the rows it already understands.
    var ownerType: String
    var ownerId: String
    var label: String
    var url: String
    /// github | docs | design | deploy | hub | link — only a glyph hint, never
    /// validated, so an unknown value simply falls back to the generic link.
    var kind: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, label, url, kind
        case projectId = "project_id"
        case ownerType = "owner_type"
        case ownerId = "owner_id"
        case sortOrder = "sort_order"
    }

    init(id: String, ownerType: String, ownerId: String, label: String, url: String,
         kind: String = "link", sortOrder: Int = 0) {
        self.id = id
        self.ownerType = ownerType
        self.ownerId = ownerId
        // Derived, never passed in, so it can never disagree with the owner —
        // the same rule the server follows when it writes the row.
        self.projectId = ownerType == "project" ? ownerId : ""
        self.label = label
        self.url = url
        self.kind = kind
        self.sortOrder = sortOrder
    }

    /// See `GraftArea.init(from:)` — tolerant of columns a given server build
    /// has not grown yet.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "link"
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        // A row from a server that predates owners, or one cached on this phone
        // before this build, has neither field. It can only ever have been a
        // project link, and project_id is exactly what says which project.
        ownerType = try c.decodeIfPresent(String.self, forKey: .ownerType) ?? "project"
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId) ?? projectId
    }

    /// True when this points at something in the user's own system rather than
    /// at a page on the web. Nothing here resolves it — Graft has no idea what
    /// Hub holds, and a guess would be worse than not knowing.
    var isHub: Bool { GraftLinkKind.isHubURL(url) }

    /// The second line of a link row. A host is the useful half of a web URL —
    /// a 90-character deploy preview tells the reader nothing — but a hub
    /// address has no host worth reading (`hub://people/tom` parses as host
    /// "people"), so it keeps everything but the scheme, which is the part a
    /// person recognises.
    var host: String {
        if isHub {
            return String(url.trimmingCharacters(in: .whitespaces).dropFirst("hub://".count))
        }
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - GraftSavedView
//
// `query` is the opaque JSON blob both clients agree on (see `IssueQuery`), so
// a view saved on the web opens on the phone and vice versa. Stored as the raw
// string rather than a decoded `IssueQuery` so a blob written by a newer client
// survives a round trip through this one unchanged.

struct GraftSavedView: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var query: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, query
        case sortOrder = "sort_order"
    }

    init(id: String, name: String, query: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.query = query
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? "{}"
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

// MARK: - Cached Data Container

struct GraftCachedData: Codable {
    var projects: [GraftProject]
    var issues: [GraftIssue]
    var milestones: [GraftMilestone]
    /// Optional so a cache file written before areas/links/views existed still
    /// decodes. A cache that fails to decode is every project on the phone
    /// disappearing on upgrade.
    var areas: [GraftArea]?
    var links: [GraftLink]?
    var savedViews: [GraftSavedView]?

    enum CodingKeys: String, CodingKey {
        case projects, issues, milestones, areas, links
        case savedViews = "saved_views"
    }
}

// MARK: - Settings Container

struct GraftSettings: Codable {
    var serverURL: String
    var fallbackURL: String
}

// MARK: - Pending Operation (offline queue)

struct PendingOperation: Codable, Identifiable {
    let id: String          // uuid
    let method: String      // POST / PUT / DELETE / PATCH
    let path: String        // e.g. /api/issues/iss_abc123
    let body: Data?         // JSON-encoded body, nil for DELETE
    let createdAt: Date
    /// Flushes that tried this op and failed for a retryable reason. Retrying a
    /// transient failure is right; retrying without limit is how one unlucky
    /// request wedges the whole queue, so `SyncEngine` caps this.
    var attempts: Int

    enum CodingKeys: String, CodingKey {
        case id, method, path, body, attempts
        case createdAt = "created_at"
    }

    init(id: String, method: String, path: String, body: Data?, createdAt: Date, attempts: Int = 0) {
        self.id = id
        self.method = method
        self.path = path
        self.body = body
        self.createdAt = createdAt
        self.attempts = attempts
    }

    /// Hand-written purely so `attempts` may be absent: queues written by an
    /// earlier build have no such key, and a queue that fails to decode is a
    /// queue of silently discarded edits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        method = try c.decode(String.self, forKey: .method)
        path = try c.decode(String.self, forKey: .path)
        body = try c.decodeIfPresent(Data.self, forKey: .body)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}

// MARK: - Dropped Operation (queue gave up)

/// An op the queue stopped trying to send. Kept only so the app can say what
/// was thrown away — an edit that quietly never reached the server is worse
/// than one the user is told about.
struct DroppedOperation: Codable, Identifiable {
    let id: String
    let method: String
    let path: String
    let reason: String
    let droppedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, method, path, reason
        case droppedAt = "dropped_at"
    }
}

// MARK: - String+Identifiable (used for sheet(item:) with status strings)
extension String: @retroactive Identifiable {
    public var id: String { self }
}

extension GraftIssue {
    var statusDisplayName: String {
        switch status {
        // "Todo", not "To do": the web client, the design system's
        // `IssueStatus.label` and the board column headers all say Todo, and
        // this was the one surface that disagreed.
        case "backlog": return "Backlog"
        case "todo": return "Todo"
        case "in-progress": return "In progress"
        case "review": return "Review"
        case "done": return "Done"
        default: return status
        }
    }

    var priorityDisplayName: String {
        switch priority {
        case "urgent": return "Urgent"
        case "high": return "High"
        case "normal": return "Normal"
        case "low": return "Low"
        default: return priority
        }
    }
}

extension GraftProject {
    var statusDisplayName: String {
        switch status {
        case "active": return "Active"
        case "paused": return "Paused"
        case "done": return "Done"
        default: return status
        }
    }
}
