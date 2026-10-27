import SwiftUI
import UIKit
import GameController

// MARK: - Hardware keyboard
//
// Every screen can be driven from a keyboard, so a phone plugged into a monitor
// (see `ExternalDisplay.swift`) can be left face down while you work. Nothing
// here depends on a monitor being connected: the same keys are worth having on
// an iPad with a keyboard case.
//
// ## Why UIKeyCommand and not `onKeyPress`
//
// `onKeyPress` needs the view focused, and on iOS a non-text view only ever
// receives focus with Accessibility ▸ Keyboards ▸ Full Keyboard Access switched
// on. So the keys are `UIKeyCommand`s declared by a zero-size view controller
// (`KeyCommandCatcher`) that makes itself first responder. The root carries one,
// and so does every screen and list that takes keys, as Quire's do: each push,
// tab switch or sheet closing brings a catcher on screen that takes the keys
// straight back, rather than leaving the root's timer to notice they went
// missing (which it never does while a text-taking view holds them). That placement is
// also what keeps typing safe: tapping a text field makes *it* first responder,
// the catcher drops out of the responder chain, and every letter goes into the
// field.
//
// The commands are global, so they need to know which screen is showing.
// `KeyCommandRouter` keeps a stack of handlers that screens push while visible;
// each key is offered top-down until one takes it. `RootView` sits at the
// bottom with the keys that work everywhere (tabs, back, refresh, help).
//
// The key map (`KeyboardShortcutsView` draws the same table):
//
//   1 2 3 / ⌘1 ⌘2 ⌘3   Inbox, Projects, Settings
//   ↑ ↓ / j k          move the selection
//   ↵                  open it
//   esc                clear the selection, then go back
//   n                  new issue (new project on the project list)
//   /                  search
//   r                  refresh
//   ] [                status forward / back
//   x                  done / reopen
//   p                  cycle priority
//   a                  archive
//   f                  favourite a project
//   t e                edit the title / description (issue screen)
//   ?                  keyboard shortcuts
//   ⌥⌘ = − T P H       monitor: text size, theme, pause, hints

/// What a screen wants done with the keys. Each returns whether it took the key;
/// one that does not is offered to the screen underneath.
struct GraftKeyHandlers {
    var move: (Int) -> Bool = { _ in false }
    var open: () -> Bool = { false }
    var escape: () -> Bool = { false }
    /// Single characters: letters, digits, `/`, `[`, `]`, `?`.
    var key: (String) -> Bool = { _ in false }
}

/// Routes the app-wide key commands to whichever screen is showing.
@MainActor
final class KeyCommandRouter {
    static let shared = KeyCommandRouter()

    private var stack: [(id: UUID, handlers: GraftKeyHandlers)] = []
    /// The keys that work everywhere (`RootView`'s), offered after every
    /// screen. Kept apart from the stack rather than pushed first: the order
    /// SwiftUI fires `onAppear` in is not promised, and the root landing on top
    /// of the Inbox would take esc away from the selection.
    private var base: GraftKeyHandlers?

    /// Push a screen's handlers, or refresh them in place. In place matters: a
    /// list re-registers whenever its rows change, which a sync does even while
    /// it sits under a pushed issue, and re-appending would float it back to the
    /// top and hand it the arrows.
    func register(_ id: UUID, _ handlers: GraftKeyHandlers) {
        if let i = stack.firstIndex(where: { $0.id == id }) {
            stack[i].handlers = handlers
        } else {
            stack.append((id, handlers))
        }
    }

    func unregister(_ id: UUID) {
        stack.removeAll { $0.id == id }
    }

    func setBase(_ handlers: GraftKeyHandlers?) {
        base = handlers
    }

    func move(_ delta: Int) { offer { $0.move(delta) } }
    func open() { offer { $0.open() } }
    func escape() { offer { $0.escape() } }
    func key(_ k: String) { offer { $0.key(k) } }

    private func offer(_ attempt: (GraftKeyHandlers) -> Bool) {
        for entry in stack.reversed() where attempt(entry.handlers) { return }
        if let base { _ = attempt(base) }
    }
}

/// Whether a hardware keyboard is attached right now. Read when a sheet opens, to
/// decide whether to focus its first field — with only the on-screen keyboard,
/// popping it up unasked covers half the form.
@MainActor
var graftHardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }

// MARK: - First-responder catcher

/// Declares the key commands and takes first responder while on screen.
///
/// `RootView` carries one, routed through `KeyCommandRouter`. Sheets carry one
/// too (in `GraftSheetHeader` and `GraftSheetScaffold`) for a different reason:
/// it routes nothing but the monitor's ⌥⌘ keys, and holding first responder
/// *inside* the sheet puts the
/// sheet's own `.keyboardShortcut`s — esc to cancel, ⌘↵ to confirm — in the
/// responder chain, and takes the keys away from the list underneath.
struct KeyCommandCatcher: UIViewControllerRepresentable {
    /// Route through `KeyCommandRouter`. False for a sheet's catcher.
    var routes = true

    func makeUIViewController(context: Context) -> KeyCommandController {
        let controller = KeyCommandController()
        controller.routes = routes
        return controller
    }

    func updateUIViewController(_ controller: KeyCommandController, context: Context) {
        controller.routes = routes
    }
}

final class KeyCommandController: UIViewController {
    var routes = true

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags = [], _ action: Selector,
                 title: String? = nil, priority: Bool = false) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            if let title { command.discoverabilityTitle = title }
            // Arrows would otherwise scroll the enclosing scroll view instead.
            command.wantsPriorityOverSystemBehavior = priority
            // These are the characters printed on the keys, not menu shortcuts
            // to be moved somewhere reachable. Left on, UIKit remaps punctuation
            // — `[` `]` `/` `=` `-` — to suit the layout (and swaps `[` for `]`
            // in a right-to-left language), and a key that types `]` can stop
            // matching the command that asks for it.
            command.allowsAutomaticLocalization = false
            command.allowsAutomaticMirroring = false
            commands.append(command)
        }

        // The monitor's keys act on the monitor, not on any screen, so every
        // catcher declares them — a sheet's included. Behind the guards below
        // they went dead whenever a sheet was up, the `?` sheet that lists
        // them among others.
        add("=", [.command, .alternate], #selector(displayLarger), title: "Monitor text larger")
        // ⌥⌘+ arrives as "+" on some layouts and as "=" plus shift on others.
        add("+", [.command, .alternate], #selector(displayLarger))
        add("=", [.command, .alternate, .shift], #selector(displayLarger))
        add("-", [.command, .alternate], #selector(displaySmaller), title: "Monitor text smaller")
        add("t", [.command, .alternate], #selector(displayTheme), title: "Monitor theme")
        add("p", [.command, .alternate], #selector(displayPause), title: "Pause monitor")
        add("h", [.command, .alternate], #selector(displayHints), title: "Monitor key hints")

        guard routes else { return commands }
        // A sheet is up over the screen this catcher belongs to: its keys are
        // the sheet's. Normally the sheet's own catcher has first responder and
        // this is never asked, but not every presentation carries one (a share
        // sheet, a confirmation dialog).
        if view.window?.rootViewController?.presentedViewController != nil { return commands }

        add(UIKeyCommand.inputUpArrow, [], #selector(moveUp), title: "Previous", priority: true)
        add(UIKeyCommand.inputDownArrow, [], #selector(moveDown), title: "Next", priority: true)
        add("\r", [], #selector(openSelection), title: "Open")
        add(UIKeyCommand.inputEscape, [], #selector(escape), title: "Back")

        for (digit, title) in [("1", "Inbox"), ("2", "Projects"), ("3", "Settings")] {
            add(digit, [], #selector(letter(_:)))
            add(digit, .command, #selector(letter(_:)), title: title)
        }
        for character in ["j", "k", "n", "/", "r", "]", "[", "x", "p", "a", "f", "t", "e", "?"] {
            add(character, [], #selector(letter(_:)))
        }
        // Shift-/ arrives as "?" on most layouts, and as "/" plus shift on some.
        add("/", .shift, #selector(help))
        return commands
    }

    @objc private func moveUp() { KeyCommandRouter.shared.move(-1) }
    @objc private func moveDown() { KeyCommandRouter.shared.move(1) }
    @objc private func openSelection() { KeyCommandRouter.shared.open() }
    @objc private func escape() { KeyCommandRouter.shared.escape() }
    @objc private func help() { KeyCommandRouter.shared.key("?") }
    @objc private func letter(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        KeyCommandRouter.shared.key(input)
    }
    @objc private func displayLarger() { ExternalDisplayModel.shared.adjustTextSize(1) }
    @objc private func displaySmaller() { ExternalDisplayModel.shared.adjustTextSize(-1) }
    @objc private func displayTheme() { ExternalDisplayModel.shared.cycleTheme() }
    @objc private func displayPause() { ExternalDisplayModel.shared.togglePause() }
    @objc private func displayHints() { ExternalDisplayModel.shared.toggleHints() }

    private var reclaim: Timer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // A text field giving up focus, or a sheet closing, leaves the window
        // with no first responder, and then no key reaches the app at all. Take
        // it back — but never from a field being typed into, and never from
        // another catcher, or a sheet's and the root's would trade it forever.
        reclaim?.invalidate()
        reclaim = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil, !self.isFirstResponder else { return }
                // The root's catcher stands back while a sheet is up; the
                // sheet's own catcher is the one that should hold the keys.
                if self.routes, self.view.window?.rootViewController?.presentedViewController != nil { return }
                let holder = FirstResponder.current()
                if !(holder is UIKeyInput), !(holder is KeyCommandController) {
                    self.becomeFirstResponder()
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        reclaim?.invalidate()
        reclaim = nil
    }
}

/// Asks the responder chain who is first responder: an action sent to `nil`
/// goes to exactly that object.
@MainActor
enum FirstResponder {
    fileprivate static var captured: UIResponder?

    static func current() -> UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(UIResponder.graft_captureFirstResponder),
                                        to: nil, from: nil, for: nil)
        return captured
    }
}

extension UIResponder {
    @objc fileprivate func graft_captureFirstResponder() {
        FirstResponder.captured = self
    }
}

// MARK: - Sheets

extension View {
    /// Holds first responder inside a sheet, so its keyboard shortcuts work and
    /// the screen underneath stops hearing keys. See `KeyCommandCatcher`.
    func graftSheetKeys() -> some View {
        background(KeyCommandCatcher(routes: false).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

// MARK: - Screens

extension View {
    /// Registers a screen's key handlers for as long as it is on screen. For
    /// screens without a list — an issue — or the root's always-on keys.
    ///
    /// `base` is for `RootView` alone: those handlers are offered last, after
    /// every screen's, whatever order things appeared in.
    func graftKeys(_ handlers: GraftKeyHandlers, base: Bool = false) -> some View {
        modifier(GraftKeyScreen(handlers: handlers, isBase: base))
    }

    /// Arrow-key selection over a list of ids, mirrored to the monitor.
    ///
    /// - `ids`: the rows in display order.
    /// - `selection`: the host's selection, so it can highlight and scroll.
    /// - `display`: what the monitor shows for a given selection.
    /// - `onOpen`: Return on a row.
    /// - `key`: everything else, with the selected id if there is one. `j`/`k`
    ///   never get here — they move.
    func graftKeyList(ids: [String],
                      selection: Binding<String?>,
                      display: @escaping (String?) -> ExternalDisplayContent,
                      onOpen: @escaping (String) -> Void,
                      key: @escaping (String, String?) -> Bool = { _, _ in false }) -> some View {
        modifier(GraftKeyList(ids: ids, selection: selection, display: display, onOpen: onOpen, key: key))
    }

    /// The ring drawn round the row the keyboard is on.
    func graftKeySelected(_ selected: Bool, radius: CGFloat = GraftMetrics.radius) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.gAccent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Holds the closures a screen handed over on its latest render.
///
/// A screen's handlers close over its values as of the render that made them.
/// The router is given thin forwarders into this box once, and the box is
/// refilled on every render, so the router never acts on a stale copy and
/// nothing has to re-register to stay current.
@MainActor
private final class HandlerBox {
    var handlers = GraftKeyHandlers()

    var forwarding: GraftKeyHandlers {
        GraftKeyHandlers(
            move: { [unowned self] in self.handlers.move($0) },
            open: { [unowned self] in self.handlers.open() },
            escape: { [unowned self] in self.handlers.escape() },
            key: { [unowned self] in self.handlers.key($0) }
        )
    }
}

private struct GraftKeyScreen: ViewModifier {
    let handlers: GraftKeyHandlers
    let isBase: Bool
    @State private var id = UUID()
    @State private var box = HandlerBox()

    func body(content: Content) -> some View {
        box.handlers = handlers
        return content
            // The root already carries one, behind every screen.
            .background { if !isBase { KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false) } }
            .onAppear {
                if isBase {
                    KeyCommandRouter.shared.setBase(box.forwarding)
                } else {
                    KeyCommandRouter.shared.register(id, box.forwarding)
                }
            }
            .onDisappear {
                if isBase {
                    KeyCommandRouter.shared.setBase(nil)
                } else {
                    KeyCommandRouter.shared.unregister(id)
                }
            }
    }
}

private struct GraftKeyList: ViewModifier {
    let ids: [String]
    @Binding var selection: String?
    let display: (String?) -> ExternalDisplayContent
    let onOpen: (String) -> Void
    let key: (String, String?) -> Bool

    @State private var routerID = UUID()
    @State private var visible = false
    /// Where the selection was, so a row that disappears from under it (done,
    /// archived, filtered out) hands the selection to its neighbour rather than
    /// dropping it.
    @State private var lastIndex: Int?
    @State private var published: ExternalDisplayContent?
    @State private var box = HandlerBox()

    private var monitor: ExternalDisplayModel { ExternalDisplayModel.shared }

    func body(content: Content) -> some View {
        box.handlers = handlers
        return content
            .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
            .onAppear {
                visible = true
                KeyCommandRouter.shared.register(routerID, box.forwarding)
                adopt(); publish()
            }
            .onChange(of: monitor.isConnected) { _, connected in
                if !connected { selection = nil }
                adopt(); publish()
            }
            .onChange(of: selection) { _, new in
                if let new, let i = ids.firstIndex(of: new) { lastIndex = i }
                publish()
            }
            .onChange(of: ids) { _, _ in
                if let current = selection, !ids.contains(current) {
                    selection = lastIndex.flatMap { ids.isEmpty ? nil : ids[min($0, ids.count - 1)] }
                }
                adopt(); publish()
            }
            .onDisappear {
                visible = false
                KeyCommandRouter.shared.unregister(routerID)
                if let published { monitor.clear(ifShowing: published) }
            }
    }

    /// With a monitor attached the list starts ready for ↵, the way a desk
    /// screen should. Without one, nothing is selected until an arrow is pressed,
    /// so a phone used by touch never shows a stray ring.
    private func adopt() {
        guard visible, monitor.isConnected, selection == nil, let first = ids.first else { return }
        selection = first
    }

    private var handlers: GraftKeyHandlers {
        GraftKeyHandlers(
            move: { delta in move(delta) },
            open: {
                guard let id = selection, ids.contains(id) else { return false }
                onOpen(id)
                return true
            },
            escape: {
                // A ring nobody asked for is let go first; with a monitor up the
                // selection is the point, so esc goes straight to "back".
                guard selection != nil, !monitor.isConnected else { return false }
                selection = nil
                return true
            },
            key: { k in
                if k == "j" { return move(1) }
                if k == "k" { return move(-1) }
                return key(k, selection.flatMap { ids.contains($0) ? $0 : nil })
            }
        )
    }

    private func move(_ delta: Int) -> Bool {
        guard !ids.isEmpty else { return false }
        // The first press adopts the top (or bottom) rather than skipping a row.
        guard let current = selection, let i = ids.firstIndex(of: current) else {
            selection = delta > 0 ? ids.first : ids.last
            return true
        }
        selection = ids[min(max(i + delta, 0), ids.count - 1)]
        return true
    }

    private func publish() {
        guard visible else { return }
        let content = display(selection)
        published = content
        monitor.present(content)
    }
}

// MARK: - Issue keys

extension GraftStore {
    /// The keys that act on one issue, shared by every list and the issue screen
    /// so `]` means the same thing wherever it is pressed. Returns whether it
    /// took the key; `undo` receives the banner to offer, for an archive.
    ///
    ///   ] [   status forward / back, stopping at the ends
    ///   x     done, or back to todo if it already is
    ///   p     priority, low → normal → high → urgent → low
    ///   a     archive, or unarchive
    func handleIssueKey(_ k: String, issueId: String, undo: @escaping @MainActor (UndoAction) -> Void) -> Bool {
        guard let issue = issues.first(where: { $0.id == issueId }) else { return false }
        switch k {
        case "]", "[":
            setIssue(issue) { $0.status = IssueStatus.step(issue.status, by: k == "]" ? 1 : -1) }
        case "x":
            setIssue(issue) { $0.status = IssueStatus.toggledDone(issue.status) }
        case "p":
            setIssue(issue) { $0.priority = IssuePriority.next(after: issue.priority) }
        case "a":
            let wasArchived = issue.archived
            Task {
                try? await archiveIssue(id: issueId)
                undo(UndoAction(message: wasArchived ? "Issue unarchived" : "Issue archived") {
                    try? await self.archiveIssue(id: issueId)
                })
            }
        default:
            return false
        }
        return true
    }

    private func setIssue(_ issue: GraftIssue, _ change: (inout GraftIssue) -> Void) {
        var updated = issue
        change(&updated)
        Task { try? await updateIssue(updated) }
    }
}

extension IssueStatus {
    /// The status `delta` steps along backlog → todo → in progress → review →
    /// done, stopping at either end rather than wrapping: `]` on a done issue
    /// should not quietly put it back in the backlog.
    static func step(_ status: String, by delta: Int) -> String {
        let all = allCases
        let i = all.firstIndex { $0.rawValue == status } ?? 0
        return all[min(max(i + delta, 0), all.count - 1)].rawValue
    }

    /// Done, or back to todo if it already is — the issue screen's own button.
    static func toggledDone(_ status: String) -> String {
        status == IssueStatus.done.rawValue ? IssueStatus.todo.rawValue : IssueStatus.done.rawValue
    }
}

extension IssuePriority {
    /// low → normal → high → urgent → low.
    static func next(after priority: String) -> String {
        let cycle: [IssuePriority] = [.low, .normal, .high, .urgent]
        let i = cycle.firstIndex { $0.rawValue == priority } ?? 1
        return cycle[(i + 1) % cycle.count].rawValue
    }
}
