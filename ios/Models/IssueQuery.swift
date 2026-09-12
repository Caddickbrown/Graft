import Foundation

// MARK: - Sort / group vocabulary
//
// These raw values are part of the saved-view contract, not private detail: a
// view saved on the web client is decoded here by exactly these strings.

enum IssueSort: String, CaseIterable, Codable, Hashable {
    case manual
    case updated
    case created
    case priority
    case title
    case status
    case milestoneDue = "milestone_due"

    var label: String {
        switch self {
        case .manual: return "Manual order"
        case .updated: return "Last updated"
        case .created: return "Created"
        case .priority: return "Priority"
        case .title: return "Title"
        case .status: return "Status"
        case .milestoneDue: return "Milestone due"
        }
    }
}

enum IssueSortDirection: String, CaseIterable, Codable, Hashable {
    case asc
    case desc

    var label: String { self == .asc ? "Ascending" : "Descending" }
}

enum IssueGrouping: String, CaseIterable, Codable, Hashable {
    case none
    case status
    case priority
    case assignee
    case milestone
    case project
    case area

    var label: String {
        switch self {
        case .none: return "No grouping"
        case .status: return "Status"
        case .priority: return "Priority"
        case .assignee: return "Assignee"
        case .milestone: return "Milestone"
        case .project: return "Project"
        case .area: return "Area"
        }
    }
}

// MARK: - IssueQuery
//
// The whole filter/sort/group state, in the one shape both clients agree on:
//
//   { "q": "", "filters": { … }, "archived": false,
//     "sort": "manual", "dir": "asc", "group": "none" }
//
// Every member of it decodes leniently. This blob travels through the server as
// opaque text and may have been written by a newer build of either client, so a
// key this version has never heard of must be ignored and a missing one must
// fall back — never throw, which would make a saved view simply un-openable.

struct IssueQuery: Codable, Equatable {

    struct Filters: Codable, Equatable {
        var status: [String] = []
        var priority: [String] = []
        var assignee: [String] = []
        var label: [String] = []
        var projectId: [String] = []
        var milestoneId: [String] = []
        var areaId: [String] = []

        enum CodingKeys: String, CodingKey {
            case status, priority, assignee, label
            case projectId = "project_id"
            case milestoneId = "milestone_id"
            case areaId = "area_id"
        }

        init() { }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent([String].self, forKey: .status) ?? []
            priority = try c.decodeIfPresent([String].self, forKey: .priority) ?? []
            assignee = try c.decodeIfPresent([String].self, forKey: .assignee) ?? []
            label = try c.decodeIfPresent([String].self, forKey: .label) ?? []
            projectId = try c.decodeIfPresent([String].self, forKey: .projectId) ?? []
            milestoneId = try c.decodeIfPresent([String].self, forKey: .milestoneId) ?? []
            areaId = try c.decodeIfPresent([String].self, forKey: .areaId) ?? []
        }

        /// Nothing selected anywhere — used to tell "no results because of a
        /// filter" apart from "no results because there is nothing".
        var isEmpty: Bool {
            status.isEmpty && priority.isEmpty && assignee.isEmpty && label.isEmpty
                && projectId.isEmpty && milestoneId.isEmpty && areaId.isEmpty
        }

        var activeCount: Int {
            status.count + priority.count + assignee.count + label.count
                + projectId.count + milestoneId.count + areaId.count
        }
    }

    var q: String = ""
    var filters = Filters()
    var archived: Bool = false
    var sort: IssueSort = .manual
    var dir: IssueSortDirection = .asc
    var group: IssueGrouping = .none

    enum CodingKeys: String, CodingKey {
        case q, filters, archived, sort, dir, group
    }

    init() { }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        q = try c.decodeIfPresent(String.self, forKey: .q) ?? ""
        filters = try c.decodeIfPresent(Filters.self, forKey: .filters) ?? Filters()
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        // Decoded via the raw string so an unrecognised mode degrades to the
        // default rather than failing the whole view.
        let sortRaw = try c.decodeIfPresent(String.self, forKey: .sort) ?? ""
        sort = IssueSort(rawValue: sortRaw) ?? .manual
        let dirRaw = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        dir = IssueSortDirection(rawValue: dirRaw) ?? .asc
        let groupRaw = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        group = IssueGrouping(rawValue: groupRaw) ?? .none
    }

    // MARK: - Is anything actually narrowing the list?

    var hasSearch: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True when the list the user is looking at has been narrowed by something
    /// they chose. Drives the "no matches" copy, which must not claim a project
    /// with 41 issues is empty.
    var isNarrowing: Bool { hasSearch || !filters.isEmpty }

    /// Shown on the filter button so the state is visible without opening it.
    var badgeCount: Int { filters.activeCount + (archived ? 1 : 0) }

    mutating func reset() {
        let keptGroup = group
        self = IssueQuery()
        group = keptGroup
    }

    // MARK: - JSON blob (saved views)

    /// The blob as stored in `views.query`. Keys are written explicitly rather
    /// than via `JSONEncoder` so the output order and shape are stable and
    /// readable when the web client or a human looks at the row.
    func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func from(json: String) -> IssueQuery {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(IssueQuery.self, from: data) else {
            return IssueQuery()
        }
        return decoded
    }

    // MARK: - Server query string

    /// `GET /api/issues?…` for this query.
    ///
    /// `archived=1` is sent unconditionally, and deliberately: it means
    /// "include archived as well as live", so the local cache keeps archived
    /// rows and the client-side filter decides what to *show*. Sending
    /// `archived=0` here would make an archived issue vanish from the phone
    /// entirely, with no way to bring it back.
    func serverQueryString() -> String {
        var items = [URLQueryItem(name: "archived", value: "1")]
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }

        func multi(_ name: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: values.joined(separator: ",")))
        }
        multi("status", filters.status)
        multi("priority", filters.priority)
        multi("assignee", filters.assignee)
        multi("label", filters.label)
        multi("project_id", filters.projectId)
        multi("milestone_id", filters.milestoneId)
        multi("area_id", filters.areaId)

        items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        items.append(URLQueryItem(name: "dir", value: dir.rawValue))

        var components = URLComponents()
        components.queryItems = items
        // `URLComponents` leaves "+" unescaped in a query, where it decodes as a
        // space server-side — a search for "C++" would otherwise arrive as "C  ".
        let encoded = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return encoded
    }
}

// MARK: - A rendered group of issues

/// One section of a grouped list. `id` is stable across redraws so SwiftUI does
/// not tear down and rebuild every row when one issue changes group.
struct IssueGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let issues: [GraftIssue]

    static func == (a: IssueGroup, b: IssueGroup) -> Bool {
        a.id == b.id && a.issues.map(\.id) == b.issues.map(\.id)
    }
}

// MARK: - Project scope (the Projects tab)

/// What the Projects tab is showing.
///
/// "Active" used to mean `archived == false`, so a paused or finished project
/// filed under Active — the web client has always meant `status == 'active'`.
enum ProjectScope: String, CaseIterable, Codable, Hashable {
    case active
    case paused
    case done
    case all
    case archived

    var label: String {
        switch self {
        case .active: return "Active"
        case .paused: return "Paused"
        case .done: return "Done"
        case .all: return "All live"
        case .archived: return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "circle.dashed"
        case .paused: return "pause.circle"
        case .done: return "checkmark.circle"
        case .all: return "square.stack"
        case .archived: return "archivebox"
        }
    }

    func matches(_ project: GraftProject) -> Bool {
        switch self {
        case .archived: return project.archived
        case .all: return !project.archived
        case .active, .paused, .done:
            return !project.archived && project.status == rawValue
        }
    }
}
