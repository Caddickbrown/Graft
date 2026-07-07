import SwiftUI

struct SettingsView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var fallbackURL = ""
    @State private var isSyncing = false

    var lastSyncedString: String {
        guard let date = store.lastSynced else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Server"), footer: Text("The primary URL is tried first. If unreachable, the fallback URL is used.")) {
                    HStack {
                        Label("Primary", systemImage: "server.rack")
                        Spacer()
                        TextField("http://raspberrypi.local:8911", text: $serverURL)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }

                    HStack {
                        Label("Fallback", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        TextField("Optional fallback URL", text: $fallbackURL)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                }

                Section("Sync") {
                    LabeledContent("Last synced", value: lastSyncedString)

                    Button {
                        Task {
                            isSyncing = true
                            await store.sync()
                            isSyncing = false
                        }
                    } label: {
                        HStack {
                            if isSyncing {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isSyncing ? "Syncing…" : "Sync now")
                        }
                    }
                    .disabled(isSyncing)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        applySettings()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                serverURL = store.serverURL
                fallbackURL = store.fallbackURL
            }
        }
    }

    private func applySettings() {
        store.serverURL = serverURL.isEmpty ? "http://raspberrypi.local:8911" : serverURL
        store.fallbackURL = fallbackURL
    }
}
