import SwiftUI

// The app's own chrome: a sheet header, a screen header and a tab bar, all
// drawn by us rather than by UIKit.
//
// Why: from iOS 26 the system puts every toolbar item and the whole tab bar
// inside its own floating translucent capsule. A design that already gives its
// primary action an accent *fill* then renders as a filled pill inside a glass
// pill — two nested capsules, one of which we did not ask for and cannot
// restyle — and the confirm/cancel pair on every sheet was the worst of it.
// UIKit's appearance proxies (see `GraftChrome`) can reach the bar's colours
// and fonts but not that shape.
//
// So the bars are ours. These are plain SwiftUI views in the normal view tree,
// styled from the same tokens as everything else, which also means they match
// the web client instead of tracking whatever iOS does next.

// MARK: - Sheet header

/// `Cancel` on the left, the primary action as a filled pill on the right.
///
/// The title is deliberately *not* here: it belongs in the scrolling content,
/// big, in the display face, the way the web client heads a page — so it
/// scrolls away rather than shrinking into a centred 17pt bar title.
struct GraftSheetHeader: View {
    let confirmLabel: String
    var confirmDisabled: Bool = false
    var isBusy: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: GraftMetrics.spaceS) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk2)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onConfirm) {
                ZStack {
                    // Both states are always laid out, one of them hidden, so
                    // the pill keeps its width when the spinner replaces the
                    // label. Swapping the content outright made the button jump
                    // a few points wide at the exact moment it was tapped.
                    Text(confirmLabel)
                        .font(GraftFont.text(GraftType.body, .semibold))
                        .opacity(isBusy ? 0 : 1)
                    ProgressView()
                        .tint(Color.gOnAccent)
                        .opacity(isBusy ? 1 : 0)
                }
                .foregroundStyle(confirmDisabled ? Color.gInk3 : Color.gOnAccent)
                .padding(.horizontal, GraftMetrics.spaceM)
                .frame(minHeight: GraftMetrics.controlPrimary)
                .background(confirmDisabled ? Color.gSurface2 : Color.gAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(confirmDisabled || isBusy)
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.bottom, GraftMetrics.spaceXS)
        .background(Color.gBg)
    }
}

// MARK: - Screen header

/// The top of a full screen: a title in the display face with actions beside
/// it, and an optional line of metadata underneath.
///
/// Replaces `.navigationTitle` + `ToolbarItem` on the screens that had them.
/// `leading` is for the one control that belongs before the title (the project
/// scope menu); everything else goes in `actions`, right-aligned.
struct GraftScreenHeader<Leading: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Drawn instead of the plain text title — for the wordmark on Projects.
    var titleView: AnyView? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS) {
            HStack(alignment: .center, spacing: GraftMetrics.spaceXS) {
                leading
                if let titleView {
                    titleView
                } else {
                    Text(title)
                        .font(GraftFont.display(GraftType.display, .bold))
                        .foregroundStyle(Color.gInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: GraftMetrics.spaceXS)
                actions
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.top, GraftMetrics.spaceXS)
        .padding(.bottom, GraftMetrics.spaceS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gBg)
    }
}

extension GraftScreenHeader where Leading == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         titleView: AnyView? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, titleView: titleView,
                  leading: { EmptyView() }, actions: actions)
    }
}

extension GraftScreenHeader where Leading == EmptyView, Actions == EmptyView {
    init(title: String, subtitle: String? = nil, titleView: AnyView? = nil) {
        self.init(title: title, subtitle: subtitle, titleView: titleView,
                  leading: { EmptyView() }, actions: { EmptyView() })
    }
}

/// A square, bordered icon button — the app's answer to a bar button item.
/// Same shape as the web client's `.icon-btn`.
struct GraftIconButton: View {
    let systemImage: String
    var tint: Color = .gInk2
    var accessibilityTitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: GraftMetrics.control, height: GraftMetrics.control)
                .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                // The visual control is 34pt; the target is the full 44.
                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
    }
}

/// The back control for a pushed screen, since the custom header replaces the
/// navigation bar that used to draw one.
struct GraftBackButton: View {
    var label: String = "Back"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: GraftMetrics.spaceXXS) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(GraftFont.text(GraftType.secondary, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.gInk2)
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(label)")
    }
}

// MARK: - Tab bar

/// The app's own tab bar.
///
/// The system one is hidden per-tab with `.toolbar(.hidden, for: .tabBar)` and
/// this is inset into the safe area in its place, so scroll views still stop
/// clear of it and each tab keeps its own navigation state — which switching on
/// a plain `if` would have thrown away.
struct GraftTabBar: View {
    @Binding var selection: GraftTab
    /// Writes still waiting for the server, shown on Settings.
    var pendingCount: Int = 0
    /// Called when the tab you are already on is tapped again — the platform's
    /// "take me back to the top of this section" gesture. See `RootView`.
    var onReselect: (GraftTab) -> Void = { _ in }

    private struct Item {
        let tab: GraftTab
        let label: String
        let symbol: String
    }

    private let items: [Item] = [
        Item(tab: .inbox,    label: "Inbox",    symbol: "tray"),
        Item(tab: .projects, label: "Projects", symbol: "square.grid.2x2"),
        Item(tab: .settings, label: "Settings", symbol: "gearshape"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                let selected = selection == item.tab
                Button {
                    // A second tap on the tab you are on is not a no-op, which
                    // is what it used to be: it unwinds that tab back to its
                    // root screen. Tapping Projects from inside a project is
                    // how you get back to the project list.
                    if selected {
                        onReselect(item.tab)
                    } else {
                        selection = item.tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: selected ? "\(item.symbol).fill" : item.symbol)
                                .font(.system(size: 19, weight: .regular))
                                .symbolVariant(.none)
                            if item.tab == .settings && pendingCount > 0 {
                                Text(pendingCount > 9 ? "9+" : "\(pendingCount)")
                                    .font(GraftFont.text(9, .semibold))
                                    .foregroundStyle(Color.gOnAccent)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.gAmber, in: Capsule())
                                    .offset(x: 11, y: -5)
                            }
                        }
                        .frame(height: 22)
                        Text(item.label)
                            .font(GraftFont.text(GraftType.micro, .medium))
                    }
                    .foregroundStyle(selected ? Color.gAccentText : Color.gInk3)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.top, GraftMetrics.spaceXXS)
        .background(alignment: .top) {
            // The rail's ground with the app's own hairline on top of it —
            // the same pair the web client's sidebar uses.
            ZStack(alignment: .top) {
                Color.gSidebar
                Rectangle()
                    .fill(Color.gHairline)
                    .frame(height: GraftMetrics.border)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Search field

/// The app's search box.
///
/// `.searchable` is a navigation-bar feature: hiding the bar to get rid of the
/// glass capsules takes the search field with it. This is the replacement, and
/// it also lets the field sit where the web client puts it — in the page body,
/// under the title, rather than above it.
struct GraftSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// Called when the keyboard's Search key is pressed — the point at which
    /// the screens that can ask the server do so.
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.gInk3)

            TextField(placeholder, text: $text)
                .font(GraftFont.text(GraftType.body))
                .foregroundStyle(Color.gInk)
                .tint(Color.gAccent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($focused)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gInk3)
                        .frame(width: GraftMetrics.tap, height: GraftMetrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, GraftMetrics.spaceS)
        .padding(.trailing, text.isEmpty ? GraftMetrics.spaceS : 0)
        .frame(minHeight: GraftMetrics.tap)
        .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                .stroke(focused ? Color.gAccent : Color.gHairline, lineWidth: GraftMetrics.border)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Sheet scaffold for the non-form sheets

/// A sheet that is a *list* rather than a form: Milestones, Areas, Links,
/// Filter & sort. Same header shape as `GraftFormScaffold`, but the trailing
/// control is a plain "Done" rather than a confirm pill, because these screens
/// save as you go and there is nothing to submit.
struct GraftSheetScaffold<Content: View>: View {
    let title: String
    var doneLabel: String = "Done"
    /// An optional extra control beside the title — "New milestone", say.
    var trailingAccessory: AnyView? = nil
    let onDone: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: GraftMetrics.spaceS) {
                Text(title)
                    .font(GraftFont.display(GraftType.display, .bold))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: GraftMetrics.spaceXS)
                if let trailingAccessory { trailingAccessory }
                Button(action: onDone) {
                    Text(doneLabel)
                        .font(GraftFont.text(GraftType.body, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .frame(minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, GraftMetrics.gutter)
            .padding(.top, GraftMetrics.spaceS)
            .padding(.bottom, GraftMetrics.spaceXS)

            content
        }
        .background(Color.gBg)
    }
}
