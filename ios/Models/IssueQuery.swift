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
        /// Stored as a *window* rather than as the two dates it resolves to.
        /// A saved view holding `due_before=2026-09-13` is right for one day
        /// and quietly wrong forever after; "overdue" is right every morning.
        var due: DueWindow = .any
        var repeats: RepeatFilter = .any

        enum CodingKeys: String, CodingKey {
            case status, priority, assignee, label, due, repeats
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
            // Via the raw string, like `sort` below: a window written by a
            // newer build degrades to "any" rather than failing the view.
            let dueRaw = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
            due = DueWindow(rawValue: dueRaw) ?? .any
            let repeatsRaw = try c.decodeIfPresent(String.self, forKey: .repeats) ?? ""
            repeats = RepeatFilter(rawValue: repeatsRaw) ?? .any
        }

        /// Nothing selected anywhere — used to tell "no results because of a
        /// filter" apart from "no results because there is nothing".
        var isEmpty: Bool {
            status.isEmpty && priority.isEmpty && assignee.isEmpty && label.isEmpty
                && projectId.isEmpty && milestoneId.isEmpty && areaId.isEmpty
                && due == .any && repeats == .any
        }

        var activeCount: Int {
            status.count + priority.count + assignee.count + label.count
                + projectId.count + milestoneId.count + areaId.count
                + (due == .any ? 0 : 1) + (repeats == .any ? 0 : 1)
        }
    }

    // MARK: - Date window
    //
    // The server's six date bounds are single-value on purpose — "due before X"
    // has exactly one X — so these must never go through the comma-joining
    // `multi()` helper that every other filter uses. See the note above the
    // bounds loop in `list_issues`.

    /// A due-date filter, held as a relative window and resolved to concrete
    /// bounds at the moment a request is built.
    enum DueWindow: String, CaseIterable, Codable, Hashable {
        case any
        case overdue
        case today
        case week

        var label: String {
            switch self {
            case .any: return "Any date"
            case .overdue: return "Overdue"
            case .today: return "Due today"
            case .week: return "Due in 7 days"
            }
        }

        /// `(due_after, due_before)`, both inclusive, both `yyyy-MM-dd` or nil.
        /// Resolved against `today` rather than `Date()` so the caller decides
        /// what "today" means and this stays testable.
        func bounds(from today: Date = Date()) -> (after: String?, before: String?) {
            let cal = Calendar.current
            func day(_ offset: Int) -> String {
                GraftDate.dayString(from: cal.date(byAdding: .day, value: offset, to: today) ?? today)
            }
            switch self {
            case .any:     return (nil, nil)
            // Strictly before today. The bound is inclusive, so yesterday.
            case .overdue: return (nil, day(-1))
            case .today:   return (day(0), day(0))
            case .week:    return (day(0), day(7))
            }
        }

        /// The same question asked of one issue, for the offline path.
        func matches(_ dueAt: String) -> Bool {
            guard self != .any else { return true }
            // An issue with no due date is not due — the server's guard, and
            // without it every undated issue would satisfy every bound.
            guard let days = GraftDate.daysUntil(dueAt), !dueAt.isEmpty else { return false }
            switch self {
            case .any:     return true
            case .overdue: return days < 0
            case .today:   return days == 0
            case .week:    return days >= 0 && days <= 7
            }
        }
    }

    /// `?recurring=`. "A recurring issue is one carrying a rule, not one that
    /// happens to be a spawned occurrence" — an occurrence carries the rule too.
    enum RepeatFilter: String, CaseIterable, Codable, Hashable {
        case any
        case only
        case never

        var label: String {
            switch self {
            case .any: return "All issues"
            case .only: return "Repeating"
            case .never: return "One-off"
            }
        }

        var param: String? {
            switch self {
            case .any: return nil
            case .only: return "true"
            case .never: return "false"
            }
        }

        func matches(_ issue: GraftIssue) -> Bool {
            switch self {
            case .any: return true
            case .only: return issue.repeats
            case .never: return !issue.repeats
            }
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

        /// The same, for the three params where the server gives `none` a
        /// meaning: area_id, assignee and milestone_id. This client holds the
        /// unset bucket as `""` — which is what the local filter and the saved
        /// blob have always said, and what the web client writes too — and the
        /// server drops blank fragments, so `?assignee=` asked for *no filter*
        /// rather than for the unassigned pile. The response was a superset the
        /// local filter then narrowed, so nothing looked wrong; the request was
        /// simply a lie, and a wasteful one. Translated here, at the edge, so
        /// the sentinel in the blob does not have to change under either client.
        func multiWithNone(_ name: String, _ values: [String]) {
            multi(name, values.map { $0.isEmpty ? "none" : $0 })
        }
        multi("status", filters.status)
        multi("priority", filters.priority)
        multiWithNone("assignee", filters.assignee)
        multi("label", filters.label)
        multi("project_id", filters.projectId)
        multiWithNone("milestone_id", filters.milestoneId)
        multiWithNone("area_id", filters.areaId)

        // Deliberately NOT through `multi`. The date bounds are single-value on
        // the server — comma-joining them would send `due_before=a,b`, which is
        // not a set the server ever splits, and the whole filter would silently
        // match nothing.
        let bounds = filters.due.bounds()
        if let after = bounds.after { items.append(URLQueryItem(name: "due_after", value: after)) }
        if let before = bounds.before { items.append(URLQueryItem(name: "due_before", value: before)) }
        if let recurring = filters.repeats.param {
            items.append(URLQueryItem(name: "recurring", value: recurring))
        }

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
