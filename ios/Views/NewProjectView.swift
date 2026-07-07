import SwiftUI

struct NewProjectView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var selectedColour = Color.indigo
    @State private var status = "active"
    @State private var isSaving = false

    let statuses = ["active", "paused", "done"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Project details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Appearance") {
                    ColorPicker("Colour", selection: $selectedColour, supportsOpacity: false)
                }

                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(statuses, id: \.self) { s in
                            Text(statusLabel(s)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let hex = selectedColour.toHex() ?? "#6366f1"
        try? await store.createProject(name: name, description: description, colour: hex, status: status)
        dismiss()
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "Active"
        case "paused": return "Paused"
        case "done": return "Done"
        default: return s
        }
    }
}

// MARK: - Edit Project View

struct EditProjectView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: GraftProject

    @State private var name = ""
    @State private var description = ""
    @State private var selectedColour = Color.indigo
    @State private var status = "active"
    @State private var isSaving = false

    let statuses = ["active", "paused", "done"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Project details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Appearance") {
                    ColorPicker("Colour", selection: $selectedColour, supportsOpacity: false)
                }

                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(statuses, id: \.self) { s in
                            Text(statusLabel(s)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = project.name
                description = project.description
                status = project.status
                selectedColour = Color(hex: project.colour) ?? .indigo
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var updated = project
        updated.name = name
        updated.description = description
        updated.status = status
        updated.colour = selectedColour.toHex() ?? project.colour
        try? await store.updateProject(updated)
        dismiss()
    }

    private func statusLabel(_ s: String) -> String {
        switch s {
        case "active": return "Active"
        case "paused": return "Paused"
        case "done": return "Done"
        default: return s
        }
    }
}

// MARK: - Color to Hex

extension Color {
    func toHex() -> String? {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
