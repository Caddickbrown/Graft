import SwiftUI

// MARK: - Palette
//
// Every token resolves per appearance, so the app follows the system setting
// the way the web client's theme toggle does. Dark is Botanical Night; light
// is "Warm paper" — cream stock, olive ink, one amber accent — rather than the
// old near-black brown sidebar, which put near-black text on a near-black
// ground at about 1.3:1.
//
// Contrast is measured against the surface each colour actually sits on;
// every text token below clears WCAG AA (4.5:1).

private func dynamicColor(dark: String, light: String) -> Color {
    Color(UIColor { traits in
        UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
    })
}

extension Color {
    // Backgrounds
    static let gBg       = dynamicColor(dark: "#131a13", light: "#f4f1e8")
    static let gSurface  = dynamicColor(dark: "#1a231a", light: "#fdfcf8")
    static let gSurface2 = dynamicColor(dark: "#212c21", light: "#f1ede2")
    static let gSidebar  = dynamicColor(dark: "#0d120d", light: "#eae5d8")
    // Text
    static let gInk      = dynamicColor(dark: "#dde8d4", light: "#23271f")
    static let gMuted    = dynamicColor(dark: "#85a07f", light: "#6a6b5c")
    static let gFaint    = dynamicColor(dark: "#7d977a", light: "#757463")
    static let gHairline = dynamicColor(dark: "#2a3a2a", light: "#ddd8c8")
    // Accents
    static let gSage     = dynamicColor(dark: "#96b86e", light: "#4f7a34")
    static let gAmber    = dynamicColor(dark: "#c8903f", light: "#a8601f")
    static let gLavender = dynamicColor(dark: "#a78ad2", light: "#6b5a9c")
    static let gTeal     = dynamicColor(dark: "#5eaa8e", light: "#3f7a5e")
    static let gRed      = dynamicColor(dark: "#cc7f7f", light: "#a83232")
    static let gOrange   = dynamicColor(dark: "#c47a35", light: "#a8601f")
    /// Label colour on top of gAmber. White on amber is 2.8:1; this is 6.8:1.
    static let gOnAccent = dynamicColor(dark: "#0d120d", light: "#ffffff")
}

// MARK: - Metrics
//
// iOS body text is 17pt. The old values (14pt titles, 10–11pt metadata) were
// desktop density on a phone.

enum GraftType {
    static let title: CGFloat = 17      // issue and project titles
    static let body: CGFloat = 16
    static let secondary: CGFloat = 14  // metadata beside a title
    static let caption: CGFloat = 13    // the smallest text used anywhere
}

enum GraftMetrics {
    /// Apple's minimum comfortable hit target.
    static let tap: CGFloat = 44
    static let radius: CGFloat = 10
    static let gutter: CGFloat = 16
}

// MARK: - Status
enum IssueStatus: String, CaseIterable {
    case backlog = "backlog"
    case todo = "todo"
    case inProgress = "in-progress"
    case review = "review"
    case done = "done"

    var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "Todo"
        case .inProgress: return "In progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .backlog: return dynamicColor(dark: "#8a9e88", light: "#757463")
        case .todo: return .gSage
        case .inProgress: return .gAmber
        case .review: return .gLavender
        case .done: return .gTeal
        }
    }

    var icon: String {
        switch self {
        case .backlog: return "circle"
        case .todo: return "circle.dotted"
        case .inProgress: return "arrow.up.circle"
        case .review: return "sparkle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

// MARK: - Priority
enum IssuePriority: String, CaseIterable {
    case urgent = "urgent"
    case high = "high"
    case normal = "normal"
    case low = "low"

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .urgent: return .gRed
        case .high: return .gOrange
        case .normal: return .gMuted
        case .low: return .gFaint
        }
    }

    var icon: String {
        switch self {
        case .urgent: return "exclamationmark.circle.fill"
        case .high: return "arrow.up.circle.fill"
        case .normal: return "minus.circle"
        case .low: return "arrow.down.circle"
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .urgent: return 9
        case .high: return 7.5
        case .normal: return 6
        case .low: return 5
        }
    }
}

// MARK: - Shared UI components

struct StatusBadge: View {
    let status: String
    var body: some View {
        let s = IssueStatus(rawValue: status) ?? .backlog
        HStack(spacing: 4) {
            Image(systemName: s.icon)
                .font(.system(size: 12))
            Text(s.label)
                .font(.system(size: GraftType.caption, weight: .medium))
        }
        .foregroundStyle(s.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(s.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct PriorityDot: View {
    let priority: String
    var body: some View {
        let p = IssuePriority(rawValue: priority) ?? .normal
        Circle()
            .fill(p.color)
            .frame(width: p.dotSize, height: p.dotSize)
    }
}

struct MilestoneTag: View {
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 10))
            Text(name)
                .font(.system(size: GraftType.caption, weight: .medium))
        }
        .foregroundStyle(Color.gSage)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.gSage.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct GraftEmptyState: View {
    let title: String
    let subtitle: String
    var systemImage: String = "leaf"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.gMuted)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Text(subtitle)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gMuted)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

struct ProjectColourDot: View {
    let hex: String
    var size: CGFloat = 10
    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
    }
}


// MARK: - Priority badge
//
// Normal is the default and says nothing, so only what stands out shows.

struct PriorityBadge: View {
    let priority: String
    var body: some View {
        let p = IssuePriority(rawValue: priority) ?? .normal
        if p == .urgent || p == .high {
            HStack(spacing: 4) {
                Image(systemName: p.icon)
                    .font(.system(size: 11))
                Text(p.label)
                    .font(.system(size: GraftType.caption, weight: .semibold))
            }
            .foregroundStyle(p.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(p.color.opacity(0.14))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Avatar

struct GraftAvatar: View {
    let name: String
    var size: CGFloat = 26

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }

    var body: some View {
        Group {
            if name.isEmpty {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.40))
                    .foregroundStyle(Color.gFaint)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Color.gHairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(Color.gMuted)
                    .frame(width: size, height: size)
                    .background(Color.gSurface2, in: Circle())
                    .overlay(Circle().strokeBorder(Color.gHairline, lineWidth: 0.5))
            }
        }
        .accessibilityLabel(name.isEmpty ? "Unassigned" : name)
    }
}

// MARK: - Undo banner
//
// Destructive actions apply immediately and offer a way back, rather than
// asking up front — or, as the project list used to, not asking at all.

struct UndoAction: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var undo: () async -> Void

    static func == (a: UndoAction, b: UndoAction) -> Bool { a.id == b.id }
}

struct UndoBanner: View {
    let action: UndoAction
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 15))
                .foregroundStyle(Color.gMuted)
            Text(action.message)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gInk)
            Spacer(minLength: 8)
            Button("Undo") {
                Task { await action.undo(); dismiss() }
            }
            .font(.system(size: GraftType.body, weight: .semibold))
            .foregroundStyle(Color.gSage)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, GraftMetrics.gutter)
    }
}

extension View {
    /// Shows an undo banner above the tab bar and clears it after 7 seconds.
    func undoBanner(_ action: Binding<UndoAction?>) -> some View {
        overlay(alignment: .bottom) {
            if let current = action.wrappedValue {
                UndoBanner(action: current) { action.wrappedValue = nil }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: current.id) {
                        try? await Task.sleep(for: .seconds(7))
                        if action.wrappedValue?.id == current.id { action.wrappedValue = nil }
                    }
            }
        }
        .animation(.snappy(duration: 0.22), value: action.wrappedValue)
    }
}

// MARK: - Relative dates

enum GraftDate {
    static func relative(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let date else { return "" }
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        if mins < 1440 { return "\(mins / 60)h ago" }
        return "\(mins / 1440)d ago"
    }

    /// Days from today to a yyyy-MM-dd string, parsed in the local calendar so
    /// a due date never slips a day depending on the timezone.
    static func daysUntil(_ dateString: String?) -> Int? {
        guard let dateString, dateString.count >= 10 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard let due = f.date(from: String(dateString.prefix(10))) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateComponents([.day], from: today, to: due).day
    }

    static func dueLabel(_ dateString: String?) -> String? {
        guard let days = daysUntil(dateString) else { return nil }
        if days < 0 { return "\(-days)d overdue" }
        if days == 0 { return "due today" }
        if days == 1 { return "due tomorrow" }
        return "in \(days) days"
    }
}

// MARK: - Color(hex:) extension
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        let c = UIColor(self)
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
