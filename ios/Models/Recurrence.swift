import Foundation

// MARK: - Recurrence
//
// The rule an issue repeats on. It travels as an RRULE string because the
// server, ICS and EventKit all speak it — see the long note above
// `_parse_recurrence` in `server/app.py`, which is the authority on what is
// accepted. This is the client half of that contract, and it matches the web
// client's `parseRecurrence` / `buildRecurrence` / `recurrenceText` trio.
//
// Two rules govern everything here:
//
//   Parsing is tolerant. A rule may have been written by a newer client, or by
//   hand, and a part this build cannot read must not make the issue unopenable.
//
//   Building is strict. The server answers 400 for an unsupported part rather
//   than ignoring it — deliberately, so "every weekday" never quietly becomes
//   "every day" — which means the editor may only ever emit parts it knows are
//   accepted. Anything it parsed but does not offer is carried through
//   untouched rather than dropped, so editing the frequency of a rule that came
//   with a COUNT does not silently make the series endless.

enum RecurrenceFreq: String, CaseIterable, Hashable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"
    case yearly = "YEARLY"

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// Singular and plural, for "every 3 weeks".
    var unit: (one: String, many: String) {
        switch self {
        case .daily: return ("day", "days")
        case .weekly: return ("week", "weeks")
        case .monthly: return ("month", "months")
        case .yearly: return ("year", "years")
        }
    }
}

/// A weekday, in the RRULE spelling. Monday first: the server fixes WKST=MO and
/// documents it, so the picker must not offer a week that starts anywhere else.
enum RecurrenceDay: String, CaseIterable, Hashable {
    case mo = "MO", tu = "TU", we = "WE", th = "TH", fr = "FR", sa = "SA", su = "SU"

    var short: String {
        switch self {
        case .mo: return "Mon"
        case .tu: return "Tue"
        case .we: return "Wed"
        case .th: return "Thu"
        case .fr: return "Fri"
        case .sa: return "Sat"
        case .su: return "Sun"
        }
    }

    /// One letter, for the compact weekday row. Sat/Sun share S, which is why
    /// the picker labels itself with `short` and only falls back to this when
    /// there is no room.
    var initial: String { String(short.prefix(1)) }
}

/// Where the next occurrence is counted from.
///
/// Said in plain language rather than as "schedule" / "completion", which are
/// storage words. The two lines below are the web client's, verbatim — the
/// whole point of the feature is that a person can tell the two apart, and they
/// cannot do that from two nouns.
enum RecurrenceAnchor: String, CaseIterable, Hashable {
    case schedule
    case completion

    var label: String {
        switch self {
        case .schedule: return "On its own day"
        case .completion: return "After I finish it"
        }
    }

    var detail: String {
        switch self {
        case .schedule: return "miss one and the next is still on its day"
        case .completion: return "the clock starts when I tick it off"
        }
    }

    /// The whole sentence, as the web client's `<option>` reads it.
    var optionText: String { "\(label) — \(detail)" }
}

// MARK: - The parsed rule

struct Recurrence: Equatable {
    var freq: RecurrenceFreq?
    var interval: Int = 1
    /// Weekly only. Empty means "the day the issue is already on".
    var byday: [RecurrenceDay] = []

    /// Parsed but not offered by the editor. Kept so a rule written elsewhere
    /// survives a round trip through this form — see the note at the top.
    var bymonthday: [Int] = []
    var count: Int?
    var until: String?

    /// "Does not repeat".
    static let none = Recurrence()

    var repeats: Bool { freq != nil }

    // MARK: Parse

    /// Reads an RRULE string. Never fails: an unrecognised `FREQ`, or no `FREQ`
    /// at all, is "does not repeat", which is exactly how the server treats an
    /// empty rule and is the only safe way to render an unknown one.
    init(rule: String?) {
        let text = (rule ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !text.isEmpty else { return }

        for chunk in text.split(separator: ";") {
            let pair = chunk.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            let (key, value) = (pair[0], pair[1])
            switch key {
            case "FREQ":
                freq = RecurrenceFreq(rawValue: value)
            case "INTERVAL":
                interval = max(1, Int(value) ?? 1)
            case "BYDAY":
                byday = value.split(separator: ",").compactMap {
                    RecurrenceDay(rawValue: $0.trimmingCharacters(in: .whitespaces))
                }
            case "BYMONTHDAY":
                bymonthday = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { (1...31).contains($0) }
            case "COUNT":
                if let n = Int(value), n >= 1 { count = n }
            case "UNTIL":
                until = value
            default:
                // An ordinal BYDAY, a BYSETPOS, a WKST — the server refuses all
                // of them, so there is nothing to carry forward and nothing
                // this can usefully say. Ignoring it here only affects how the
                // rule *reads*; it was never going to be re-emitted.
                continue
            }
        }
        // A rule with no usable FREQ is not a rule. Everything else it may have
        // said was relative to one.
        if freq == nil { self = Recurrence() }
    }

    init() { }

    // MARK: Build

    /// The RRULE to store. `""` for "does not repeat".
    ///
    /// Only parts the server accepts are emitted, and only where they are legal
    /// for the frequency: `BYDAY` is weekly-only and `BYMONTHDAY` monthly-only,
    /// and sending either anywhere else is a 400 rather than a shrug.
    var rule: String {
        guard let freq else { return "" }
        var bits = ["FREQ=\(freq.rawValue)"]
        if interval > 1 { bits.append("INTERVAL=\(interval)") }
        if freq == .weekly, !byday.isEmpty {
            // Calendar order regardless of the order they were tapped in.
            let ordered = RecurrenceDay.allCases.filter { byday.contains($0) }
            bits.append("BYDAY=" + ordered.map(\.rawValue).joined(separator: ","))
        }
        if freq == .monthly, !bymonthday.isEmpty {
            bits.append("BYMONTHDAY=" + bymonthday.sorted().map(String.init).joined(separator: ","))
        }
        // RFC 5545 forbids both, and so does the server: they can disagree, and
        // then the series has two lengths depending on who is asking.
        if let count { bits.append("COUNT=\(count)") }
        else if let until, !until.isEmpty { bits.append("UNTIL=\(until)") }
        return bits.joined(separator: ";")
    }

    // MARK: Say it out loud

    /// The rule in the words someone would use — "every Mon, Wed", "every 3
    /// weeks". The editor shows this rather than the RRULE, because
    /// `FREQ=WEEKLY;BYDAY=SU` is not a sentence anyone can check at a glance.
    var text: String {
        guard let freq else { return "" }
        let unit = interval == 1 ? freq.unit.one : freq.unit.many
        let every = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)"
        if freq == .weekly, !byday.isEmpty {
            let names = RecurrenceDay.allCases
                .filter { byday.contains($0) }
                .map(\.short)
                .joined(separator: ", ")
            return interval == 1 ? "every \(names)" : "\(every) on \(names)"
        }
        // The editor does not offer BYMONTHDAY, but a rule written elsewhere
        // can carry it and is preserved on save — so it has to be *said*, or
        // "every month" would describe a rule that means the 1st and the 15th.
        if freq == .monthly, !bymonthday.isEmpty {
            let days = bymonthday.sorted().map(Self.ordinal).joined(separator: ", ")
            return "\(every) on the \(days)"
        }
        return every
    }

    /// "1st", "22nd" — English only, like the rest of the app's copy.
    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default:     suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// The rule plus its anchor, as one sentence — so the two anchors are told
    /// apart by what they do rather than by the words on their labels.
    func summary(anchor: RecurrenceAnchor) -> String {
        guard repeats else { return "" }
        switch anchor {
        case .completion:
            return "Repeats \(text), counted from the moment you tick it off."
        case .schedule:
            return "Repeats \(text). Finish it late and the next one still lands on its own day."
        }
    }

    /// The short form for a row glyph's accessibility label and menus.
    static func shortText(_ rule: String) -> String {
        Recurrence(rule: rule).text
    }
}
