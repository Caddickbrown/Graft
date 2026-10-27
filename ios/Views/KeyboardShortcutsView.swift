import SwiftUI

/// Every key, on one sheet — `?` from anywhere. The same table as the comment at
/// the top of `KeyboardCommands.swift`; change both together. The monitor draws
/// it too (`ExternalShortcuts`), so the sheet is readable with the phone down.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct ShortcutGroup {
        let title: String
        let shortcuts: [Shortcut]
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Anywhere", shortcuts: [
            .init(keys: "1  2  3", action: "Inbox, Projects, Settings (also ⌘1–3)"),
            .init(keys: "esc", action: "Clear the selection, then go back"),
            .init(keys: "r", action: "Refresh"),
            .init(keys: "u  ⌘Z", action: "Undo an archive"),
            .init(keys: "?", action: "This sheet"),
        ]),
        ShortcutGroup(title: "Lists", shortcuts: [
            .init(keys: "↑ ↓  or  j k", action: "Move"),
            .init(keys: "↵", action: "Open"),
            .init(keys: "n", action: "New issue (new project on Projects)"),
            .init(keys: "/", action: "Search — esc or ↓ to come back"),
            .init(keys: "f", action: "Favourite the project"),
        ]),
        ShortcutGroup(title: "Issues — in a list or open", shortcuts: [
            .init(keys: "]  [", action: "Status forward / back"),
            .init(keys: "x", action: "Done, or reopen"),
            .init(keys: "p", action: "Priority: low → normal → high → urgent"),
            .init(keys: "a", action: "Archive, or unarchive"),
            .init(keys: "t  e", action: "Edit title / description (open issue)"),
            .init(keys: "o", action: "Open the next one, after finishing a repeating issue"),
        ]),
        ShortcutGroup(title: "Sheets", shortcuts: [
            .init(keys: "⌘↵", action: "Save"),
            .init(keys: "esc", action: "Cancel"),
            .init(keys: "tab", action: "Next field"),
            .init(keys: "↵", action: "Add, from the title or name"),
            .init(keys: "⌘[  ⌘]", action: "Status back / forward"),
            .init(keys: "⌘P  ⌘D", action: "Priority, due date (new issue)"),
            .init(keys: "⌘O", action: "Project (new issue), area (new project)"),
            .init(keys: "⌘K", action: "Colour (new project)"),
        ]),
        ShortcutGroup(title: "Monitor", shortcuts: [
            .init(keys: "⌥⌘ =  ⌥⌘ −", action: "Text larger / smaller"),
            .init(keys: "⌥⌘ T", action: "Theme"),
            .init(keys: "⌥⌘ P", action: "Pause — the monitor goes blank"),
            .init(keys: "⌥⌘ H", action: "Hide or show the key hints"),
        ]),
    ]

    var body: some View {
        GraftSheetScaffold(title: "Keyboard", onDone: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceXL) {
                    ForEach(Self.groups, id: \.title) { group in
                        GraftSection(title: group.title) {
                            ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                if index > 0 { GraftRowDivider() }
                                HStack(spacing: GraftMetrics.spaceS) {
                                    Text(shortcut.keys)
                                        .font(GraftFont.mono(GraftType.secondary, .medium))
                                        .foregroundStyle(Color.gInk)
                                        .frame(width: 120, alignment: .leading)
                                    Text(shortcut.action)
                                        .font(GraftFont.text(GraftType.secondary))
                                        .foregroundStyle(Color.gInk2)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: GraftMetrics.tap)
                            }
                        }
                    }
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.space4XL)
            }
        }
        .presentationDetents([.large])
        .onAppear { ExternalDisplayModel.shared.presentSheet(.shortcuts) }
        .onDisappear { ExternalDisplayModel.shared.dismissSheet() }
    }
}
