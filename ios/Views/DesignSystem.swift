import SwiftUI

// MARK: - Palette
//
// Direction: **Porcelain / One Green**. The old "Botanical Night" theme made
// green the wallpaper — a forest ground, sage text, sage controls — so nothing
// green could mean anything. Here the ground is neutral (porcelain in light,
// graphite in dark) and there is exactly one green, spent four or five times a
// screen: the primary action, the done ring, the selected state, a focus ring.
// Hierarchy comes from spacing, weight and surface steps, not from colour and
// not from borders.
//
// Every token resolves per appearance, so the app follows the system setting
// the way the web client's theme toggle does. The hex values are BUILD.md §4
// verbatim and are shared with the web client — three of them were deliberately
// darkened to clear WCAG AA against the surface they sit on, so do not "tidy"
// them back towards the raw brand value.
//
// The light accent in particular is a *darkened* brand: raw #35D07F on white is
// only 2.0:1, which fails as a text or icon colour, so light mode uses #1B7B49
// (brand at 32% black) for fills and #115933 (46% black) for accent-coloured
// text.

private func dynamicColor(dark: String, light: String) -> Color {
    Color(UIColor { traits in
        UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
    })
}

extension Color {

    // MARK: Brand and accent

    /// The one brand value, unadjusted. Use it for marks and illustration only
    /// — on a light ground it is not legible as text or as an icon.
    static let gBrand       = dynamicColor(dark: "#35D07F", light: "#35D07F")
    /// The accent: primary buttons, the done ring, selection. Light mode
    /// darkens the brand so it still clears contrast on white.
    static let gAccent      = dynamicColor(dark: "#35D07F", light: "#1B7B49")
    /// Accent-coloured *text* and small glyphs. A step further from the brand
    /// than `gAccent` in both directions, because thin strokes need more.
    static let gAccentText  = dynamicColor(dark: "#6AD996", light: "#115933")
    /// A tint for the background of an accented chip, row or selected control.
    /// Kept as a translucency so it composes correctly over any surface step.
    static let gAccentWash  = Color.gAccent.opacity(0.13)
    /// Label colour on top of `gAccent`. White on the dark accent is 2.0:1;
    /// near-black is 8.4:1, so each mode takes the one that reads.
    static let gOnAccent    = dynamicColor(dark: "#082115", light: "#FFFFFF")

    // MARK: Surfaces
    //
    // Elevation comes from these steps, not from shadow. Shadow is reserved for
    // things that genuinely float over the content: overlays, the undo banner.

    static let gBg          = dynamicColor(dark: "#0F1113", light: "#FAFAFA")
    static let gSurface     = dynamicColor(dark: "#171A1D", light: "#FFFFFF")
    static let gSurface2    = dynamicColor(dark: "#1F2327", light: "#F4F4F5")
    static let gSurface3    = dynamicColor(dark: "#282D32", light: "#EBEBED")
    /// The rail / sidebar ground. In light mode it is deliberately the same
    /// white as `gSurface`; the rail is separated by spacing, not by a slab.
    static let gSidebar     = dynamicColor(dark: "#0A0C0E", light: "#FFFFFF")

    // MARK: Lines
    //
    // The system is near-borderless. `gHairline` is the default and is meant to
    // be barely there; `gLine2` is for the rare divider that has to carry
    // structure on its own (a table rule, a focused field).

    static let gHairline    = dynamicColor(dark: "#262B30", light: "#EFEFEF")
    static let gLine2       = dynamicColor(dark: "#343A41", light: "#E0E0E0")

    // MARK: Ink

    static let gInk         = dynamicColor(dark: "#EDEFF1", light: "#1C1C1E")
    /// Secondary ink: metadata beside a title, section labels, inactive tabs.
    static let gInk2        = dynamicColor(dark: "#979FA8", light: "#6E6E73")
    /// Tertiary ink: the quietest text that still has to be readable.
    static let gInk3        = dynamicColor(dark: "#7A828C", light: "#7E7E85")

    // MARK: Status and priority

    /// In-progress amber. This was the old CTA colour; the CTA is now
    /// `gAccent`, and `gAmber` means "in progress" and nothing else.
    static let gAmber       = dynamicColor(dark: "#F5A623", light: "#A86200")
    /// In review. (Named for the old botanical palette; it is now a blue.)
    static let gLavender    = dynamicColor(dark: "#4C9AFF", light: "#2563EB")
    /// Urgent priority.
    static let gRed         = dynamicColor(dark: "#FF5A4D", light: "#DC2626")
    /// High priority.
    static let gOrange      = dynamicColor(dark: "#FF9142", light: "#C2410C")
    /// Low priority — quieter than `gInk3`, because low priority is a thing you
    /// are allowed to not notice.
    static let gPriorityLow = dynamicColor(dark: "#4A525A", light: "#B4B4B8")

    // MARK: Compatibility aliases
    //
    // These are the names the rest of the app already spells. They now point at
    // the Porcelain tokens above; prefer the canonical name in new code.

    /// The old green accent, used everywhere. Now simply the accent.
    static let gSage        = Color.gAccent
    /// The old "done" colour. Done is the accent now.
    static let gTeal        = Color.gAccent
    /// Was secondary text; now `gInk2`.
    static let gMuted       = Color.gInk2
    /// Was tertiary text; now `gInk3`.
    static let gFaint       = Color.gInk3
}

// MARK: - Type
//
// iOS body text is 17pt. The old ramp stopped at 13 and called it "the smallest
// text used anywhere", which was never true — 9, 10, 11 and 12pt all shipped as
// bare literals. The ramp below covers everything the app actually draws, so a
// call site never has a reason to invent a size.

enum GraftType {
    /// Uppercase section labels and counters. The smallest text in the app, and
    /// only ever used with `.semibold` + `microTracking`, never for prose.
    static let micro: CGFloat = 11
    /// Timestamps, chips, label pills — short metadata that sits under a title.
    static let caption: CGFloat = 13
    /// Metadata beside a title, and secondary rows in a form.
    static let secondary: CGFloat = 14
    /// Running text: descriptions, comments, button labels.
    static let body: CGFloat = 16
    /// Issue and project titles — the default for anything you tap through to.
    static let title: CGFloat = 17
    /// Screen section headings and empty-state titles.
    static let heading: CGFloat = 20
    /// The one big number or name at the top of a detail screen.
    static let display: CGFloat = 26

    /// Letter spacing for `micro`. Uppercase at 11pt closes up without it.
    static let microTracking: CGFloat = 0.6
}

// MARK: - Metrics

enum GraftMetrics {

    // MARK: Hit targets
    //
    // THE RULE: every interactive element is at least `GraftMetrics.tap` on its
    // smallest axis. The control heights below are *visual* heights — a 30pt
    // chip is fine, but it must carry `.frame(minWidth: tap, minHeight: tap)`
    // or an equivalent `.contentShape` so the thing you can hit is 44pt.

    /// Apple's minimum comfortable hit target. The floor for anything tappable.
    static let tap: CGFloat = 44
    /// A chip, a filter pill, an inline toggle.
    static let controlSmall: CGFloat = 30
    /// The default control height: text fields, pickers, secondary buttons.
    static let control: CGFloat = 34
    /// Primary buttons — the ones wearing `gAccent`.
    static let controlPrimary: CGFloat = 38

    // MARK: Radii — BUILD.md's 4 / 8 / 12 / 16 ladder

    /// Label chips and other small inline pills.
    static let radiusTight: CGFloat = 4
    /// Buttons, fields, badges.
    static let radiusSmall: CGFloat = 8
    /// The default: cards, rows, sheets-within-a-screen.
    static let radius: CGFloat = 12
    /// Large containers — a whole section, a modal.
    static let radiusLarge: CGFloat = 16
    /// Fully rounded. Use `Capsule()` where you can; this is for the cases
    /// where a `RoundedRectangle` is already in the shape position.
    static let pill: CGFloat = 999

    // MARK: Lines

    /// Border width. One physical point, everywhere — hairlines at 0.5 vanish
    /// on a non-Retina simulator and read as dirt on device.
    static let border: CGFloat = 1

    // MARK: Spacing — 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 56
    //
    // Hierarchy in this system comes from these, so they are worth spelling.

    /// Between a glyph and its label.
    static let spaceXXS: CGFloat = 4
    /// Between chips on the same line.
    static let spaceXS: CGFloat = 8
    /// Between the rows of a single card.
    static let spaceS: CGFloat = 12
    /// The screen gutter and the gap between cards.
    static let spaceM: CGFloat = 16
    /// Between a heading and its content.
    static let spaceL: CGFloat = 20
    /// Between sections of a screen.
    static let spaceXL: CGFloat = 24
    /// Between unrelated blocks.
    static let spaceXXL: CGFloat = 32
    /// Page-level top and bottom padding.
    static let space3XL: CGFloat = 40
    /// Around an empty state, which needs the room to look deliberate.
    static let space4XL: CGFloat = 56

    /// The screen gutter. Same value as `spaceM`; kept because every call site
    /// already spells it this way and it reads better at the edge of a screen.
    static let gutter: CGFloat = 16

    /// Default diameter of a `StatusRing`.
    static let ring: CGFloat = 16
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
        case .backlog: return .gInk3
        case .todo: return .gInk2
        case .inProgress: return .gAmber
        case .review: return .gLavender
        case .done: return .gAccent
        }
    }

    /// Kept for call sites that still want a glyph in a menu or a picker. The
    /// *row* treatment is `StatusRing`, which is drawn rather than symbolised
    /// so that it matches the web client exactly.
    var icon: String {
        switch self {
        case .backlog: return "circle"
        case .todo: return "circle.dotted"
        case .inProgress: return "circle.lefthalf.filled"
        case .review: return "circle.righthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    /// How much of the ring is filled, 0...1. `nil` means "no fill at all",
    /// which is how backlog and todo differ from a 0%-complete in-progress.
    var ringFill: CGFloat? {
        switch self {
        case .backlog: return nil
        case .todo: return nil
        case .inProgress: return 0.5
        case .review: return 0.75
        case .done: return 1
        }
    }
}

// MARK: - Status ring
//
// Status is a filling ring, not a dot — backlog an empty ring, todo dashed,
// in-progress half filled, review three-quarter, done a solid disc with a
// check. This is the one component that has to be identical on both platforms,
// so the geometry is written as ratios of `size` and the web client mirrors
// them in SVG:
//
//     stroke width   = size × 0.125        (2pt at 16)
//     gap            = size × 0.0625       (1pt at 16)
//     core diameter  = size × 0.625        (10pt at 16) — the filled wedge
//     dash (todo)    = [size × 0.125, size × 0.125]
//     check stroke   = size × 0.14, round cap and join
//
// The wedge starts at twelve o'clock and fills clockwise. It is drawn as a
// trimmed circle stroked with a line as wide as its own diameter, which is the
// cheapest way to get a pie slice out of a stroke.

struct StatusRing: View {
    let status: IssueStatus
    var size: CGFloat

    init(status: IssueStatus, size: CGFloat = GraftMetrics.ring) {
        self.status = status
        self.size = size
    }

    init(status: String, size: CGFloat = GraftMetrics.ring) {
        self.status = IssueStatus(rawValue: status) ?? .backlog
        self.size = size
    }

    private var stroke: CGFloat { size * 0.125 }
    private var core: CGFloat { size * 0.625 }

    var body: some View {
        ZStack {
            if status == .done {
                Circle()
                    .fill(Color.gAccent)
                CheckMark()
                    .stroke(
                        Color.gOnAccent,
                        style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: size, height: size)
            } else {
                if status == .todo {
                    Circle()
                        .strokeBorder(
                            status.color,
                            style: StrokeStyle(lineWidth: stroke, dash: [size * 0.125, size * 0.125])
                        )
                } else {
                    Circle()
                        .strokeBorder(status.color, lineWidth: stroke)
                }

                if let fill = status.ringFill {
                    // A circle laid out in a `core / 2` box has a path radius
                    // of `core / 4`; stroking it `core / 2` wide paints solidly
                    // from the centre out to `core / 2`, i.e. a disc of diameter
                    // `core`. Trimming it takes a clockwise slice of that disc.
                    // Rotating -90° moves the start from three to twelve.
                    Circle()
                        .trim(from: 0, to: fill)
                        .stroke(status.color, lineWidth: core / 2)
                        .frame(width: core / 2, height: core / 2)
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }
}

/// The tick inside a done ring. Drawn, not an SF Symbol, so it lands on the
/// same pixels as the web client's `<path>`.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.29, y: h * 0.52))
        p.addLine(to: CGPoint(x: w * 0.43, y: h * 0.67))
        p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.34))
        return p
    }
}

// MARK: - Priority
//
// Priority pairs colour with a distinct *shape*, never colour alone: a diamond
// for urgent, a filled disc for high, a hollow disc for normal, a bar for low.
// Colour-blind users and anyone glancing at a greyscale screenshot still get
// the ordering.

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
        case .normal: return .gInk2
        case .low: return .gPriorityLow
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
        HStack(spacing: GraftMetrics.spaceXXS) {
            StatusRing(status: s, size: 12)
            Text(s.label)
                .font(.system(size: GraftType.caption, weight: .medium))
        }
        .foregroundStyle(s.color)
        .padding(.horizontal, GraftMetrics.spaceXS)
        .padding(.vertical, GraftMetrics.spaceXXS)
        .background(s.color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct PriorityDot: View {
    let priority: String
    var size: CGFloat = 10

    var body: some View {
        let p = IssuePriority(rawValue: priority) ?? .normal
        Group {
            switch p {
            case .urgent:
                // A diamond: the only shape here with corners.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(p.color)
                    .frame(width: size * 0.72, height: size * 0.72)
                    .rotationEffect(.degrees(45))
            case .high:
                Circle()
                    .fill(p.color)
                    .frame(width: size * 0.75, height: size * 0.75)
            case .normal:
                Circle()
                    .strokeBorder(p.color, lineWidth: 1.5)
                    .frame(width: size * 0.7, height: size * 0.7)
            case .low:
                Capsule()
                    .fill(p.color)
                    .frame(width: size * 0.72, height: size * 0.22)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(p.label) priority")
    }
}

/// A milestone. Deliberately *not* accented — a milestone appears on most rows,
/// and green that appears on most rows stops meaning anything. The old leaf was
/// a leftover from the botanical theme; a flag is what a milestone is.
struct MilestoneTag: View {
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9))
            Text(name)
                .font(.system(size: GraftType.caption, weight: .medium))
        }
        .foregroundStyle(Color.gInk2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.gSurface2)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radiusTight)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }
}

/// One of an issue's labels. Labels are writable in the app and were displayed
/// nowhere; this is the chip that fixes that.
struct GraftLabelChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: GraftType.caption, weight: .medium))
            .foregroundStyle(Color.gInk2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.gSurface2)
            .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusTight))
            .overlay(
                RoundedRectangle(cornerRadius: GraftMetrics.radiusTight)
                    .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
            )
    }
}

/// An empty state. The optional action is for the two cases where empty is a
/// thing the user can *fix* — "nothing configured" wants a way to configure it,
/// and "no results" wants a way to clear the filters. Without an action, this
/// is the plain "nothing here yet" state it always was.
struct GraftEmptyState: View {
    let title: String
    let subtitle: String
    var systemImage: String = "tray"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: GraftMetrics.spaceS) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.gInk3)
            Text(title)
                .font(.system(size: GraftType.heading, weight: .semibold))
                .foregroundStyle(Color.gInk)
            Text(subtitle)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gInk2)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: GraftType.body, weight: .semibold))
                        .foregroundStyle(Color.gOnAccent)
                        .padding(.horizontal, GraftMetrics.spaceL)
                        .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                        .background(
                            Color.gAccent,
                            in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                        )
                }
                .padding(.top, GraftMetrics.spaceXXS)
            }
        }
        .padding(GraftMetrics.space3XL)
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
            HStack(spacing: GraftMetrics.spaceXXS) {
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
                    .foregroundStyle(Color.gInk3)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().strokeBorder(
                            Color.gLine2,
                            style: StrokeStyle(lineWidth: GraftMetrics.border, dash: [3, 2])
                        )
                    )
            } else {
                Text(initials)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(Color.gInk2)
                    .frame(width: size, height: size)
                    .background(Color.gSurface2, in: Circle())
                    .overlay(Circle().strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border))
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
        HStack(spacing: GraftMetrics.spaceS) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 15))
                .foregroundStyle(Color.gInk2)
            Text(action.message)
                .font(.system(size: GraftType.body))
                .foregroundStyle(Color.gInk)
            Spacer(minLength: GraftMetrics.spaceXS)
            Button("Undo") {
                Task { await action.undo(); dismiss() }
            }
            .font(.system(size: GraftType.body, weight: .semibold))
            .foregroundStyle(Color.gAccentText)
            .frame(minHeight: GraftMetrics.tap)
        }
        .padding(.horizontal, GraftMetrics.spaceM)
        .padding(.vertical, 10)
        .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gLine2, lineWidth: GraftMetrics.border)
        )
        // Shadow is for things that float. This is one of the two places in the
        // app that qualifies.
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
                    .padding(.bottom, GraftMetrics.spaceS)
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

// MARK: - Issue row
//
// One row shared by the Inbox and the project list. They had drifted into two
// different treatments — one put the status glyph on the left, the other made
// it a badge on the right — so the same issue looked different depending on
// which screen you reached it from. This matches the web client's card:
// priority as a left edge, the status ring beside the title, metadata beneath.

struct GraftIssueRow: View {
    let issue: GraftIssue
    var project: GraftProject? = nil
    var due: String? = nil
    var showProject: Bool = true
    /// Labels beyond this are summarised as "+n" rather than wrapping the row.
    var maxLabels: Int = 3

    var body: some View {
        let status = IssueStatus(rawValue: issue.status) ?? .backlog
        let priority = IssuePriority(rawValue: issue.priority) ?? .normal
        let flagged = priority == .urgent || priority == .high
        let overdue = (due?.contains("overdue")) == true
        let done = issue.status == "done"
        let labels = issue.labels.filter { !$0.isEmpty }

        HStack(spacing: 0) {
            if flagged {
                Rectangle()
                    .fill(priority.color)
                    .frame(width: 3)
            }

            HStack(alignment: .top, spacing: 11) {
                StatusRing(status: status, size: GraftMetrics.ring)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 7) {
                    Text(issue.title)
                        .font(.system(size: GraftType.title, weight: .medium))
                        .foregroundStyle(done ? Color.gInk2 : Color.gInk)
                        .strikethrough(done, color: Color.gInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: GraftMetrics.spaceXS) {
                        PriorityBadge(priority: issue.priority)
                        if let due {
                            Text(due)
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(overdue ? Color.gRed : Color.gInk2)
                        }
                        if let milestone = issue.milestoneName {
                            MilestoneTag(name: milestone)
                        }
                        if showProject, let project {
                            Text(project.name)
                                .font(.system(size: GraftType.caption))
                                .foregroundStyle(Color.gInk2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        GraftAvatar(name: issue.assignee, size: 24)
                    }

                    if !labels.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(labels.prefix(maxLabels), id: \.self) { label in
                                GraftLabelChip(text: label)
                            }
                            if labels.count > maxLabels {
                                Text("+\(labels.count - maxLabels)")
                                    .font(.system(size: GraftType.caption, weight: .medium))
                                    .foregroundStyle(Color.gInk3)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, GraftMetrics.spaceS)
            .padding(.vertical, GraftMetrics.spaceS)
        }
        .frame(minHeight: GraftMetrics.tap)
        .opacity(issue.archived ? 0.55 : 1)
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }
}

// MARK: - Relative dates

enum GraftDate {
    static func relative(_ iso: String) -> String {
        guard let date = timestamp(from: iso) else { return "" }
        let mins = Int(Date().timeIntervalSince(date) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        if mins < 1440 { return "\(mins / 60)h ago" }
        return "\(mins / 1440)d ago"
    }

    /// Parses a server timestamp, with or without a timezone designator.
    ///
    /// The server writes `datetime.utcnow().isoformat()` — no trailing `Z` —
    /// and `ISO8601DateFormatter` rejects that outright, so every "Created" and
    /// "Updated" line rendered blank. A naive timestamp from this server is
    /// UTC, which is the same assumption the web client makes.
    static func timestamp(from iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let stamped = zoned(iso)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: stamped) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stamped)
    }

    private static func zoned(_ iso: String) -> String {
        if iso.hasSuffix("Z") { return iso }
        // An explicit offset always lives in the time half, after the T — the
        // dashes in the date half are not one.
        if let t = iso.firstIndex(of: "T") {
            let time = iso[t...].dropFirst()
            if time.contains(where: { $0 == "+" || $0 == "-" }) { return iso }
        }
        return iso + "Z"
    }

    /// `yyyy-MM-dd` read in the device's own calendar. Pinned to POSIX/Gregorian
    /// so a phone set to a non-Gregorian calendar still agrees with the server
    /// about what year it is.
    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// A stored due date as local midnight. Paired with `dayString(from:)` so a
    /// date read out and written straight back is unchanged — the milestone
    /// form used to read UTC midnight and write local, which walked the date a
    /// day earlier on every save west of Greenwich.
    static func day(from dateString: String?) -> Date? {
        guard let dateString, dateString.count >= 10 else { return nil }
        return dayFormatter.date(from: String(dateString.prefix(10)))
    }

    /// The inverse of `day(from:)`.
    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Days from today to a yyyy-MM-dd string, parsed in the local calendar so
    /// a due date never slips a day depending on the timezone.
    static func daysUntil(_ dateString: String?) -> Int? {
        guard let due = day(from: dateString) else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day
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
