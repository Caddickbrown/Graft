import SwiftUI

// The regular-width chrome: at `horizontalSizeClass == .regular` (iPad, an
// opened-out iPhone) the tab bar's three destinations move into a sidebar down
// the left, the way the web client's rail carries them. It folds to a narrow
// strip that keeps only the way back and "+". The phone keeps `GraftTabBar`.

/// The tab bar's destinations stacked down a 180 pt column, with the
/// favourite projects under them.
struct GraftSideBar: View {
    @Binding var selection: GraftTab
    /// Writes still waiting for the server, shown on Settings.
    var pendingCount: Int = 0
    /// Favourite projects, in the order they are listed.
    var favourites: [GraftProject] = []
    /// The tab you are already on, tapped again. See `GraftTabBar`.
    var onReselect: (GraftTab) -> Void = { _ in }
    var onOpenProject: (GraftProject) -> Void = { _ in }
    /// Folds the sidebar down to `GraftSideRail`.
    var onCollapse: () -> Void

    static let width: CGFloat = 180

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
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS) {
            HStack(spacing: 0) {
                GraftWordmark(size: 20)
                Spacer(minLength: 0)
                GraftSidebarToggle(label: "Hide sidebar", action: onCollapse)
            }
            .padding(.leading, GraftMetrics.spaceXS)
            .padding(.bottom, GraftMetrics.spaceS)

            ForEach(items, id: \.tab) { item in
                row(item)
            }

            if !favourites.isEmpty {
                Text("FAVOURITES")
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .kerning(GraftType.microTracking)
                    .foregroundStyle(Color.gInk2)
                    .padding(.leading, GraftMetrics.spaceXS)
                    .padding(.top, GraftMetrics.spaceL)
                    .padding(.bottom, GraftMetrics.spaceXXS)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(favourites) { project in
                            favouriteRow(project)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, GraftMetrics.spaceXS)
        .padding(.top, GraftMetrics.spaceXS)
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.gSidebar.ignoresSafeArea())
    }

    private func row(_ item: Item) -> some View {
        let selected = selection == item.tab
        return Button {
            if selected { onReselect(item.tab) } else { selection = item.tab }
        } label: {
            HStack(spacing: GraftMetrics.spaceS) {
                Image(systemName: selected ? "\(item.symbol).fill" : item.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 22)
                Text(item.label)
                    .font(GraftFont.text(GraftType.secondary, selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if item.tab == .settings && pendingCount > 0 {
                    Text(pendingCount > 9 ? "9+" : "\(pendingCount)")
                        .font(GraftFont.text(9, .semibold))
                        .foregroundStyle(Color.gOnAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gAmber, in: Capsule())
                }
            }
            .foregroundStyle(selected ? Color.gAccentText : Color.gInk2)
            .padding(.horizontal, GraftMetrics.spaceXS)
            .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap, alignment: .leading)
            .background(selected ? Color.gAccentWash : Color.clear,
                        in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.tab == .settings && pendingCount > 0 ? "\(pendingCount) waiting" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func favouriteRow(_ project: GraftProject) -> some View {
        Button {
            onOpenProject(project)
        } label: {
            HStack(spacing: GraftMetrics.spaceXS) {
                // The project's own strip, as on its card in Projects.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: project.colour))
                    .frame(width: 3, height: 18)
                if !project.icon.isEmpty {
                    Text(project.icon).font(GraftFont.emoji(13))
                }
                Text(project.name)
                    .font(GraftFont.text(GraftType.caption, .medium))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GraftMetrics.spaceXS)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(project.name)
        .accessibilityHint("Opens the project")
    }
}

/// The sidebar folded away: a 52 pt strip with the way back and "+".
struct GraftSideRail: View {
    var onNew: () -> Void
    var onExpand: () -> Void

    static let width: CGFloat = 52

    var body: some View {
        VStack(spacing: GraftMetrics.spaceXS) {
            GraftSidebarToggle(label: "Show sidebar", action: onExpand)
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.gOnAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.gAccent, in: Circle())
                    .frame(width: GraftMetrics.tap, height: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New issue")
            Spacer(minLength: 0)
        }
        .padding(.top, GraftMetrics.spaceXS)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.gSidebar.ignoresSafeArea())
    }
}

/// The system's sidebar glyph, so it reads as the toggle it is everywhere else
/// on iPad; ⌃⌘S, the standard Toggle Sidebar keys, works from a keyboard.
struct GraftSidebarToggle: View {
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.gInk2)
                .frame(width: GraftMetrics.tap, height: GraftMetrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .accessibilityLabel(label)
    }
}
