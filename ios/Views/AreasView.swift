import SwiftUI

// MARK: - Area picker
//
// A project belongs to at most one area, and `""` — "No area" — is a real,
// choosable answer rather than a missing one.

struct AreaPicker: View {
    @Environment(GraftStore.self) private var store
    @Binding var areaId: String

    var body: some View {
        // A menu rather than a `Picker`: inside a stock `Form` the picker drew
        // its own grey row, which is exactly the look the sheets moved off.
        // '' and nil both mean "no area" — the store stores the empty string,
        // the row speaks Optional.
        GraftMenuRow(
            label: "Area",
            options: store.sortedAreas,
            selection: Binding(
                get: { areaId.isEmpty ? nil : areaId },
                set: { areaId = $0 ?? "" }
            ),
            title: { $0.name },
            emptyTitle: "No area"
        )
    }
}

// MARK: - Managing areas

struct AreasView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var renaming: GraftArea?
    @State private var renameText = ""
    @State private var pendingDelete: GraftArea?

    private func projectCount(_ area: GraftArea) -> Int {
        store.projects.filter { $0.areaKey == area.id }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceXXL) {
                    Text("Areas")
                        .font(GraftFont.display(GraftType.display, .bold))
                        .foregroundStyle(Color.gInk)
                        .padding(.top, GraftMetrics.spaceXS)

                    GraftSection(title: "Areas",
                                 footnote: "Deleting an area never deletes its projects — they move back to \u{201C}No area\u{201D}.") {
                        if store.areas.isEmpty {
                            Text("No areas yet. An area is a shelf for projects — \u{201C}Work\u{201D}, \u{201C}Home\u{201D}, \u{201C}Someday\u{201D}.")
                                .font(GraftFont.text(GraftType.secondary))
                                .foregroundStyle(Color.gInk2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, GraftMetrics.spaceXS)
                        }
                        // Delete is an explicit button: `swipeActions` needs a
                        // `List`, and this screen is no longer one.
                        ForEach(Array(store.sortedAreas.enumerated()), id: \.element.id) { index, area in
                            if index > 0 { GraftRowDivider() }
                            HStack(spacing: GraftMetrics.spaceXS) {
                                Button {
                                    renaming = area
                                    renameText = area.name
                                } label: {
                                    HStack {
                                        Text(area.name)
                                            .font(GraftFont.text(GraftType.body))
                                            .foregroundStyle(Color.gInk)
                                        Spacer(minLength: 0)
                                        Text("\(projectCount(area))")
                                            .font(GraftFont.mono(GraftType.caption))
                                            .monospacedDigit()
                                            .foregroundStyle(Color.gInk3)
                                    }
                                    .frame(minHeight: GraftMetrics.tap)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button { pendingDelete = area } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.gInk3)
                                        .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(area.name)")
                            }
                        }
                    }

                    GraftSection(title: "Add an area") {
                        HStack(spacing: GraftMetrics.spaceS) {
                            TextField("Name", text: $newName)
                                .font(GraftFont.text(GraftType.title))
                                .foregroundStyle(Color.gInk)
                                .tint(Color.gAccent)
                                .padding(.vertical, GraftMetrics.spaceXS)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.gLine2)
                                        .frame(height: GraftMetrics.border)
                                }

                            Button("Add") {
                                let name = newName.trimmingCharacters(in: .whitespaces)
                                newName = ""
                                guard !name.isEmpty else { return }
                                Task { try? await store.createArea(name: name) }
                            }
                            .font(GraftFont.text(GraftType.secondary, .semibold))
                            .foregroundStyle(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                             ? Color.gInk3 : Color.gOnAccent)
                            .padding(.horizontal, GraftMetrics.spaceS)
                            .frame(height: GraftMetrics.controlSmall)
                            .background(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? Color.gSurface2 : Color.gAccent, in: Capsule())
                            .buttonStyle(.plain)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .frame(minHeight: GraftMetrics.tap)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.bottom, GraftMetrics.space3XL)
            }
            .background(Color.gBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            // A half-typed area name is worth as much as a half-typed issue.
            .interactiveDismissDisabled(!newName.trimmingCharacters(in: .whitespaces).isEmpty)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(GraftFont.text(GraftType.secondary, .semibold))
                        .foregroundStyle(Color.gAccentText)
                }
            }
            .alert("Rename area", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    guard let area = renaming else { return }
                    renaming = nil
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    // Built as a `let` rather than mutated in place: a local
                    // `var` captured by the `Task` below is a concurrency error.
                    let renamed = GraftArea(
                        id: area.id,
                        name: name,
                        colour: area.colour,
                        sortOrder: area.sortOrder
                    )
                    Task { try? await store.updateArea(renamed) }
                }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)?" } ?? "Delete area?",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let area = pendingDelete {
                    Button("Delete area", role: .destructive) {
                        Task { try? await store.deleteArea(id: area.id) }
                        pendingDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let area = pendingDelete {
                    let n = projectCount(area)
                    Text("\(n) project\(n == 1 ? "" : "s") will move to \u{201C}No area\u{201D}. Nothing is deleted.")
                }
            }
        }
    }
}
