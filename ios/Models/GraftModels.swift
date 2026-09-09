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
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case issueCounts = "issue_counts"
    }

    var openIssueCount: Int {
        guard let counts = issueCounts else { return 0 }
        return counts.backlog + counts.todo + counts.inProgress + counts.review
    }
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

// MARK: - Cached Data Container

struct GraftCachedData: Codable {
    var projects: [GraftProject]
    var issues: [GraftIssue]
    var milestones: [GraftMilestone]
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

    enum CodingKeys: String, CodingKey {
        case id, method, path, body
        case createdAt = "created_at"
    }
}

// MARK: - String+Identifiable (used for sheet(item:) with status strings)
extension String: @retroactive Identifiable {
    public var id: String { self }
}

extension GraftIssue {
    var statusDisplayName: String {
        switch status {
        case "backlog": return "Backlog"
        case "todo": return "To do"
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
