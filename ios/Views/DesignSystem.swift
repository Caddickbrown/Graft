import SwiftUI

// MARK: - Palette
extension Color {
    // Backgrounds
    static let gBg       = Color(hex: "#131a13")   // deep forest
    static let gSurface  = Color(hex: "#1a231a")   // dark moss
    static let gSurface2 = Color(hex: "#212c21")   // slightly lighter
    static let gSidebar  = Color(hex: "#0d120d")   // night
    // Text
    static let gInk      = Color(hex: "#dde8d4")   // warm parchment
    static let gMuted    = Color(hex: "#678063")   // sage grey
    static let gHairline = Color(hex: "#2a3a2a")   // dark green border
    // Accents
    static let gSage     = Color(hex: "#96b86e")   // growth, links
    static let gAmber    = Color(hex: "#c8903f")   // CTA, in-progress
    static let gLavender = Color(hex: "#9b7fc9")   // review
    static let gTeal     = Color(hex: "#5eaa8e")   // done
    static let gRed      = Color(hex: "#b85555")   // urgent
    static let gOrange   = Color(hex: "#c47a35")   // high priority
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
        case .backlog: return Color(hex: "#4a5a49")
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
        case .low: return Color(hex: "#3a4e3a")
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
                .font(.system(size: 11))
            Text(s.label)
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 9))
            Text(name)
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Text(subtitle)
                .font(.system(size: 13))
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
