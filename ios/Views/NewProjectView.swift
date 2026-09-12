import SwiftUI

// Both project sheets, built from FormKit rather than a stock `Form`. They were
// the last two screens in the app that looked like Settings.app: grouped grey
// cards, an SF-labelled `ColorPicker` opening the system colour wheel, and a
// segmented control that cannot take the accent.
//
// The colour control is the substantive change, not just a restyle — it used to
// offer any colour at all, including ones illegible on one of the two themes.
// It now offers the ten that clear 3:1 on both (see `GraftPalette`).

private let projectStatuses = ["active", "paused", "done"]

private func projectStatusLabel(_ s: String) -> String {
    switch s {
    case "active": return "Active"
    case "paused": return "Paused"
    case "done":   return "Done"
    default:       return s
    }
}

// MARK: - New project

struct NewProjectView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var colourHex = GraftPalette.fallback
    @State private var status = "active"
    @State private var areaId = ""
    @State private var isSaving = false
    @FocusState private var focus: GraftFormField?

    private var hasDraft: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            || !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GraftFormScaffold(
            title: "New project",
            confirmLabel: "Create",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            isBusy: isSaving,
            onCancel: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            GraftSection(title: "Project details") {
                GraftTextField(label: "Name", placeholder: "What is it called?",
                               text: $name, focused: $focus, field: .name)
                GraftRowDivider()
                GraftTextField(label: "Description", placeholder: "Optional",
                               text: $description, axis: .vertical, lineLimit: 3...6,
                               focused: $focus, field: .description)
            }

            GraftSection(title: "Area") {
                AreaPicker(areaId: $areaId)
            }

            GraftSection(title: "Appearance") {
                GraftColourPicker(hex: $colourHex)
            }

            GraftSection(title: "Status") {
                GraftChoiceRow(label: "Status", options: projectStatuses, selection: $status,
                               title: projectStatusLabel)
            }
        }
        .disabled(isSaving)
        // A swipe-down used to throw the draft away silently.
        .interactiveDismissDisabled(hasDraft)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        try? await store.createProject(
            name: name,
            description: description,
            colour: colourHex,
            status: status,
            areaId: areaId
        )
        dismiss()
    }
}

// MARK: - Edit project

struct EditProjectView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: GraftProject

    @State private var name = ""
    @State private var description = ""
    @State private var colourHex = GraftPalette.fallback
    @State private var status = "active"
    @State private var icon = ""
    @State private var areaId = ""
    @State private var isSaving = false
    @State private var loaded = false
    @FocusState private var focus: GraftFormField?

    /// Anything changed from what the project currently says.
    private var hasDraft: Bool {
        name != project.name
            || description != project.description
            || status != project.status
            || icon != project.icon
            || areaId != project.areaKey
            || colourHex.caseInsensitiveCompare(project.colour) != .orderedSame
    }

    var body: some View {
        GraftFormScaffold(
            title: "Edit project",
            confirmLabel: "Save",
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            isBusy: isSaving,
            onCancel: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            GraftSection(title: "Project details") {
                GraftTextField(label: "Name", placeholder: "What is it called?",
                               text: $name, focused: $focus, field: .name)
                GraftRowDivider()
                GraftTextField(label: "Description", placeholder: "Optional",
                               text: $description, axis: .vertical, lineLimit: 3...6,
                               focused: $focus, field: .description)
            }

            GraftSection(title: "Area") {
                AreaPicker(areaId: $areaId)
            }

            GraftSection(title: "Icon", footnote: "One emoji, shown beside the project everywhere.") {
                HStack(spacing: GraftMetrics.spaceS) {
                    // The current icon, or the colour dot that stands in for it.
                    Group {
                        if icon.isEmpty {
                            Circle().fill(Color(hex: colourHex)).frame(width: 24, height: 24)
                        } else {
                            Text(icon).font(.system(size: 26))
                        }
                    }
                    .frame(width: 34, height: 34)

                    TextField("Emoji", text: $icon)
                        .font(GraftFont.text(GraftType.body))
                        .foregroundStyle(Color.gInk)
                        .tint(Color.gAccent)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .icon)
                        // Keep it to a single grapheme — the field used to accept
                        // a whole sentence and then draw it at 28pt.
                        .onChange(of: icon) { _, new in
                            if let first = new.first { icon = String(first) } else { icon = "" }
                        }
                        .padding(.horizontal, GraftMetrics.spaceS)
                        .frame(minHeight: GraftMetrics.control)
                        .background(Color.gSurface2)
                        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))

                    if !icon.isEmpty {
                        Button { icon = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.gInk3)
                                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear icon")
                    }
                }
                .frame(minHeight: GraftMetrics.tap)
            }

            GraftSection(title: "Appearance") {
                GraftColourPicker(hex: $colourHex)
            }

            GraftSection(title: "Status") {
                GraftChoiceRow(label: "Status", options: projectStatuses, selection: $status,
                               title: projectStatusLabel)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(hasDraft)
        .onAppear {
            // Guarded: a second `onAppear` would put the stored values back
            // over whatever has been typed since the first one.
            guard !loaded else { return }
            loaded = true
            name = project.name
            description = project.description
            status = project.status
            // Snap a colour from the old palette onto the nearest current one,
            // so saving an untouched project does not write a stale hex back.
            colourHex = GraftPalette.nearest(to: project.colour).hex
            icon = project.icon
            areaId = project.areaKey
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var updated = project
        updated.name = name
        updated.description = description
        updated.status = status
        updated.colour = colourHex
        updated.icon = icon
        updated.areaId = areaId
        try? await store.updateProject(updated)
        dismiss()
    }
}

// Color(hex:) and toHex() are defined in DesignSystem.swift
