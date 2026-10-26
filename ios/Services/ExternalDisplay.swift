import SwiftUI
import UIKit

// MARK: - External display
//
// Plug an iPhone or iPad into a monitor and iOS mirrors the app by default.
// Declaring a scene for `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
// (see the scene manifest in Info.plist, which names `ExternalDisplaySceneDelegate`
// below) opts out of mirroring and hands Graft a window of its own on the
// monitor. Two things follow:
//
// * the phone becomes independent of the monitor, so it can be dimmed — or
//   ignored — while a keyboard drives the app, and
// * the monitor can show something laid out for a desk rather than a phone
//   blown up: the list you are arrowing through beside the issue under the
//   selection, or the issue you have open.
//
// The monitor draws from the same `GraftStore` as the phone, by id. Content is
// a *description* of what to show (a list of issue ids, an issue id), never a
// copy of the rows, so a status changed with `]` repaints both screens in the
// same pass with nothing to keep in step. Modelled on Quire's desk mode.

/// What the second screen is showing.
enum ExternalDisplayContent: Equatable {
    /// Nothing selected anywhere — the monitor shows the day's numbers.
    case idle
    /// A list of issues being arrowed through: the Inbox, or a project.
    case issues(title: String, items: [ExternalListItem], selected: String?)
    /// The project list.
    case projects(items: [ExternalListItem], selected: String?)
    /// One issue, open.
    case issue(id: String)
}

/// One row of a mirrored list: an id, and the section header to draw above it
/// when it is the first row of a section.
struct ExternalListItem: Equatable, Identifiable {
    let id: String
    var section: String? = nil

    /// Flattens sections into rows, marking the first of each.
    static func sections(_ sections: [(title: String?, ids: [String])]) -> [ExternalListItem] {
        sections.flatMap { section in
            section.ids.enumerated().map { offset, id in
                ExternalListItem(id: id, section: offset == 0 ? section.title : nil)
            }
        }
    }
}

/// How big the monitor's type is. A desk monitor and a TV across the room want
/// different sizes, and the panel's resolution alone cannot tell which it is.
enum ExternalTextSize: String, CaseIterable, Identifiable {
    case small, regular, large
    static let key = "graft.external.textSize"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small:   return "Small"
        case .regular: return "Regular"
        case .large:   return "Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:   return 0.8
        case .regular: return 1
        case .large:   return 1.25
        }
    }
}

/// The monitor's appearance: the phone's, or pinned.
enum ExternalTheme: String, CaseIterable, Identifiable {
    case followApp, light, dark
    static let key = "graft.external.theme"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .followApp: return "Match app"
        case .light:     return "Light"
        case .dark:      return "Dark"
        }
    }
}

// MARK: - Model

/// Shared between the app's scene and the external one. A singleton because the
/// two scenes have separate view hierarchies: the monitor's window is built by a
/// UIKit scene delegate that cannot reach the app scene's environment.
@MainActor
@Observable
final class ExternalDisplayModel {
    static let shared = ExternalDisplayModel()

    static let dimKey = "graft.external.dimDevice"
    static let dimLevelKey = "graft.external.dimLevel"
    static let hintsKey = "graft.external.hints"
    /// Dimmest the slider goes. A fully dark panel reads as a dead phone.
    static let dimFloor: Double = 0.02

    private(set) var isConnected = false
    private(set) var isPaused = false
    /// What the monitor is drawing. Only tracks `latest` while one is attached,
    /// so nothing republishes to nobody.
    private(set) var content: ExternalDisplayContent = .idle
    /// Set once by `RootView`: the monitor reads issues and projects from it.
    var store: GraftStore?
    /// The app window's resolved scheme. An external scene gets a trait
    /// collection of its own that does not follow the device, so `RootView`
    /// pushes the scheme here and the monitor applies it.
    var appColorScheme: ColorScheme = .light

    /// Bumped whenever a preference the monitor draws from changes, so views
    /// reading `UserDefaults` directly still repaint.
    private(set) var preferencesVersion = 0

    private var latest: ExternalDisplayContent = .idle

    private init() {}

    // MARK: Publishing

    func present(_ new: ExternalDisplayContent) {
        latest = new
        guard isConnected, !isPaused else { return }
        content = new
    }

    /// Back to idle, but only if `shown` is still what is up. On a push, the
    /// outgoing screen's `onDisappear` can land *after* the incoming one has
    /// claimed the monitor; this keeps it from blanking what just arrived.
    func clear(ifShowing shown: ExternalDisplayContent) {
        guard latest == shown else { return }
        present(.idle)
    }

    // MARK: Keyboard controls

    func togglePause() {
        guard isConnected else { return }
        isPaused.toggle()
        content = isPaused ? .idle : latest
        updateIdleTimer()
    }

    func adjustTextSize(_ delta: Int) {
        let all = ExternalTextSize.allCases
        let index = all.firstIndex(of: textSize) ?? 1
        textSize = all[min(all.count - 1, max(0, index + delta))]
    }

    func cycleTheme() {
        let all = ExternalTheme.allCases
        let index = all.firstIndex(of: theme) ?? 0
        theme = all[(index + 1) % all.count]
    }

    func toggleHints() { showsHints.toggle() }

    // MARK: Preferences

    var textSize: ExternalTextSize {
        get {
            _ = preferencesVersion
            return ExternalTextSize(rawValue: UserDefaults.standard.string(forKey: ExternalTextSize.key) ?? "") ?? .regular
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ExternalTextSize.key); preferencesVersion += 1 }
    }

    var theme: ExternalTheme {
        get {
            _ = preferencesVersion
            return ExternalTheme(rawValue: UserDefaults.standard.string(forKey: ExternalTheme.key) ?? "") ?? .followApp
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ExternalTheme.key); preferencesVersion += 1 }
    }

    /// Registered nowhere, so absent means on.
    var showsHints: Bool {
        get {
            _ = preferencesVersion
            return UserDefaults.standard.object(forKey: Self.hintsKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.hintsKey); preferencesVersion += 1 }
    }

    var dimsDevice: Bool {
        get {
            _ = preferencesVersion
            return UserDefaults.standard.bool(forKey: Self.dimKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.dimKey)
            preferencesVersion += 1
            dimPreferenceChanged()
        }
    }

    var dimLevel: Double {
        get {
            _ = preferencesVersion
            return UserDefaults.standard.object(forKey: Self.dimLevelKey) as? Double ?? Self.dimFloor
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.dimLevelKey)
            preferencesVersion += 1
            dimPreferenceChanged()
        }
    }

    /// The scheme the monitor should draw in.
    var colorScheme: ColorScheme {
        switch theme {
        case .followApp: return appColorScheme
        case .light:     return .light
        case .dark:      return .dark
        }
    }

    // MARK: Connection

    func displayDidConnect() {
        isConnected = true
        content = isPaused ? .idle : latest
        updateIdleTimer()
        applyDim()
    }

    func displayDidDisconnect() {
        isConnected = false
        isPaused = false
        content = .idle
        updateIdleTimer()
        restoreBrightness()
    }

    /// Stay awake while a monitor is being driven — a phone face down beside a
    /// keyboard is never touched, and auto-lock would take the monitor with it.
    func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isConnected && !isPaused
            && UIApplication.shared.applicationState == .active
    }

    // MARK: Dimming the phone

    /// The user's brightness before we touched it, so unplugging puts it back
    /// exactly. Nil whenever we have not dimmed.
    private var brightnessToRestore: CGFloat?
    private var terminationObserver: NSObjectProtocol?

    /// The panel the app's own window sits on. `UIScreen.main` is deprecated;
    /// the application scene's screen is the supported route, and the only one
    /// whose brightness is writable.
    private var deviceScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
    }

    private func dimPreferenceChanged() {
        guard isConnected else { return }
        if dimsDevice { applyDim() } else { restoreBrightness() }
    }

    private func applyDim() {
        guard dimsDevice, let screen = deviceScreen else { return }
        // The baseline is captured once, so dragging the slider does not
        // overwrite it with our own dimmed value.
        if brightnessToRestore == nil { brightnessToRestore = screen.brightness }
        screen.brightness = CGFloat(min(0.5, max(Self.dimFloor, dimLevel)))
        observeTermination()
    }

    private func restoreBrightness() {
        guard let saved = brightnessToRestore else { return }
        deviceScreen?.brightness = saved
        brightnessToRestore = nil
    }

    /// Quitting must restore brightness too, or the phone is left dark with
    /// nothing on screen to explain why.
    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ExternalDisplayModel.shared.restoreBrightness() }
        }
    }
}

// MARK: - Scene plumbing

/// Delegate for the scene declared under
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` in Info.plist.
/// Declaring that scene is what stops iOS mirroring the app; this builds the
/// window that takes the mirror's place.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene
        else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ExternalDisplayRoot())
        // Shown but never made key — the phone's window keeps the keyboard.
        window.isHidden = false
        self.window = window
        ExternalDisplayModel.shared.displayDidConnect()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard scene.session.role == .windowExternalDisplayNonInteractive else { return }
        window = nil
        ExternalDisplayModel.shared.displayDidDisconnect()
    }
}

// MARK: - Publishing from a screen

extension View {
    /// Show `content` on the monitor for as long as this view is on screen.
    /// Nearly free with nothing plugged in: the model keeps the value and
    /// publishes it to nobody.
    func externalDisplay(_ content: ExternalDisplayContent) -> some View {
        modifier(ExternalDisplayPresenter(content: content))
    }
}

private struct ExternalDisplayPresenter: ViewModifier {
    let content: ExternalDisplayContent

    func body(content view: Content) -> some View {
        view
            .onAppear { ExternalDisplayModel.shared.present(content) }
            .onChange(of: content) { _, new in ExternalDisplayModel.shared.present(new) }
            .onDisappear { ExternalDisplayModel.shared.clear(ifShowing: content) }
    }
}
