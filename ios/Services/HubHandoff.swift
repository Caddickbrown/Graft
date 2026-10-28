import Foundation

// MARK: - HubHandoff
//
// Edits made in Hub, on this same phone, handed to Graft through a shared App
// Group folder rather than over the network.
//
// Hub shows Graft's issues and lets them be ticked off and edited. Off the
// home network it can't reach the Pi, so it queues the edit; but when Graft is
// on the same phone there is a shorter way round, and one that works in
// phone-only mode too, where there is no Pi to reach at all. Hub writes each
// action as a file; Graft picks it up the next time it comes to the front and
// makes the edit itself, through the same store methods a tap would use, so it
// is saved, queued and sent exactly like one.
//
//   <group>/handoff/graft-actions/<id>.json   written by Hub, deleted here
//   <group>/handoff/graft-applied/<id>        empty, written here when applied
//
// Hub reads the second folder to learn which of its actions landed; anything it
// doesn't find there it settles by its own route. See docs/local-first.md for
// the file format.
//
// The rule is the server's `_ts` rule: an edit made before the issue last
// changed here is stale and is skipped, not applied over the top. Skipped and
// malformed files are deleted too — leaving one would only have it read again
// on every foreground.
//
// Without the App Group entitlement (an unsigned CI build, a profile missing
// the group) there is no container and this does nothing.

@MainActor
enum HubHandoff {
    static let appGroup = "group.com.caddickbrown.shared"

    /// One drain at a time. Launch and the first foreground both ask, and the
    /// store calls inside await; a second pass over the same files mid-way
    /// through the first would apply a create twice.
    private static var draining = false

    private struct Action {
        let id: String
        let kind: String
        let issueId: String
        let fields: [String: Any]
        let body: [String: Any]
        let madeAt: Date
        let file: URL
    }

    /// Read every waiting action, oldest first, and apply or skip each one.
    static func drain(into store: GraftStore) async {
        guard !draining,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return }
        draining = true
        defer { draining = false }

        let handoff = container.appendingPathComponent("handoff", isDirectory: true)
        let actionsDir = handoff.appendingPathComponent("graft-actions", isDirectory: true)
        let appliedDir = handoff.appendingPathComponent("graft-applied", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: actionsDir, includingPropertiesForKeys: nil
        ) else { return }

        var actions: [Action] = []
        for file in files where file.pathExtension == "json" {
            if let action = read(file) {
                actions.append(action)
            } else {
                // Malformed: nothing to apply and nothing to report back.
                try? FileManager.default.removeItem(at: file)
            }
        }
        actions.sort { $0.madeAt < $1.madeAt }

        // An issue this pass has already written to is compared with the Hub
        // edit that wrote it, not with its `updatedAt`, which is now: two edits
        // Hub queued a minute apart would otherwise see the first one's write
        // as a newer change, and drop the second.
        var appliedAt: [String: Date] = [:]
        for action in actions {
            if await apply(action, to: store, appliedAt: appliedAt) {
                appliedAt[action.kind == "graft.create" ? createdId(action) : action.issueId] = action.madeAt
                try? FileManager.default.createDirectory(at: appliedDir, withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: appliedDir.appendingPathComponent(action.id).path, contents: Data()
                )
            }
            try? FileManager.default.removeItem(at: action.file)
        }
    }

    private static func read(_ file: URL) -> Action? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty,
              // The id names the marker file, so it must not name a path.
              !id.contains("/"), id != ".", id != "..",
              let kind = json["kind"] as? String,
              let issueId = json["issue_id"] as? String, !issueId.isEmpty,
              let madeAt = (json["made_at"] as? String).flatMap(GraftDate.timestamp(from:))
        else { return nil }
        return Action(
            id: id, kind: kind, issueId: issueId,
            fields: json["fields"] as? [String: Any] ?? [:],
            body: json["body"] as? [String: Any] ?? [:],
            madeAt: madeAt, file: file
        )
    }

    /// Whether the action was applied. False for one that was skipped.
    private static func apply(_ action: Action, to store: GraftStore, appliedAt: [String: Date]) async -> Bool {
        switch action.kind {
        case "graft.update":
            return await update(action, in: store, since: appliedAt[action.issueId])
        case "graft.create":
            return await create(action, in: store)
        default:
            return false
        }
    }

    private static func update(_ action: Action, in store: GraftStore, since: Date?) async -> Bool {
        guard let current = store.issues.first(where: { $0.id == action.issueId }) else { return false }
        // Newer here than the edit: someone changed it since, on this phone or
        // in the last pull. Not newer — equal included — and the edit stands.
        // A stamp that won't parse is read as old, the server's choice too.
        if let updated = since ?? GraftDate.timestamp(from: current.updatedAt), updated > action.madeAt {
            return false
        }
        let f = action.fields
        var issue = current
        if let v = f["title"] as? String { issue.title = v }
        if let v = f["description"] as? String { issue.description = v }
        if let v = f["status"] as? String { issue.status = v }
        if let v = f["priority"] as? String { issue.priority = v }
        if f.keys.contains("assignee") { issue.assignee = f["assignee"] as? String ?? "" }
        if let v = f["labels"] as? [String] { issue.labels = v }
        if let v = f["project_id"] as? String, !v.isEmpty { issue.projectId = v }
        // Present and null clears, as on the server.
        if f.keys.contains("milestone_id") {
            let v = f["milestone_id"] as? String ?? ""
            issue.milestoneId = v.isEmpty ? nil : v
        }
        if f.keys.contains("start_at") { issue.startAt = f["start_at"] as? String ?? "" }
        if f.keys.contains("due_at") { issue.dueAt = f["due_at"] as? String ?? "" }
        if let v = f["recurrence"] as? String { issue.recurrence = v }
        if let v = f["recurrence_anchor"] as? String { issue.recurrenceAnchor = v }

        do {
            if !sameContent(issue, current) {
                try await store.updateIssue(issue)
            }
            // Archive is its own endpoint and a toggle, so it is only sent when
            // the issue isn't already where Hub wants it.
            if let archived = f["archived"] as? Bool,
               store.issues.first(where: { $0.id == action.issueId })?.archived != archived {
                try await store.archiveIssue(id: action.issueId)
            }
        } catch {
            return false
        }
        return true
    }

    /// The id a create makes: the body's, which is the one Hub minted.
    private static func createdId(_ action: Action) -> String {
        (action.body["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? action.issueId
    }

    private static func create(_ action: Action, in store: GraftStore) async -> Bool {
        let b = action.body
        let id = createdId(action)
        guard !id.isEmpty, !store.issues.contains(where: { $0.id == id }) else { return false }
        let milestone = b["milestone_id"] as? String ?? ""
        do {
            try await store.createIssue(
                // The server's own fallback for an issue with no project.
                projectId: (b["project_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "proj_none",
                title: (b["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                description: b["description"] as? String ?? "",
                status: b["status"] as? String ?? "backlog",
                priority: b["priority"] as? String ?? "normal",
                milestoneId: milestone.isEmpty ? nil : milestone,
                assignee: b["assignee"] as? String ?? "",
                labels: b["labels"] as? [String] ?? [],
                startAt: b["start_at"] as? String ?? "",
                dueAt: b["due_at"] as? String ?? "",
                recurrence: b["recurrence"] as? String ?? "",
                recurrenceAnchor: b["recurrence_anchor"] as? String ?? "schedule",
                id: id
            )
        } catch {
            return false
        }
        return true
    }

    /// Everything `updateIssue` sends, compared, so an action that changes
    /// nothing doesn't bump `updatedAt` and queue a write for it.
    private static func sameContent(_ a: GraftIssue, _ b: GraftIssue) -> Bool {
        a.title == b.title && a.description == b.description && a.status == b.status
            && a.priority == b.priority && a.assignee == b.assignee && a.labels == b.labels
            && a.projectId == b.projectId && a.milestoneId == b.milestoneId
            && a.startAt == b.startAt && a.dueAt == b.dueAt
            && a.recurrence == b.recurrence && a.recurrenceAnchor == b.recurrenceAnchor
    }
}
