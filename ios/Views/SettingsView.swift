import SwiftUI

/// Settings.
///
/// Two things used to conspire to lose a server URL. "Done" called `dismiss()`
/// on a tab root, where it is a no-op, so it looked like a save button and was
/// not one. And `.onAppear` re-read the store on *every* appearance, so typing
/// a URL and switching tabs silently put the old value back. Settings are now
/// hydrated once and applied as they are edited, so there is nothing to lose.
struct SettingsView: View {
    @Environment(GraftStore.self) private var store

    @State private var serverURL = ""
    @State private var fallbackURL = ""
    @State private var isSyncing = false
    @State private var piEnabled = false
    /// Guards the one-time hydration described above.
    @State private var loaded = false
    /// Light / dark / system. The same key `GraftApp` reads.
    @AppStorage(GraftTheme.storageKey) private var themeRaw = GraftTheme.system.rawValue

    @FocusState private var urlFieldFocused: Bool

    var lastSyncedString: String {
        guard let date = store.lastSynced else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var pendingCount: Int { store.syncEngine.pendingCount }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GraftScreenHeader(title: "Settings")

                ScrollView {
                    VStack(alignment: .leading, spacing: GraftMetrics.spaceXL) {
                        pendingSection
                        appearanceSection
                        serverSection
                        if piEnabled {
                            certificateSection
                            syncSection
                        }
                        notificationsSection
                        aboutSection
                    }
                    .padding(.horizontal, GraftMetrics.spaceL)
                    .padding(.vertical, GraftMetrics.spaceL)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                // No "Done" here. This is a tab root, so `dismiss()` did
                // nothing — and the only thing it was doing besides was saving,
                // which now happens as you type. A keyboard Done is what people
                // actually wanted from it.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { urlFieldFocused = false }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Deliberately outside the `loaded` guard below: the user can
                // change the permission in Settings.app and come straight back,
                // and a stale answer here would have this screen claiming the
                // app can do something it cannot.
                Task { await store.notifications.refreshAuthorization() }

                guard !loaded else { return }
                loaded = true
                serverURL = store.serverURL
                fallbackURL = store.fallbackURL
                piEnabled = !store.serverURL.isEmpty
            }
            // Applied as edited rather than on a button. A half-typed URL is
            // harmless — it is only used when something tries to sync.
            .onChange(of: serverURL) { _, _ in applySettings() }
            .onChange(of: fallbackURL) { _, _ in applySettings() }
            .onChange(of: piEnabled) { _, _ in applySettings() }
        }
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingSection: some View {
        if pendingCount > 0 {
            SettingsSection(title: "Pending") {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.gAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pendingCount) change\(pendingCount == 1 ? "" : "s") waiting to sync")
                            .font(GraftFont.text(GraftType.secondary))
                            .foregroundStyle(Color.gInk)
                        Text(piEnabled ? "Will sync when the Pi is reachable" : "Link a Pi server below to sync")
                            .font(GraftFont.text(GraftType.caption))
                            .foregroundStyle(Color.gInk2)
                    }
                    Spacer()
                }
                .padding(GraftMetrics.spaceS + 2)
                .background(Color.gAmber.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                        .stroke(Color.gAmber.opacity(0.25), lineWidth: GraftMetrics.border)
                )
            }
        }
    }

    // MARK: - Server

    /// Light / dark / follow the phone.
    ///
    /// The web client has had this in the corner of its rail from the start and
    /// the phone simply obeyed iOS, so the two clients could not be made to
    /// match on the same desk. The picker writes one string to `UserDefaults`;
    /// `GraftApp` reads it and hands the window a colour scheme, and the whole
    /// palette follows from there.
    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            GraftChoiceRow(
                label: "Theme",
                options: GraftTheme.allCases,
                selection: Binding(
                    get: { GraftTheme(rawValue: themeRaw) ?? .system },
                    set: { themeRaw = $0.rawValue }
                ),
                title: { $0.label }
            )
        }
    }

    private var serverSection: some View {
        SettingsSection(title: "Pi Server") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gInk2)
                        .frame(width: 18)
                    Text("Link to Pi server")
                        .font(GraftFont.text(GraftType.secondary))
                        .foregroundStyle(Color.gInk)
                    Spacer()
                    Toggle("", isOn: $piEnabled)
                        .tint(Color.gAccent)
                        .labelsHidden()
                }
                .frame(minHeight: GraftMetrics.tap)

                if piEnabled {
                    Divider().background(Color.gHairline)

                    Text("Data is stored on this phone. The Pi syncs changes when reachable.")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    SettingsURLField(
                        label: "Primary",
                        icon: "server.rack",
                        // The server is HTTPS-only, and that is intended.
                        placeholder: "https://raspberrypi.local:8911",
                        text: $serverURL,
                        focused: $urlFieldFocused
                    )

                    Divider().background(Color.gHairline)

                    SettingsURLField(
                        label: "Fallback",
                        icon: "arrow.triangle.2.circlepath",
                        placeholder: "https://… (optional)",
                        text: $fallbackURL,
                        focused: $urlFieldFocused
                    )
                }
            }
        }
    }

    // MARK: - Certificate trust
    //
    // The Pi serves HTTPS with a certificate from an mkcert development CA.
    // iOS will refuse it until that root is both installed *and* switched on
    // under Certificate Trust Settings — two separate steps, and the second one
    // is the one everybody misses because installing a profile looks finished.
    // Nothing here weakens validation; the app does not bypass it.

    private var certificateSection: some View {
        SettingsSection(title: "Certificate") {
            VStack(alignment: .leading, spacing: GraftMetrics.spaceS) {
                Text("The Pi uses a certificate from your own mkcert development CA. For this phone to trust it:")
                    .font(GraftFont.text(GraftType.secondary))
                    .foregroundStyle(Color.gInk)
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "Open the mkcert root certificate (rootCA.pem) on this phone — AirDrop it, or open it from a link.")
                step(2, "Install it: Settings › General › VPN & Device Management › the downloaded profile › Install.")
                step(3, "Turn it on: Settings › General › About › Certificate Trust Settings, and enable full trust for the mkcert root.")

                Text("Step 3 is separate from step 2 and is easy to miss — installing the profile alone is not enough, and until it is done every sync fails as if the Pi were offline.")
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: GraftMetrics.spaceXS) {
            Text("\(number)")
                .font(GraftFont.text(GraftType.micro, .bold))
                .foregroundStyle(Color.gOnAccent)
                .frame(width: 18, height: 18)
                .background(Color.gAccent, in: Circle())
            Text(text)
                .font(GraftFont.text(GraftType.caption))
                .foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection(title: "Sync") {
            VStack(alignment: .leading, spacing: GraftMetrics.spaceS) {
                HStack(spacing: GraftMetrics.spaceXS) {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gInk2)
                    Text("Last synced")
                        .font(GraftFont.text(GraftType.secondary))
                        .foregroundStyle(Color.gInk)
                    Spacer()
                    Text(lastSyncedString)
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                }
                .padding(.horizontal, GraftMetrics.spaceS + 2)
                .frame(minHeight: GraftMetrics.tap)
                .background(Color.gSurface2)
                .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))

                Button {
                    Task {
                        isSyncing = true
                        applySettings()
                        await store.sync()
                        isSyncing = false
                    }
                } label: {
                    HStack(spacing: GraftMetrics.spaceXS) {
                        if isSyncing {
                            ProgressView().tint(Color.gOnAccent).scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: GraftType.secondary, weight: .medium))
                        }
                        Text(isSyncing ? "Syncing…" : "Sync now")
                            .font(GraftFont.text(GraftType.secondary, .semibold))
                    }
                    .foregroundStyle(Color.gOnAccent)
                    .frame(maxWidth: .infinity, minHeight: GraftMetrics.tap)
                    .background(isSyncing ? Color.gAccent.opacity(0.6) : Color.gAccent)
                    .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                }
                .disabled(isSyncing)
                .buttonStyle(.plain)

                if let err = store.errorMessage {
                    Text(err)
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = store.syncEngine.lastFlushError {
                    Text("⚠ \(err)")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Changes the queue gave up on. A refused or exhausted op is
                // gone for good, and an edit that silently never reached the
                // server is worse than one you were told about.
                if !store.syncEngine.droppedOps.isEmpty {
                    VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS + 2) {
                        Text("Changes that couldn't be saved")
                            .font(GraftFont.text(GraftType.caption, .semibold))
                            .foregroundStyle(Color.gInk)
                        ForEach(store.syncEngine.droppedOps) { op in
                            Text("\(op.method) \(op.path) — \(op.reason)")
                                .font(GraftFont.text(GraftType.caption))
                                .foregroundStyle(Color.gInk2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            store.syncEngine.clearDropped()
                        } label: {
                            Text("Dismiss")
                                .font(GraftFont.text(GraftType.secondary, .semibold))
                                .foregroundStyle(Color.gAccentText)
                                // Was a ~16pt target sitting inside a warning
                                // box, which is not a thing anyone can hit.
                                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(GraftMetrics.spaceS)
                    .background(Color.gRed.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
                }
            }
        }
    }

    // MARK: - Notifications
    //
    // Local notifications only. There is no APNs here and no push entitlement:
    // the Pi has no certificate and no token store, and everything worth saying
    // is known hours or days ahead. The server decides *what* is worth saying;
    // the phone schedules as many of them as iOS will hold.

    @ViewBuilder
    private var notificationsSection: some View {
        let scheduler = store.notifications
        SettingsSection(title: "Notifications") {
            GraftToggleRow(label: "Remind me about due work", isOn: Binding(
                get: { scheduler.isEnabled },
                set: { wanted in
                    scheduler.isEnabled = wanted
                    guard wanted else { return }
                    Task {
                        // iOS only shows the prompt once, ever. After a refusal
                        // this resolves to `.denied` and the note below sends
                        // the user to Settings.app instead of asking again.
                        await scheduler.requestAuthorization()
                        await store.rescheduleNotifications()
                    }
                }
            ))

            if scheduler.isEnabled {
                GraftRowDivider()
                notificationStatus(scheduler)
            }
        }
    }

    @ViewBuilder
    private func notificationStatus(_ scheduler: NotificationScheduler) -> some View {
        switch scheduler.authorization {
        case .denied:
            settingsNote(
                "Notifications are turned off for Graft in iOS Settings. Nothing can be scheduled until they are turned back on.",
                icon: "bell.slash", tint: Color.gAmber,
                action: ("Open Settings", { openSystemSettings() })
            )
        case .notAsked, .unknown:
            settingsNote("Waiting for permission.", icon: "bell", tint: Color.gInk2)
        case .grantedQuietly:
            settingsNote(
                "Allowed, but alerts are off — reminders will only appear in Notification Centre.",
                icon: "bell.badge", tint: Color.gAmber,
                action: ("Open Settings", { openSystemSettings() })
            )
        case .granted:
            VStack(alignment: .leading, spacing: GraftMetrics.spaceXXS) {
                Text(scheduler.scheduledCount == 0
                     ? "Nothing scheduled yet — reminders are built on the next sync."
                     : "\(scheduler.scheduledCount) reminder\(scheduler.scheduledCount == 1 ? "" : "s") scheduled.")
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                if scheduler.droppedCount > 0 {
                    // iOS holds 64 pending local notifications per app and drops
                    // the rest without telling anyone. Said out loud, because it
                    // is not a fact any user could deduce.
                    Text("\(scheduler.droppedCount) more didn't fit — iOS holds \(NotificationScheduler.pendingLimit) at a time, so the latest and most overdue win.")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !piEnabled {
                    Text("No server linked, so there is nothing to schedule from yet.")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, GraftMetrics.spaceXXS)
        }
    }

    private func settingsNote(
        _ text: String, icon: String, tint: Color,
        action: (title: String, run: () -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(alignment: .top, spacing: GraftMetrics.spaceXS) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text(text)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .font(GraftFont.text(GraftType.secondary, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .frame(minHeight: GraftMetrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GraftMetrics.spaceS)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection(title: "About Graft") {
            HStack(spacing: GraftMetrics.spaceS) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.gAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Graft")
                        .font(GraftFont.text(15, .semibold))
                        .foregroundStyle(Color.gInk)
                    Text("Tend your work. Watch it grow.")
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("v\(appVersion)")
                        .font(GraftFont.text(GraftType.caption, .medium))
                        .foregroundStyle(Color.gInk2)
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .font(GraftFont.text(GraftType.micro))
                        .foregroundStyle(Color.gInk3)
                }
            }
            .padding(GraftMetrics.spaceS + 2)
            .background(Color.gSurface2)
            .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
        }
    }

    /// Turning the toggle off clears the *stored* URLs without clearing the
    /// fields, so switching it back on does not mean typing the address again.
    private func applySettings() {
        let primary = serverURL.trimmingCharacters(in: .whitespaces)
        let secondary = fallbackURL.trimmingCharacters(in: .whitespaces)
        store.serverURL = piEnabled ? primary : ""
        store.fallbackURL = piEnabled ? secondary : ""
    }
}

// MARK: - Settings Section Container

/// Settings' own section, now just the shared one — it used to draw a card,
/// which is what the whole app has moved off.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GraftSection(title: title) { content }
    }
}

// MARK: - Settings URL Field

struct SettingsURLField: View {
    let label: String
    let icon: String
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.gInk2)
                .frame(width: 18)
            Text(label)
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gInk)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color.gAccentText)
                .font(GraftFont.text(GraftType.caption))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused(focused)
        }
        .frame(minHeight: GraftMetrics.tap)
    }
}
