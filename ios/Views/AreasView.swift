import SwiftUI

// MARK: - Area picker
//
// A project belongs to at most one area, and `""` — "No area" — is a real,
// choosable answer rather than a missing one.

struct AreaPicker: View {
    @Environment(GraftStore.self) private var store
    @Binding var areaId: String

    var body: some View {
        Picker("Area", selection: $areaId) {
            Text("No area").tag("")
            ForEach(store.sortedAreas) { area in
                Text(area.name).tag(area.id)
            }
        }
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
            Form {
                Section {
                    if store.areas.isEmpty {
                        Text("No areas yet. An area is a shelf for projects — \u{201C}Work\u{201D}, \u{201C}Home\u{201D}, \u{201C}Someday\u{201D}.")
                            .font(.system(size: GraftType.secondary))
                            .foregroundStyle(Color.gInk2)
                    }
                    ForEach(store.sortedAreas) { area in
                        Button {
                            renaming = area
                            renameText = area.name
                        } label: {
                            HStack {
                                Text(area.name)
                                    .foregroundStyle(Color.gInk)
                                Spacer()
                                Text("\(projectCount(area))")
                                    .font(.system(size: GraftType.caption))
                                    .foregroundStyle(Color.gInk2)
                            }
                            .frame(minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = area
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Areas")
                } footer: {
                    Text("Deleting an area never deletes its projects — they move back to \u{201C}No area\u{201D}.")
                }

                Section("Add an area") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Add") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            newName = ""
                            guard !name.isEmpty else { return }
                            Task { try? await store.createArea(name: name) }
                        }
                        .fontWeight(.semibold)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .frame(minHeight: GraftMetrics.tap)
                    }
                }
            }
            .navigationTitle("Areas")
            .navigationBarTitleDisplayMode(.inline)
            // A half-typed area name is worth as much as a half-typed issue.
            .interactiveDismissDisabled(!newName.trimmingCharacters(in: .whitespaces).isEmpty)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
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
