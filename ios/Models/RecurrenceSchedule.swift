import CryptoKit
import Foundation

// MARK: - Ids the server derives

enum GraftHash {
    /// `hashlib.sha1(text.encode()).hexdigest()`. The server derives a spawned
    /// occurrence's id and a notification's id this way, and the phone has to
    /// arrive at the same ones.
    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The next occurrence, worked out on the phone
//
// With a server, completing a recurring issue is answered by the server: the
// PUT that marks it done comes back with the next occurrence it spawned (see
// `applySpawn`). A phone with no server has nobody to ask, so this is the
// server's rule again, line for line, so that a series behaves the same with
// or without one. The authority is `server/app.py`:
//
//   `_parse_recurrence`        → `RecurrenceSchedule.Rule.init?(_:)`
//   `_next_occurrence`         → `RecurrenceSchedule.next(_:base:after:)`
//   `_recurrence_next_dates`   → `RecurrenceSchedule.nextDates(for:completedOn:)`
//   `_spawn_next_occurrence`   → `GraftStore.spawnLocally`
//
// Change one side and change the other. The rule here is deliberately the
// strict one, not `Recurrence`'s tolerant parse: the server spawns nothing for a
// rule it would refuse, and neither may this.
//
// Dates are whole days counted from 1970-01-01 rather than `Date`s, because the
// server's are `datetime.date`s: no time of day and no time zone, so nothing a
// phone crossing a date line does can move one.

/// A calendar date with no time zone, as a day number.
struct GraftDay: Comparable, Hashable {
    /// Days since 1970-01-01.
    let number: Int

    init(number: Int) { self.number = number }

    /// Howard Hinnant's `days_from_civil`, which is exact for every date the
    /// proleptic Gregorian calendar has — the same calendar Python's `date` uses.
    init(year: Int, month: Int, day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        number = era * 146097 + doe - 719468
    }

    /// `yyyy-MM-dd`, read from the front of `text` as `_parse_date` does
    /// (`date.fromisoformat(text[:10])`). Nil for anything else, never a guess.
    init?(iso text: String) {
        let head = Array(text.prefix(10))
        guard head.count == 10, head[4] == "-", head[7] == "-" else { return nil }
        let digits = head.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let year = Int(String(head[0..<4])),
              let month = Int(String(head[5..<7])),
              let day = Int(String(head[8..<10])),
              year >= 1, (1...12).contains(month),
              (1...GraftDay.daysIn(year: year, month: month)).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Today in UTC, which is what the server's `datetime.utcnow().date()` is.
    static var todayUTC: GraftDay {
        GraftDay(number: Int((Date().timeIntervalSince1970 / 86_400).rounded(.down)))
    }

    /// `civil_from_days`, the inverse of the initialiser above.
    var components: (year: Int, month: Int, day: Int) {
        let z = number + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    var iso: String {
        let c = components
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// Monday is 0, as in Python's `date.weekday()`. 1970-01-01 was a Thursday.
    var weekday: Int { ((number % 7) + 7 + 3) % 7 }

    func adding(days: Int) -> GraftDay { GraftDay(number: number + days) }

    /// `calendar.monthrange(year, month)[1]`.
    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    static func < (a: GraftDay, b: GraftDay) -> Bool { a.number < b.number }
}

enum RecurrenceSchedule {

    /// `_RECUR_MAX_STEPS`: a guard against a rule that matches nothing.
    static let maxSteps = 500

    /// A rule the server would accept, normalised the way `_parse_recurrence`
    /// returns it. The initialiser fails wherever the server answers 400.
    struct Rule: Equatable {
        var freq: String
        var interval: Int
        /// Monday = 0, sorted, no repeats.
        var byday: [Int]
        var bymonthday: [Int]
        var count: Int?
        var until: GraftDay?

        private static let freqs = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
        private static let days = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]
        private static let keys = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "COUNT", "UNTIL"]

        init?(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            var parts: [String: String] = [:]
            for raw in text.uppercased().split(separator: ";", omittingEmptySubsequences: false) {
                let chunk = raw.trimmingCharacters(in: .whitespaces)
                if chunk.isEmpty { continue }
                guard let eq = chunk.firstIndex(of: "=") else { return nil }
                let key = chunk[..<eq].trimmingCharacters(in: .whitespaces)
                let value = chunk[chunk.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                guard Self.keys.contains(key), parts[key] == nil else { return nil }
                parts[key] = value
            }

            guard let freq = parts["FREQ"], !freq.isEmpty, Self.freqs.contains(freq) else { return nil }
            self.freq = freq

            if let raw = parts["INTERVAL"] {
                guard let n = Int(raw), n >= 1 else { return nil }
                interval = n
            } else {
                interval = 1
            }

            var byday: [Int] = []
            if let raw = parts["BYDAY"] {
                guard freq == "WEEKLY" else { return nil }
                for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    guard let d = Self.days[token.trimmingCharacters(in: .whitespaces)] else { return nil }
                    byday.append(d)
                }
                guard !byday.isEmpty else { return nil }
            }
            self.byday = Array(Set(byday)).sorted()

            var bymonthday: [Int] = []
            if let raw = parts["BYMONTHDAY"] {
                guard freq == "MONTHLY" else { return nil }
                for token in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    guard let dom = Int(token.trimmingCharacters(in: .whitespaces)),
                          (1...31).contains(dom) else { return nil }
                    bymonthday.append(dom)
                }
            }
            self.bymonthday = Array(Set(bymonthday)).sorted()

            if let raw = parts["COUNT"] {
                guard let n = Int(raw), n >= 1 else { return nil }
                count = n
            } else {
                count = nil
            }

            if let raw = parts["UNTIL"] {
                // The ICS form (20261231, 20261231T120000Z) or the ISO one;
                // only the date half is kept.
                let digits = String(raw.split(separator: "T", omittingEmptySubsequences: false).first ?? "")
                    .replacingOccurrences(of: "-", with: "")
                guard digits.count == 8, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                let iso = "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
                guard let day = GraftDay(iso: iso) else { return nil }
                until = day
            } else {
                until = nil
            }

            // RFC 5545 forbids both, and so does the server.
            if count != nil && until != nil { return nil }
        }
    }

    private static func monthIndex(_ d: GraftDay) -> Int {
        let c = d.components
        return c.year * 12 + (c.month - 1)
    }

    /// Python's `//`, which floors where Swift's `/` truncates. The two differ
    /// only for a negative numerator, which `after < base` can produce.
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// `_next_occurrence`: the first occurrence strictly after `after`, with the
    /// rule's phase taken from `base`. Nil once UNTIL has passed, or if nothing
    /// matches within the step limit.
    static func next(_ rule: Rule, base: GraftDay, after: GraftDay) -> GraftDay? {
        func answer(_ d: GraftDay?) -> GraftDay? {
            guard let d else { return nil }
            if let until = rule.until, d > until { return nil }
            return d
        }

        if rule.freq == "DAILY" || (rule.freq == "WEEKLY" && rule.byday.isEmpty) {
            let step = rule.interval * (rule.freq == "WEEKLY" ? 7 : 1)
            let n = max(1, floorDiv(after.number - base.number, step) + 1)
            return answer(base.adding(days: n * step))
        }

        if rule.freq == "WEEKLY" {
            // Weeks start Monday, and the interval counts from the block that
            // holds `base`.
            let block = 7 * rule.interval
            let weekStart = base.adding(days: -base.weekday)
            let skip = max(0, floorDiv(after.number - weekStart.number, block))
            var cursor = weekStart.adding(days: skip * block)
            for _ in 0..<maxSteps {
                for weekday in rule.byday {
                    let candidate = cursor.adding(days: weekday)
                    if candidate > after { return answer(candidate) }
                }
                cursor = cursor.adding(days: block)
            }
            return nil
        }

        if rule.freq == "MONTHLY" {
            // An explicit BYMONTHDAY skips a month without that day; a day
            // inherited from `base` clamps to the month's last day instead.
            let strict = !rule.bymonthday.isEmpty
            let days = strict ? rule.bymonthday : [base.components.day]
            let first = monthIndex(base)
            let skip = max(0, floorDiv(monthIndex(after) - first, rule.interval))
            for step in skip..<(skip + maxSteps) {
                let index = first + step * rule.interval
                let year = floorDiv(index, 12)
                let month = index - year * 12 + 1
                let last = GraftDay.daysIn(year: year, month: month)
                for wanted in days {
                    var dom = wanted
                    if dom > last {
                        if strict { continue }
                        dom = last
                    }
                    let candidate = GraftDay(year: year, month: month, day: dom)
                    if candidate > after { return answer(candidate) }
                }
            }
            return nil
        }

        // YEARLY: month and day from `base`, 29 February clamping to the 28th.
        let b = base.components
        let skip = max(0, floorDiv(after.components.year - b.year, rule.interval))
        for step in skip..<(skip + maxSteps) {
            let year = b.year + step * rule.interval
            let last = GraftDay.daysIn(year: year, month: b.month)
            let candidate = GraftDay(year: year, month: b.month, day: min(b.day, last))
            if candidate > after { return answer(candidate) }
        }
        return nil
    }

    /// `_recurrence_next_dates`: the `(startAt, dueAt)` the next occurrence
    /// carries, or nil when the series ends here.
    static func nextDates(for issue: GraftIssue, completedOn: GraftDay) -> (start: String, due: String)? {
        guard let rule = Rule(issue.recurrence) else { return nil }
        let due = GraftDay(iso: issue.dueAt)
        let start = GraftDay(iso: issue.startAt)
        let anchor = issue.recurrenceAnchor.trimmingCharacters(in: .whitespaces).lowercased()

        let base: GraftDay
        let after: GraftDay
        if anchor == "completion" {
            // Counted from the doing, not from the calendar.
            base = completedOn
            after = completedOn
        } else {
            // The calendar's claim: `base` keeps the phase, `after` skips what
            // was missed.
            base = due ?? start ?? completedOn
            after = max(base, completedOn)
        }

        guard let nxt = next(rule, base: base, after: after) else { return nil }

        if let due, let start {
            // Keep the window the user drew.
            return (nxt.adding(days: -(due.number - start.number)).iso, nxt.iso)
        }
        if start != nil {
            return (nxt.iso, "")
        }
        return ("", nxt.iso)
    }
}
