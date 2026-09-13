import Foundation
import Observation
import UserNotifications

// MARK: - NotificationScheduler
//
// Turns the server's `notifications` rows into iOS local notifications.
//
// Local, not push. There is no APNs here and no push entitlement: the Pi has no
// certificate, no token store and no reason to hold either, and everything the
// user needs to be told about is known hours or days in advance. The server
// decides *what* is worth saying — see the long note above the notifications
// section in `app.py` — and this decides which of it fits.
//
// Three things make this more than a for-loop:
//
//   The 64 cap. iOS keeps at most 64 pending local notifications per app and
//   silently drops the rest, so something has to rank. The order is
//   overdue → due → starting → assigned → digest: lateness first, because it is
//   the only kind the user cannot discover by looking at the right day.
//
//   `fire_at` is UTC. The server has no idea what timezone the phone is in, so
//   whole-day dates are stamped 09:00 UTC (08:00 for the digest) and converted
//   here. Scheduling the string as written would fire at the wrong hour
//   everywhere but Greenwich.
//
//   Rescheduling, not accumulating. Every sync rebuilds the whole pending set
//   rather than adding to it. A due date that moved must move its notification,
//   which means the old one has to be cancelled, which means the set is rebuilt
//   from scratch each time.

@MainActor
@Observable
final class NotificationScheduler {

    // MARK: - State

    enum Authorization: Equatable {
        case unknown
        case notAsked
        case denied
        case granted
        /// Authorised, but every alert is going to the Notification Centre
        /// rather than the screen. Worth saying out loud, because from inside
        /// the app it looks identical to nothing being scheduled.
        case grantedQuietly
    }

    private(set) var authorization: Authorization = .unknown
    /// How many notifications are actually pending after the last rebuild.
    private(set) var scheduledCount = 0
    /// Set when the last rebuild had to leave some out. The Settings screen
    /// says so, because "you have 90 things due and iOS will hold 64" is not a
    /// fact anyone can deduce.
    private(set) var droppedCount = 0
    private(set) var lastError: String?

    /// The user's own switch, separate from the system permission. Off by
    /// default: a task app that starts buzzing the moment it is linked to a
    /// server has not been given permission by anybody.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { Task { await clearAll() } }
        }
    }

    // MARK: - Constants

    /// iOS holds 64 pending local notifications per app and drops the rest
    /// without telling anyone.
    static let pendingLimit = 64

    /// Every request this app schedules is prefixed, so a rebuild can clear
    /// exactly its own pending set and nothing else.
    private static let prefix = "graft.note."
    private static let enabledKey = "graft.notifications.enabled"

    /// A notification whose moment has already passed is usually stale — the
    /// due badge in the app is already saying it, and a phone buzzing about
    /// Tuesday on Thursday is worse than silence. Inside this window it is
    /// still today's news, so it is pushed to a few minutes out instead.
    private static let staleAfter: TimeInterval = 12 * 3600
    private static let catchUpDelay: TimeInterval = 15 * 60

    // MARK: - Init

    private let ledgerURL: URL

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ledgerURL = docs.appendingPathComponent("graft_scheduled_notes.json")
        ledger = Self.loadLedger(from: ledgerURL)
    }

    // MARK: - Authorisation

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            authorization = .notAsked
        case .denied:
            authorization = .denied
        case .authorized, .provisional, .ephemeral:
            authorization = settings.alertSetting == .enabled ? .granted : .grantedQuietly
        @unknown default:
            authorization = .unknown
        }
    }

    /// Asks once. iOS only ever shows the prompt for `.notDetermined`, so after
    /// a refusal this resolves to `.denied` and the caller has to send the user
    /// to Settings.app instead.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            lastError = error.localizedDescription
            await refreshAuthorization()
            return false
        }
    }

    // MARK: - The ledger
    //
    // What this app has already scheduled *and acked*.
    //
    // It exists because acking at schedule time and reading with
    // `?undelivered=true` pull against each other: the moment a row is acked it
    // stops coming back, but it is still sitting in the pending set and still
    // has to survive the next rebuild. Without a local record, every sync would
    // cancel everything it scheduled on the previous one.

    private struct ScheduledNote: Codable, Identifiable {
        let id: String
        let kind: String
        let issueId: String
        let title: String
        let body: String
        let fireAt: Date
    }

    private var ledger: [String: ScheduledNote] = [:]

    private static func loadLedger(from url: URL) -> [String: ScheduledNote] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let notes = try? decoder.decode([String: ScheduledNote].self, from: data)
        else { return [:] }
        return notes
    }

    private func saveLedger() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(ledger) {
            try? data.write(to: ledgerURL, options: .atomic)
        }
    }

    // MARK: - Rebuild

    /// Pull, rank, schedule, ack. Safe to call on every sync.
    ///
    /// `digestBody` is computed by the caller from what the phone already knows,
    /// because the digest row carries no issue of its own and a notification
    /// reading "your summary is ready" is not worth a buzz.
    func reschedule(base: String, api: APIService, digestBody: String) async {
        guard isEnabled else { return }
        await refreshAuthorization()
        guard authorization == .granted || authorization == .grantedQuietly else { return }

        let now = Date()
        let horizonSince = Self.stamp(now.addingTimeInterval(-Self.staleAfter))

        // Two reads, and the difference between them is the whole reason the
        // ledger exists.
        //
        // `current` is everything still ahead of us, delivered or not. Rows this
        // app has already acked come back here and nowhere else, which is what
        // lets the reaper below tell "already told the user about this" apart
        // from "the server has dropped this".
        //
        // `undelivered` is the set that still needs telling — and the only set
        // that gets acked.
        //
        // Both are `try`, not `try?`: an unreachable server must leave the
        // pending set exactly as it is. Treating a failed read as an empty
        // answer would cancel every reminder on the phone the first time the Pi
        // was asleep, and nothing would bring them back until it woke.
        let current: [GraftNotification]
        let undelivered: [GraftNotification]
        do {
            current = try await api.notifications(base: base, since: horizonSince)
            undelivered = try await api.notifications(
                base: base, undelivered: true, since: horizonSince)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }

        guard !current.isEmpty || !ledger.isEmpty else {
            await clearPending()
            scheduledCount = 0
            droppedCount = 0
            return
        }

        // Reap. A derived notification whose issue moved, was finished or was
        // deleted is simply gone from the server — the reconciler drops rows
        // nobody wants any more — so anything in the ledger the server no
        // longer lists is a notification about something that is no longer
        // true, and must not fire.
        let live = Set(current.map(\.id))
        ledger = ledger.filter { live.contains($0.key) && $0.value.fireAt > now.addingTimeInterval(-Self.staleAfter) }

        // Fold in what is new. A row already in the ledger keeps its ledger
        // entry — same id, same content — so this is only ever additive.
        var pendingAck: [String] = []
        for note in undelivered {
            guard ledger[note.id] == nil else { continue }
            guard let entry = Self.entry(for: note, now: now, digestBody: digestBody) else { continue }
            ledger[note.id] = entry
            pendingAck.append(note.id)
        }

        let ranked = ledger.values.sorted(by: Self.ranked)
        let keep = Array(ranked.prefix(Self.pendingLimit))
        droppedCount = max(0, ranked.count - keep.count)

        await clearPending()
        var scheduled: Set<String> = []
        for note in keep {
            if await add(note) { scheduled.insert(note.id) }
        }
        scheduledCount = scheduled.count
        saveLedger()

        // Ack only what actually reached the notification centre. A row that
        // was ranked out by the cap, or that iOS refused, has not been shown to
        // anybody and must still come back as undelivered next time.
        for id in pendingAck where scheduled.contains(id) {
            _ = try? await api.ackNotification(base: base, id: id)
        }
    }

    /// Drops everything and forgets the ledger — for the switch being turned
    /// off, or a server being unlinked.
    func clearAll() async {
        await clearPending()
        ledger = [:]
        saveLedger()
        scheduledCount = 0
        droppedCount = 0
    }

    // MARK: - Private

    /// Removes only this app's own pending requests. `removeAllPending…` would
    /// do here too, since nothing else in Graft schedules anything — but the
    /// prefix makes that an assumption the code states rather than one the next
    /// feature has to remember.
    private func clearPending() async {
        let centre = UNUserNotificationCenter.current()
        let pending = await centre.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        guard !mine.isEmpty else { return }
        centre.removePendingNotificationRequests(withIdentifiers: mine)
    }

    private func add(_ note: ScheduledNote) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        // Enough to open the right issue when the app grows a deep link; a
        // digest row carries "" and lands on the Inbox.
        content.userInfo = ["issue_id": note.issueId, "kind": note.kind, "note_id": note.id]
        content.threadIdentifier = note.issueId.isEmpty ? "graft.digest" : note.issueId

        // The one place the UTC-to-local conversion happens. `note.fireAt` is an
        // absolute instant, already parsed out of the server's naive-UTC string;
        // `Calendar.current` is in the device's timezone, so these components
        // are the local wall-clock time of that instant.
        let fire = max(note.fireAt, Date().addingTimeInterval(60))
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)

        let request = UNNotificationRequest(
            identifier: Self.prefix + note.id, content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// overdue → due → starting → assigned → digest, then soonest first.
    ///
    /// Kind before time on purpose. When more than 64 things want saying, the
    /// ones worth saying are the late ones: a due date is discoverable by
    /// looking at today, and lateness is the state the user has already stopped
    /// looking for.
    private static func ranked(_ a: ScheduledNote, _ b: ScheduledNote) -> Bool {
        let ra = rank(a.kind), rb = rank(b.kind)
        if ra != rb { return ra < rb }
        if a.fireAt != b.fireAt { return a.fireAt < b.fireAt }
        return a.id < b.id
    }

    private static func rank(_ kind: String) -> Int {
        switch kind {
        case "overdue":  return 0
        case "due":      return 1
        case "starting": return 2
        case "assigned": return 3
        case "digest":   return 4
        default:         return 5
        }
    }

    /// One server row as something schedulable, or nil if it is not worth
    /// scheduling: stale, dismissed, or about an issue that has since been
    /// finished (the reconciler will drop it, but the client should not wait).
    private static func entry(
        for note: GraftNotification, now: Date, digestBody: String
    ) -> ScheduledNote? {
        guard note.dismissedAt == nil else { return nil }
        if let status = note.issueStatus, status == "done" { return nil }
        guard let fire = GraftDate.timestamp(from: note.fireAt) else { return nil }

        let when: Date
        if fire > now {
            when = fire
        } else if now.timeIntervalSince(fire) <= staleAfter {
            // Still today's news — the phone was asleep or off the network when
            // it should have said so. A few minutes out rather than instantly,
            // so a sync does not fire a burst the moment it finishes.
            when = now.addingTimeInterval(catchUpDelay)
        } else {
            return nil
        }

        let title = note.issueTitle ?? "An issue"
        let (heading, body): (String, String)
        switch note.kind {
        case "overdue":  (heading, body) = ("Overdue", title)
        case "due":      (heading, body) = ("Due today", title)
        case "starting": (heading, body) = ("Starts today", title)
        case "assigned": (heading, body) = ("Assigned to you", title)
        case "digest":   (heading, body) = ("Today in Graft", digestBody)
        default:         (heading, body) = ("Graft", title)
        }
        guard !body.isEmpty else { return nil }

        return ScheduledNote(id: note.id, kind: note.kind, issueId: note.issueId,
                             title: heading, body: body, fireAt: when)
    }

    /// The server compares `since` as text against naive-UTC timestamps, so the
    /// bound has to be written the same way its own rows are.
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }
}
