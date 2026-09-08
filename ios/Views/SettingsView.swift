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

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.gBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // Server section
                        SettingsSection(title: "Server") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("The primary URL is tried first. If unreachable, the fallback is used.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.gMuted)
                                    .padding(.bottom, 8)

                                SettingsURLField(
                                    label: "Primary",
                                    icon: "server.rack",
                                    placeholder: "http://raspberrypi.local:8911",
                                    text: $serverURL
                                )

                                Divider().background(Color.gHairline)

                                SettingsURLField(
                                    label: "Fallback",
                                    icon: "arrow.triangle.2.circlepath",
                                    placeholder: "Optional fallback URL",
                                    text: $fallbackURL
                                )
                            }
                        }

                        // Sync section
                        SettingsSection(title: "Sync") {
                            VStack(alignment: .leading, spacing: 12) {
                                // Last synced row
                                HStack(spacing: 8) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.gMuted)
                                    Text("Last synced")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.gInk)
                                    Spacer()
                                    Text(lastSyncedString)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.gMuted)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.gSurface2)
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                // Sync now button
                                Button {
                                    Task {
                                        isSyncing = true
                                        applySettings()
                                        await store.sync()
                                        isSyncing = false
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        if isSyncing {
                                            ProgressView()
                                                .tint(.white)
                                                .scaleEffect(0.85)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 14, weight: .medium))
                                        }
                                        Text(isSyncing ? "Syncing…" : "Sync now")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(isSyncing ? Color.gAmber.opacity(0.6) : Color.gAmber)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .disabled(isSyncing)
                                .buttonStyle(.plain)
                            }
                        }

                        // About section
                        SettingsSection(title: "About Graft") {
                            VStack(spacing: 0) {
                                HStack(spacing: 12) {
                                    Image(systemName: "leaf.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Color.gSage)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Graft")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.gInk)
                                        Text("Tend your work. Watch it grow.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.gMuted)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("v\(appVersion)")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Color.gMuted)
                                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.gMuted.opacity(0.6))
                                    }
                                }
                                .padding(14)
                            }
                            .background(Color.gSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.gBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        applySettings()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.gAmber)
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

// MARK: - Settings Section Container

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.gMuted)
                .tracking(0.8)

            content
                .padding(14)
                .background(Color.gSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gHairline, lineWidth: 0.5))
        }
    }
}

// MARK: - Settings URL Field

struct SettingsURLField: View {
    let label: String
    let icon: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.gMuted)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.gInk)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color.gSage)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        }
        .padding(.vertical, 10)
    }
}
