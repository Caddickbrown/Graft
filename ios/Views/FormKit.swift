import SwiftUI

// MARK: - Form kit
//
// The pieces the *writing* surfaces are built from. Everything you read in this
// app was custom — project detail, issue detail, settings — and everything you
// typed into was a stock grouped `Form`: grey inset cards, SF labels, a system
// `ColorPicker`. So the app looked like itself until the moment you added
// something, and then looked like Settings.app.
//
// These match the reading surfaces: `Color.gSurface` cards on `Color.gBg`, one
// hairline, the 4/8/12/16 radius ladder, Geist throughout. Nothing here draws a
// control iOS already draws well — the keyboard, the date wheel and the emoji
// keyboard are all still the system's.

// MARK: Scaffold

/// A sheet with the app's own chrome: bar background, Cancel/confirm pair, and
/// a scrolling body on `gBg` rather than a grouped-table background.
struct GraftFormScaffold<Content: View>: View {
    let title: String
    let confirmLabel: String
    var confirmDisabled: Bool = false
    var isBusy: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceXXL) {
                    // The title lives in the content, big, in the display face —
                    // the way the web client heads a screen. A centred 17pt bar
                    // title is the single most iOS-looking thing a sheet can do.
                    Text(title)
                        .font(GraftFont.display(GraftType.display, .bold))
                        .foregroundStyle(Color.gInk)
                        .padding(.top, GraftMetrics.spaceXS)

                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.top, GraftMetrics.spaceS)
                // Room to scroll the last field clear of the keyboard.
                .padding(.bottom, GraftMetrics.space4XL)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.gBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .font(GraftFont.text(GraftType.secondary))
                        .foregroundStyle(Color.gInk2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onConfirm) {
                        if isBusy {
                            ProgressView().tint(Color.gOnAccent)
                        } else {
                            Text(confirmLabel)
                                .font(GraftFont.text(GraftType.secondary, .semibold))
                        }
                    }
                    // A filled pill, not bar-button blue text: this is the
                    // primary action and the design gives primary actions the
                    // accent as a *fill*.
                    .foregroundStyle(confirmDisabled ? Color.gInk3 : Color.gOnAccent)
                    .padding(.horizontal, GraftMetrics.spaceS)
                    .frame(height: GraftMetrics.controlSmall)
                    .background(confirmDisabled ? Color.gSurface2 : Color.gAccent, in: Capsule())
                    .disabled(confirmDisabled || isBusy)
                }
            }
        }
    }
}

// MARK: Section

/// A titled card. Same shape as `SettingsSection`, which it replaces — that one
/// was private to Settings, which is why every other sheet fell back to `Form`.
struct GraftSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceS) {
            // Label, then a hairline running to the edge — the web client's
            // section head. A white rounded card on a grey ground is exactly
            // what `Form` draws, so building one by hand bought nothing.
            GraftSectionHeader(title: title, inset: false)

            VStack(alignment: .leading, spacing: 0) { content }

            if let footnote {
                Text(footnote)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The divider between rows inside a `GraftSection`.
struct GraftRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.gHairline)
            .frame(height: GraftMetrics.border)
            .padding(.vertical, GraftMetrics.spaceM)
    }
}

// MARK: Text

/// A labelled single-line field. The label sits above the text rather than
/// beside it, so a long placeholder never squeezes the input to nothing.
struct GraftTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int> = 1...1
    var focused: FocusState<GraftFormField?>.Binding
    var field: GraftFormField

    private var isFocused: Bool { focused.wrappedValue == field }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS) {
            Text(label.uppercased())
                .font(GraftFont.text(GraftType.micro, .semibold))
                .foregroundStyle(isFocused ? Color.gAccentText : Color.gInk3)
                .tracking(GraftType.microTracking)

            Group {
                if axis == .vertical {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(lineLimit)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            // Type sits on the ground at reading size, with a rule under it —
            // no filled capsule, which is the iOS text-field tell.
            .font(GraftFont.text(GraftType.title))
            .foregroundStyle(Color.gInk)
            .tint(Color.gAccent)
            .focused(focused, equals: field)
            .padding(.vertical, GraftMetrics.spaceXS)

            Rectangle()
                .fill(isFocused ? Color.gAccent : Color.gLine2)
                .frame(height: isFocused ? 2 : GraftMetrics.border)
        }
        .animation(.snappy(duration: 0.15), value: isFocused)
    }
}

/// Which field owns the keyboard. One enum per app rather than a `Bool` each,
/// so a sheet can move focus between fields.
enum GraftFormField: Hashable {
    case name, description, icon, title, label, url, note
}

// MARK: Choice

/// A horizontal row of chips — the app's answer to `.pickerStyle(.segmented)`,
/// which cannot be coloured and always reads as iOS rather than as Graft.
struct GraftChoiceRow<T: Hashable>: View {
    let label: String
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    /// An optional meaning-colour shown as a dot before the label.
    ///
    /// The selected chip is always the accent — "the selected state" is one of
    /// the sanctioned uses of the one green, and tinting it with the option's
    /// own colour made grey-by-meaning options (Backlog, Normal priority) look
    /// disabled at the exact moment they were chosen. The dot keeps the meaning
    /// without spending it on the selection.
    var dot: (T) -> Color? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            if !label.isEmpty {
                Text(label.uppercased())
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .foregroundStyle(Color.gInk3)
                    .tracking(GraftType.microTracking)
            }

            // Wraps rather than scrolls: five status chips do not fit one line
            // on a small phone, and a row that scrolls hides its own options.
            FlowRow(spacing: GraftMetrics.spaceXS) {
                ForEach(options, id: \.self) { option in
                    let isOn = option == selection
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: GraftMetrics.spaceXXS + 2) {
                            if let colour = dot(option) {
                                Circle()
                                    .fill(isOn ? Color.gOnAccent.opacity(0.85) : colour)
                                    .frame(width: 6, height: 6)
                            }
                            Text(title(option))
                                .font(GraftFont.text(GraftType.secondary, isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Color.gOnAccent : Color.gInk2)
                        }
                            .padding(.horizontal, GraftMetrics.spaceS)
                            .frame(height: GraftMetrics.controlSmall)
                            .background(isOn ? Color.gAccent : Color.gSurface2, in: Capsule())
                            .overlay(
                                Capsule().stroke(isOn ? .clear : Color.gHairline,
                                                 lineWidth: GraftMetrics.border)
                            )
                            // Visual height stays 30; the hit target is 44.
                            .contentShape(Rectangle())
                            .frame(minHeight: GraftMetrics.tap)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .animation(.snappy(duration: 0.18), value: selection)
        }
    }
}

/// A menu-backed row for lists too long to be chips (areas, projects).
///
/// `Identifiable` alone: the models it lists are not all `Hashable`, and the
/// only thing this needs to compare is the id it already binds to.
struct GraftMenuRow<T: Identifiable>: View {
    let label: String
    let options: [T]
    @Binding var selection: T.ID?
    let title: (T) -> String
    var emptyTitle: String = "None"

    private var currentTitle: String {
        guard let selection, let match = options.first(where: { $0.id == selection })
        else { return emptyTitle }
        return title(match)
    }

    var body: some View {
        Menu {
            Button(emptyTitle) { selection = nil }
            ForEach(options) { option in
                Button(title(option)) { selection = option.id }
            }
        } label: {
            HStack(spacing: GraftMetrics.spaceXS) {
                Text(label)
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk)
                Spacer()
                Text(currentTitle)
                    .font(GraftFont.text(GraftType.secondary))
                    .foregroundStyle(Color.gInk2)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
            }
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
    }
}

// MARK: Colour

/// The project palette as a swatch grid, replacing the system `ColorPicker`.
/// A free colour wheel let a project be any colour at all, including ones that
/// vanish on one of the two themes; these ten are the ones that survive both.
struct GraftColourPicker: View {
    @Binding var hex: String

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: GraftMetrics.spaceXS)]

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack {
                Text("Colour")
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .foregroundStyle(Color.gInk3)
                    .tracking(GraftType.microTracking)
                Spacer()
                Text(GraftPalette.nearest(to: hex).name)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
            }

            LazyVGrid(columns: columns, spacing: GraftMetrics.spaceXS) {
                ForEach(GraftPalette.swatches) { swatch in
                    let isOn = swatch.hex.caseInsensitiveCompare(hex) == .orderedSame
                    Button { hex = swatch.hex } label: {
                        Circle()
                            .fill(swatch.colour)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().stroke(Color.gInk, lineWidth: isOn ? 2 : 0)
                                    .padding(-3)
                            )
                            .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .animation(.snappy(duration: 0.18), value: hex)
        }
    }
}

// MARK: Layout

/// Minimal flow layout — chips that wrap to the next line instead of being
/// clipped or forcing a horizontal scroller.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layout(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func layout(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
                rows[rows.count - 1].indices = [index]
                rows[rows.count - 1].width = size.width
                rows[rows.count - 1].height = size.height
            } else {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows
    }
}

// MARK: Multi-choice

/// Multi-select as wrapping chips rather than a list of checkmark rows.
///
/// The filter sheet had eleven sections of tappable rows, which on a phone meant
/// scrolling past forty-odd rows to reach "reset". As chips, every section is
/// one or two lines and the whole sheet is legible at a glance — which matters
/// more here than anywhere, because the thing being displayed *is* state.
struct GraftMultiChoiceRow: View {
    let label: String
    let options: [FilterOption]
    @Binding var selection: [String]
    /// Optional meaning-colour, drawn as a dot. See `GraftChoiceRow.dot`.
    var dot: (String) -> Color? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(spacing: GraftMetrics.spaceXS) {
                GraftSectionHeader(title: label,
                                   count: selection.isEmpty ? nil : selection.count,
                                   inset: false)
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .font(GraftFont.text(GraftType.micro, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .buttonStyle(.plain)
                }
            }

            FlowRow(spacing: GraftMetrics.spaceXS) {
                ForEach(options) { option in
                    let isOn = selection.contains(option.id)
                    Button {
                        if let idx = selection.firstIndex(of: option.id) {
                            selection.remove(at: idx)
                        } else {
                            selection.append(option.id)
                        }
                    } label: {
                        HStack(spacing: GraftMetrics.spaceXXS + 2) {
                            if let colour = dot(option.id) {
                                Circle()
                                    .fill(isOn ? Color.gOnAccent.opacity(0.85) : colour)
                                    .frame(width: 6, height: 6)
                            }
                            Text(option.label)
                                .font(GraftFont.text(GraftType.secondary, isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Color.gOnAccent : Color.gInk2)
                                .lineLimit(1)
                        }
                            .padding(.horizontal, GraftMetrics.spaceS)
                            .frame(height: GraftMetrics.controlSmall)
                            .background(isOn ? Color.gAccent : Color.gSurface2, in: Capsule())
                            .overlay(
                                Capsule().stroke(isOn ? .clear : Color.gHairline,
                                                 lineWidth: GraftMetrics.border)
                            )
                            .contentShape(Rectangle())
                            .frame(minHeight: GraftMetrics.tap)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? [.isSelected] : [])
                }
            }
            .animation(.snappy(duration: 0.18), value: selection)
        }
    }
}

// MARK: Toggle

/// A switch row on the app's own surface.
struct GraftToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(GraftFont.text(GraftType.body))
                .foregroundStyle(Color.gInk)
        }
        .tint(Color.gAccent)
        .frame(minHeight: GraftMetrics.tap)
    }
}
