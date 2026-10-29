//
//  Motion.swift
//  Graft
//
//  How Graft moves. One set of timings, one haptic vocabulary, and the few
//  moments that earn a little delight: an issue closing, a milestone
//  finishing, a page growing out of the row you tapped. Calm and fast first —
//  nothing here holds up a tap — and still under Reduce Motion: the change
//  happens, it just doesn't move (kit/specs/MOTION.md). `ReducedMotion` in
//  GraftApp.swift strips animations from every transaction; the keyframe and
//  repeating animations below, which transactions don't reach, check
//  `accessibilityReduceMotion` themselves.
//

import SwiftUI
import UIKit

// MARK: - Timings

enum GraftMotion {
    /// A press, a toggle, a chip changing state. 120 ms.
    static let micro = Animation.easeOut(duration: 0.12)
    /// Panels, banners, a status sliding over. 200 ms, out-expo.
    static let standard = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.2)
    /// Something crossing the screen: a row tucking away, a card changing column.
    static let move = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.32)
    /// An object landing: a check, a chip, a planted flag.
    static let settle = Animation.spring(duration: 0.35, bounce: 0.2)
    /// The moments that earn choreography: a milestone finishing.
    static let story = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.6)
}

// MARK: - Haptics
//
// One place decides which moments are felt, so the app has a vocabulary
// rather than a buzz on every tap.

enum GraftHaptic {
    /// An issue done, a milestone finished.
    case success
    /// Something put down: a card dropped, a refresh landed, an assignee set.
    case land
    /// A refusal.
    case warning

    @MainActor
    func play() {
        switch self {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .land: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

/// A change made on this phone, animated: the store wraps its own edits in
/// this so a closed issue tucks out of the list and a dragged card slides into
/// its column, while changes arriving from a sync simply land. Under Reduce
/// Motion the app-wide `ReducedMotion` strips the animation.
enum GraftEdit {
    @MainActor
    static func animated(_ body: () -> Void) {
        withAnimation(GraftMotion.move, body)
    }
}

// MARK: - Arrival
//
// A screen arrives rather than appears: pushed, or switched to, its rows and
// headers rise 6 pt and fade in top to bottom, all of it inside about 150 ms.
// Only on arrival — scrolling, a sync landing or coming back to a screen leaves
// everything where it is. Each page carries an arrival stamp; `graftArrive()`
// plays only for views appearing just after it, delayed by how far down the
// screen they sit.

struct GraftArrival: Equatable {
    var date = Date()
    var token = UUID()
}

extension EnvironmentValues {
    @Entry var graftArrival: GraftArrival? = nil
    /// Whether this view's tab is the one showing; switching to it replays the
    /// arrival.
    @Entry var graftTabActive = true
    /// The stack's namespace for page-from-row zooms. Nil outside a stack.
    @Entry var graftZoomNamespace: Namespace.ID? = nil
}

private struct GraftArrivalRoot: ViewModifier {
    @Environment(\.graftTabActive) private var active
    @State private var arrival = GraftArrival()

    func body(content: Content) -> some View {
        content
            .environment(\.graftArrival, arrival)
            .onChange(of: active) { _, now in if now { arrival = GraftArrival() } }
    }
}

private struct GraftArrive: ViewModifier {
    @Environment(\.graftArrival) private var arrival
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var played: UUID?
    @State private var shown = true
    @State private var y: CGFloat = 0

    /// Appearing this long after the page arrived means scrolled to, not
    /// arriving: it just shows.
    private static let window: TimeInterval = 0.6

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { y = $0 }
            .onAppear(perform: play)
            .onChange(of: arrival) { _, _ in play() }
    }

    private func play() {
        guard let arrival, played != arrival.token else { return }
        played = arrival.token
        guard !reduceMotion, Date().timeIntervalSince(arrival.date) < Self.window else {
            shown = true
            return
        }
        shown = false
        // Top of the screen first; nothing waits longer than 0.15 s.
        let screen = max(1, UIScreen.main.bounds.height)
        let delay = 0.15 * min(1, max(0, y / screen))
        DispatchQueue.main.async {
            withAnimation(GraftMotion.standard.delay(delay)) { shown = true }
        }
    }
}

// MARK: - Page from row
//
// Opening an issue or a project grows its page out of the row you tapped, and
// going back shrinks it into the same spot.

private struct GraftZoomSource: ViewModifier {
    @Environment(\.graftZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String

    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct GraftZoomDestination: ViewModifier {
    @Environment(\.graftZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String

    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

extension GraftRoute {
    /// What a route's page zooms out of; links mark their row with the same.
    var zoomID: String {
        switch self {
        case .project(let id): return "project:\(id)"
        case .issue(let issue): return "issue:\(issue.id)"
        case .series(let issue): return "series:\(issue.id)"
        }
    }
}

extension View {
    /// Marks a page: what `graftArrive()` below it times itself from.
    func graftArrivalRoot() -> some View { modifier(GraftArrivalRoot()) }

    /// Rises into place when the page it is on arrives.
    func graftArrive() -> some View { modifier(GraftArrive()) }

    /// Marks the row or card a route's page zooms out of.
    func graftZoomSource(_ route: GraftRoute) -> some View { modifier(GraftZoomSource(id: route.zoomID)) }

    /// Marks a pushed page as the far end of that zoom.
    func graftZoomDestination(_ route: GraftRoute) -> some View { modifier(GraftZoomDestination(id: route.zoomID)) }
}

extension AnyTransition {
    /// A row leaving a list because of something done to it: it tucks away to
    /// the side, and arrives in its new place by fading up.
    static var graftTuck: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    /// A label or a chip arriving: a small pop.
    static var graftPop: AnyTransition {
        .scale(scale: 0.6).combined(with: .opacity)
    }
}

// MARK: - Strike
//
// Closing an issue strikes its title through from left to right instead of the
// line simply being there: a struck copy of the text is revealed under a mask
// that sweeps across.

struct GraftStrikeText: View {
    let text: String
    let done: Bool
    var font: Font
    var colour: Color
    var doneColour: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0…1, how much of the struck copy shows.
    @State private var sweep: CGFloat

    init(_ text: String, done: Bool, font: Font, colour: Color, doneColour: Color) {
        self.text = text
        self.done = done
        self.font = font
        self.colour = colour
        self.doneColour = doneColour
        _sweep = State(initialValue: done ? 1 : 0)
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(colour)
            // What the sweep hasn't reached yet.
            .mask(alignment: .trailing) {
                GeometryReader { g in
                    Rectangle()
                        .frame(width: g.size.width * (1 - sweep))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(text)
                    .font(font)
                    .foregroundStyle(doneColour)
                    .strikethrough(true, color: doneColour)
                    .mask(alignment: .leading) {
                        GeometryReader { g in
                            Rectangle().frame(width: g.size.width * sweep)
                        }
                    }
                    .accessibilityHidden(true)
            }
            .onChange(of: done) { _, now in
                if reduceMotion {
                    sweep = now ? 1 : 0
                } else {
                    withAnimation(now ? GraftMotion.move : GraftMotion.standard) { sweep = now ? 1 : 0 }
                }
            }
    }
}

// MARK: - Personalities
//
// The three people an issue can be assigned to each have a small way of
// saying "got it" when one lands on them. Played only when the assignee
// changes — never on first draw, never on scroll.

enum GraftPersona {
    case dan, hermes, clawrence, other

    init(_ name: String) {
        switch name.lowercased().split(separator: " ").first.map(String.init) ?? "" {
        case "dan", "daniel": self = .dan
        case "hermes": self = .hermes
        case "clawrence": self = .clawrence
        default: self = .other
        }
    }
}

private struct PersonaPose {
    var angle = 0.0
    var x = 0.0
    var y = 0.0
    var scale = 1.0
}

private struct GraftPersonaGreeting: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    @State private var trigger = 0

    func body(content: Content) -> some View {
        greeting(content)
            .onChange(of: name) { old, new in
                guard !reduceMotion, !new.isEmpty, old != new else { return }
                trigger += 1
            }
    }

    @ViewBuilder
    private func greeting(_ content: Content) -> some View {
        switch GraftPersona(name) {
        case .dan:
            // A nod.
            content.keyframeAnimator(initialValue: PersonaPose(), trigger: trigger) { view, pose in
                view.offset(y: pose.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(2.5, duration: 0.12)
                    CubicKeyframe(-1, duration: 0.12)
                    SpringKeyframe(0, duration: 0.25)
                }
            }
        case .hermes:
            // Winged sandals: a quick hop.
            content.keyframeAnimator(initialValue: PersonaPose(), trigger: trigger) { view, pose in
                view.offset(y: pose.y).scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(-6, duration: 0.14)
                    CubicKeyframe(0, duration: 0.14)
                    CubicKeyframe(-2, duration: 0.08)
                    SpringKeyframe(0, duration: 0.2)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.08, duration: 0.14)
                    SpringKeyframe(1, duration: 0.3)
                }
            }
        case .clawrence:
            // A pinch-pinch, side to side.
            content.keyframeAnimator(initialValue: PersonaPose(), trigger: trigger) { view, pose in
                view.rotationEffect(.degrees(pose.angle))
            } keyframes: { _ in
                KeyframeTrack(\.angle) {
                    CubicKeyframe(-12, duration: 0.08)
                    CubicKeyframe(10, duration: 0.1)
                    CubicKeyframe(-6, duration: 0.08)
                    SpringKeyframe(0, duration: 0.2)
                }
            }
        case .other:
            content.keyframeAnimator(initialValue: PersonaPose(), trigger: trigger) { view, pose in
                view.scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.12, duration: 0.12)
                    SpringKeyframe(1, duration: 0.3)
                }
            }
        }
    }
}

extension View {
    /// The assignee's "got it" when an issue lands on them.
    func graftPersonaGreeting(_ name: String) -> some View {
        modifier(GraftPersonaGreeting(name: name))
    }
}

// MARK: - Seedling
//
// Nothing left to do. Graft's empty state grows a seedling instead of showing
// an empty tray: the stem draws up, two leaves unfurl, and then it sways a
// little in a breeze for as long as the screen is quiet.

struct GraftSeedling: View {
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown: CGFloat = 0
    @State private var leaves: CGFloat = 0
    @State private var sway = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Soil.
            Capsule()
                .fill(Color.gInk3.opacity(0.35))
                .frame(width: size * 0.62, height: size * 0.06)
            ZStack(alignment: .bottom) {
                SeedlingStem()
                    .trim(from: 0, to: grown)
                    .stroke(Color.gAccent, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                SeedlingLeaf()
                    .fill(Color.gAccent)
                    .frame(width: size * 0.34, height: size * 0.2)
                    .scaleEffect(leaves, anchor: .bottomTrailing)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -size * 0.17, y: -size * 0.52)
                SeedlingLeaf()
                    .fill(Color.gAccent.opacity(0.85))
                    .frame(width: size * 0.3, height: size * 0.18)
                    .scaleEffect(x: -1)
                    .scaleEffect(leaves, anchor: .bottomLeading)
                    .rotationEffect(.degrees(16))
                    .offset(x: size * 0.15, y: -size * 0.66)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(sway ? 3 : -3), anchor: .bottom)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { grown = 1; leaves = 1; return }
            withAnimation(.easeOut(duration: 0.45)) { grown = 1 }
            withAnimation(GraftMotion.settle.delay(0.35)) { leaves = 1 }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(0.8)) { sway = true }
        }
    }
}

private struct SeedlingStem: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.midX + rect.width * 0.02, y: rect.minY + rect.height * 0.24),
                   control1: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.maxY - rect.height * 0.35),
                   control2: CGPoint(x: rect.midX + rect.width * 0.1, y: rect.minY + rect.height * 0.5))
        return p
    }
}

private struct SeedlingLeaf: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.maxX * 0.15, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.maxX * 0.85, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pull to refresh
//
// Letting go of a pull to refresh: when the sync comes back a leaf sprouts at
// the top of the list for a moment, with a light tap — the list was watered.
// It claims nothing about the result; the sync strip still says if the server
// couldn't be reached.

private struct GraftRefresh: ViewModifier {
    let action: () async -> Void
    @State private var landed = 0
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .refreshable {
                await action()
                GraftHaptic.land.play()
                landed += 1
            }
            .overlay(alignment: .top) {
                if showing {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.gAccent)
                        .symbolEffect(.bounce, value: landed)
                        .frame(width: 30, height: 30)
                        .background(Color.gSurface2, in: Circle())
                        .overlay(Circle().strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border))
                        .padding(.top, GraftMetrics.spaceXS)
                        .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: landed) { _, now in
                withAnimation(GraftMotion.settle) { showing = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if landed == now { withAnimation(GraftMotion.standard) { showing = false } }
                }
            }
    }
}

extension View {
    /// `.refreshable`, with the leaf that sprouts when it lands.
    func graftRefreshable(_ action: @escaping () async -> Void) -> some View {
        modifier(GraftRefresh(action: action))
    }
}

// MARK: - Confetti-lite
//
// A milestone finishing: a dozen small flecks in the project's palette burst
// up from the flag and fall away inside 0.9 s. Drawn on a Canvas from a
// timeline, so it costs nothing when it isn't playing.

struct GraftConfetti: View {
    /// Bump to play.
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started: Date?

    private static let colours: [Color] = [.gAccent, .gAmber, .gLavender, .gInk2]
    private static let pieces: [(angle: Double, speed: Double, spin: Double)] = (0..<14).map { i in
        let a = -Double.pi / 2 + (Double(i) - 6.5) * 0.17
        return (a, 70 + Double((i * 37) % 40), Double((i * 53) % 7) - 3)
    }

    var body: some View {
        TimelineView(.animation(paused: started == nil)) { t in
            Canvas { ctx, size in
                guard let started else { return }
                let e = t.date.timeIntervalSince(started)
                guard e < 0.9 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                for (i, p) in Self.pieces.enumerated() {
                    let x = origin.x + cos(p.angle) * p.speed * e
                    let y = origin.y + sin(p.angle) * p.speed * e + 160 * e * e
                    var piece = ctx
                    piece.opacity = max(0, 1 - e / 0.9)
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(p.spin * e * 4))
                    piece.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)),
                               with: .color(Self.colours[i % Self.colours.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            started = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { started = nil }
        }
    }
}
