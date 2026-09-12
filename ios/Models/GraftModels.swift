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
        case id, name, description, status, colour, icon, archived
        case areaId = "area_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case issueCounts = "issue_counts"
    }

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
    var sortOrder: Int
    @FlexibleBool var archived: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, labels, assignee, archived
        case projectId = "project_id"
        case milestoneId = "milestone_id"
        case milestoneName = "milestone_name"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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
// Per-project related URLs. This replaces the half-built `projects.repo_url`,
// which the server still stores but neither client shows any more.

struct GraftLink: Codable, Identifiable, Hashable {
    let id: String
    var projectId: String
    var label: String
    var url: String
    /// github | docs | design | deploy | link — only a glyph hint, never
    /// validated, so an unknown value simply falls back to the generic link.
    var kind: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, label, url, kind
        case projectId = "project_id"
        case sortOrder = "sort_order"
    }

    init(id: String, projectId: String, label: String, url: String, kind: String = "link", sortOrder: Int = 0) {
        self.id = id
        self.projectId = projectId
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
        projectId = try c.decode(String.self, forKey: .projectId)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "link"
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    /// The host, for the second line of a link row. Shown instead of the full
    /// URL because a 90-character deploy preview URL tells the reader nothing.
    var host: String {
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
