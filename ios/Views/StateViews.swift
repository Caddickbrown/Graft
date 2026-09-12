import SwiftUI

// MARK: - Loading
//
// Every list surface used to show a bare, untitled `ProgressView` — a spinner
// in the middle of a black screen that says nothing about what is coming. A
// skeleton says "rows, shortly", keeps the layout from jumping when they land,
// and reads as fast rather than as stuck.

/// One placeholder issue/project row, at the real row's height.
struct GraftSkeletonRow: View {
    var showsSecondLine: Bool = true
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Color.gSurface2)
                .frame(width: GraftMetrics.ring, height: GraftMetrics.ring)

            VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
                RoundedRectangle(cornerRadius: GraftMetrics.radiusTight)
                    .fill(Color.gSurface2)
                    .frame(height: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsSecondLine {
                    RoundedRectangle(cornerRadius: GraftMetrics.radiusTight)
                        .fill(Color.gSurface2)
                        .frame(width: 120, height: 10)
                }
            }
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        .padding(.vertical, GraftMetrics.spaceS)
        .frame(minHeight: 64)
        .background(Color.gSurface)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
        .opacity(pulse ? 0.45 : 0.85)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        // One announcement for the whole placeholder list rather than one per
        // fake row, which VoiceOver would otherwise read out five times.
        .accessibilityHidden(true)
    }
}

/// A screenful of placeholder rows.
struct GraftSkeletonList: View {
    var count: Int = 5

    var body: some View {
        VStack(spacing: GraftMetrics.spaceXS) {
            ForEach(0..<count, id: \.self) { _ in
                GraftSkeletonRow()
            }
        }
        .padding(.horizontal, GraftMetrics.gutter)
        .padding(.top, GraftMetrics.spaceXS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Nothing matched
//
// Distinct from "nothing here". A milestone filter matching nothing used to say
// "Tap + to plant your first issue" about a project holding 41 issues, and a
// search matching nothing on the Projects tab rendered a blank list with no
// message at all.

struct GraftNoResults: View {
    /// What the user typed, if anything — the copy quotes it back so it is
    /// obvious *why* the list is empty.
    let searchText: String
    /// How many filters are on, so filter-emptiness reads differently from
    /// search-emptiness.
    var activeFilters: Int = 0
    var clearTitle: String = "Clear filters"
    var onClear: (() -> Void)? = nil

    private var searching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        GraftEmptyState(
            title: searching ? "No matches for \u{201C}\(searchText)\u{201D}" : "Nothing matches these filters",
            subtitle: subtitle,
            systemImage: searching ? "magnifyingglass" : "line.3.horizontal.decrease.circle",
            actionTitle: onClear == nil ? nil : (searching && activeFilters == 0 ? "Clear search" : clearTitle),
            action: onClear
        )
    }

    private var subtitle: String {
        if searching && activeFilters > 0 {
            return "Nothing here matches that search with \(activeFilters) filter\(activeFilters == 1 ? "" : "s") applied. There may be more without them."
        }
        if searching {
            return "Nothing here matches that. Try a shorter search, or a different spelling."
        }
        return "There is work here — just none of it matching the filters you have on."
    }
}

// MARK: - Error

struct GraftErrorState: View {
    let message: String
    /// Synchronous on purpose: the caller wraps its own `Task`, which keeps the
    /// async work in the view's actor context rather than smuggling a
    /// non-`Sendable` async closure through this struct.
    var retry: (() -> Void)? = nil

    var body: some View {
        GraftEmptyState(
            title: "Couldn't load",
            subtitle: message,
            systemImage: "exclamationmark.triangle",
            actionTitle: retry == nil ? nil : "Try again",
            action: retry
        )
    }
}

// MARK: - First run
//
// A new install used to see "No projects yet / Time to get grafting" — a
// healthy-looking empty state with no hint that the app can be pointed at a
// server, or that Settings is where you do it.

struct GraftNoServerState: View {
    @Environment(GraftRouter.self) private var router

    var body: some View {
        GraftEmptyState(
            title: "No server linked",
            subtitle: "Graft is working on its own on this phone. Link it to your Pi in Settings to sync with the web client — or carry on locally and link it later.",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            actionTitle: "Open Settings",
            action: { router.tab = .settings }
        )
    }
}

// MARK: - Sync strip
//
// `errorMessage` was read on one screen out of five, so an unreachable server
// looked exactly like a reachable one everywhere else. This is the one place
// the connection state is spelled, and it goes on top of every list surface.

struct SyncStrip: View {
    @Environment(GraftStore.self) private var store
    @Environment(GraftRouter.self) private var router

    var body: some View {
        switch store.connection {
        case .ok:
            // Nothing to say. Silence is the healthy state.
            EmptyView()

        case .noServer:
            strip(
                icon: "antenna.radiowaves.left.and.right.slash",
                tint: Color.gInk2,
                title: "Local only",
                detail: "Not linked to a server",
                actionTitle: "Link"
            ) { router.tab = .settings }

        case .syncing:
            strip(
                icon: "arrow.triangle.2.circlepath",
                tint: Color.gInk2,
                title: "Syncing…",
                detail: nil,
                actionTitle: nil,
                action: nil
            )

        case .pending(let count):
            strip(
                icon: "arrow.up.circle",
                tint: Color.gAmber,
                title: "\(count) change\(count == 1 ? "" : "s") waiting to sync",
                detail: "Saved on this phone",
                actionTitle: "Retry"
            ) { Task { await store.flushPending() } }

        case .unreachable(let message):
            strip(
                icon: "exclamationmark.triangle",
                tint: Color.gRed,
                title: "Can't reach the server",
                detail: message,
                actionTitle: "Retry"
            ) { Task { await store.sync() } }

        case .failed(let reason):
            strip(
                icon: "xmark.octagon",
                tint: Color.gRed,
                title: "A change couldn't be saved",
                detail: reason,
                actionTitle: "Details"
            ) { router.tab = .settings }
        }
    }

    @ViewBuilder
    private func strip(
        icon: String,
        tint: Color,
        title: String,
        detail: String?,
        actionTitle: String?,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(GraftFont.text(GraftType.caption, .medium))
                    .foregroundStyle(Color.gInk)
                if let detail {
                    Text(detail)
                        .font(GraftFont.text(GraftType.micro))
                        .foregroundStyle(Color.gInk2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: GraftMetrics.spaceXS)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(GraftFont.text(GraftType.caption, .semibold))
                    .foregroundStyle(Color.gAccentText)
                    // The rule: 44pt on the smallest axis, whatever the strip
                    // looks like.
                    .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, GraftMetrics.spaceS)
        .padding(.trailing, actionTitle == nil ? GraftMetrics.spaceS : GraftMetrics.spaceXXS)
        .padding(.vertical, actionTitle == nil ? GraftMetrics.spaceXS : 0)
        .frame(minHeight: GraftMetrics.tap)
        .background(Color.gSurface2)
        .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
        .padding(.horizontal, GraftMetrics.gutter)
    }
}

// MARK: - The subtitle under a large title
//
// `navigationSubtitle` needs a newer OS than this app deploys to, and the
// Inbox's summary in `.principal` fought the large title and truncated to
// nothing. This is the same information, given its own line at the top of the
// content where it has the full width.

struct GraftScreenSubtitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GraftFont.text(GraftType.secondary))
            .foregroundStyle(Color.gInk2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GraftMetrics.gutter)
            .padding(.bottom, GraftMetrics.spaceS)
    }
}

// MARK: - Section header
//
// One treatment for every "GROUP · count" header, so the Inbox, the grouped
// list and the project list stop inventing their own.

struct GraftSectionHeader: View {
    let title: String
    var count: Int? = nil
    var trailing: AnyView? = nil
    /// Screens carry the gutter themselves; a form has already applied it.
    var inset: Bool = true

    var body: some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Text(title.uppercased())
                .font(GraftFont.text(GraftType.micro, .semibold))
                .kerning(GraftType.microTracking)
                .foregroundStyle(Color.gInk2)
                .fixedSize()
            if let count {
                Text("\(count)")
                    .font(GraftFont.mono(GraftType.micro))
                    .monospacedDigit()
                    .foregroundStyle(Color.gInk3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.gSurface2, in: Capsule())
                    .fixedSize()
            }
            // The rule to the right edge. This is the web client's section head
            // and it is most of what stops a list of groups reading as a plain
            // iOS table with grey captions.
            Rectangle()
                .fill(Color.gHairline)
                .frame(height: GraftMetrics.border)
            if let trailing { trailing.fixedSize() }
        }
        .padding(.horizontal, inset ? GraftMetrics.gutter : 0)
        .padding(.top, GraftMetrics.spaceXXS)
        .padding(.bottom, GraftMetrics.spaceXS)
    }
}

// MARK: - Per-section empty copy
//
// The Inbox's sections could all be empty at once while issues plainly existed,
// leaving a segmented control, a floating + and nothing else. Every section now
// says what it means to be empty.

struct GraftSectionEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GraftFont.text(GraftType.secondary))
            .foregroundStyle(Color.gInk3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, GraftMetrics.spaceS)
            .padding(.vertical, GraftMetrics.spaceS)
            .background(Color.gSurface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
            .overlay(
                RoundedRectangle(cornerRadius: GraftMetrics.radius)
                    .strokeBorder(
                        Color.gHairline,
                        style: StrokeStyle(lineWidth: GraftMetrics.border, dash: [4, 3])
                    )
            )
            .padding(.horizontal, GraftMetrics.gutter)
            .padding(.bottom, GraftMetrics.spaceXS)
    }
}

// MARK: - Floating add button
//
// Three screens had drawn their own, and one of them had drifted to a different
// bottom padding.

struct GraftFAB: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.gOnAccent)
                .frame(width: 56, height: 56)
                .background(Color.gAccent, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .accessibilityLabel(label)
        .padding(.trailing, GraftMetrics.spaceL)
        .padding(.bottom, GraftMetrics.spaceL)
    }
}
