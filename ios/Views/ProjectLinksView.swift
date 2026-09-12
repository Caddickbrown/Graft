import SwiftUI

// MARK: - Link kinds
//
// `kind` is only ever a glyph hint, so an unknown value is not an error — it
// falls back to the generic link. It is detected from the hostname when a link
// is created, and can be overridden by hand.

enum GraftLinkKind: String, CaseIterable, Identifiable {
    case github
    case docs
    case design
    case deploy
    case link

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: return "Code"
        case .docs: return "Docs"
        case .design: return "Design"
        case .deploy: return "Deploy"
        case .link: return "Link"
        }
    }

    /// A neutral branch glyph for code hosts.
    ///
    /// Deliberately *not* anything resembling GitHub's Octocat, which is
    /// copyrighted and not ours to draw. A branch is what the link means
    /// anyway, and it reads correctly for GitLab, Codeberg and a bare git
    /// remote too.
    var systemImage: String {
        switch self {
        case .github: return "arrow.triangle.branch"
        case .docs: return "doc.text"
        case .design: return "paintbrush"
        case .deploy: return "bolt.horizontal"
        case .link: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .github: return .gInk2
        case .docs: return .gInk2
        case .design: return .gLavender
        case .deploy: return .gAmber
        case .link: return .gInk2
        }
    }

    /// Guessed from the host, never from the path — a repo URL and an issue URL
    /// on the same host are the same kind of thing.
    static func detect(from urlString: String) -> GraftLinkKind {
        let host = (URL(string: normalise(urlString))?.host ?? urlString).lowercased()
        if host.contains("github") || host.contains("gitlab")
            || host.contains("bitbucket") || host.contains("codeberg")
            || host.contains("sr.ht") || host.contains("git.") {
            return .github
        }
        if host.contains("notion") || host.contains("readthedocs")
            || host.contains("confluence") || host.contains("gitbook")
            || host.contains("docs.") || host.contains("wiki") {
            return .docs
        }
        if host.contains("figma") || host.contains("sketch")
            || host.contains("dribbble") || host.contains("penpot") {
            return .design
        }
        if host.contains("vercel") || host.contains("netlify")
            || host.contains("fly.dev") || host.contains("herokuapp")
            || host.contains("railway") || host.contains("render.com") {
            return .deploy
        }
        return .link
    }

    /// A typed-in `example.com/x` is a URL the user means; without a scheme
    /// `URL(string:)` parses it as a path and `openURL` does nothing at all.
    static func normalise(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
    }
}

// MARK: - Links on the project screen
//
// Replaces `projects.repo_url`, which was half-built, singular, and shown
// nowhere useful. The column still exists on the server for older clients; this
// client no longer surfaces it.

struct ProjectLinksSection: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.openURL) private var openURL

    let projectId: String

    @State private var editing: GraftLink?
    @State private var showAdd = false
    @State private var pendingDelete: GraftLink?

    private var links: [GraftLink] { store.links(for: projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GraftSectionHeader(title: "Links", count: links.isEmpty ? nil : links.count)

            VStack(spacing: 0) {
                ForEach(links) { link in
                    Button {
                        if let url = URL(string: GraftLinkKind.normalise(link.url)) {
                            openURL(url)
                        }
                    } label: {
                        LinkRow(link: link)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editing = link
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDelete = link
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }

                    Rectangle()
                        .fill(Color.gHairline)
                        .frame(height: GraftMetrics.border)
                        .padding(.leading, 42)
                }

                Button {
                    showAdd = true
                } label: {
                    HStack(spacing: GraftMetrics.spaceS) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.gAccentText)
                            .frame(width: 22)
                        Text(links.isEmpty ? "Add a link — repo, docs, deploy" : "Add a link")
                            .font(GraftFont.text(GraftType.body))
                            .foregroundStyle(Color.gAccentText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, GraftMetrics.spaceS)
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color.gSurface)
            .clipShape(RoundedRectangle(cornerRadius: GraftMetrics.radius))
            .overlay(
                RoundedRectangle(cornerRadius: GraftMetrics.radius)
                    .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
            )
            .padding(.horizontal, GraftMetrics.gutter)
        }
        .sheet(isPresented: $showAdd) {
            LinkFormView(projectId: projectId, link: nil)
        }
        .sheet(item: $editing) { link in
            LinkFormView(projectId: projectId, link: link)
        }
        .confirmationDialog(
            pendingDelete.map { "Remove \($0.label)?" } ?? "Remove link?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let link = pendingDelete {
                Button("Remove link", role: .destructive) {
                    Task { try? await store.deleteLink(id: link.id) }
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }
}

// MARK: - One link row

private struct LinkRow: View {
    let link: GraftLink

    var body: some View {
        let kind = GraftLinkKind(rawValue: link.kind) ?? .link

        HStack(spacing: GraftMetrics.spaceS) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(kind.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(link.label.isEmpty ? link.host : link.label)
                    .font(GraftFont.text(GraftType.body))
                    .foregroundStyle(Color.gInk)
                    .lineLimit(1)
                Text(link.host)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.gInk3)
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        // 44pt minimum, per the design system's hit-target rule.
        .frame(minHeight: GraftMetrics.tap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(link.label), \(link.host)")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Add / edit a link

struct LinkFormView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectId: String
    let link: GraftLink?

    @State private var label = ""
    @State private var url = ""
    @State private var kind: GraftLinkKind = .link
    /// True once the user has picked a kind by hand, after which typing a URL
    /// stops overwriting their choice.
    @State private var kindChosenByHand = false
    @State private var isSaving = false
    @State private var loaded = false
    @FocusState private var focus: GraftFormField?

    private var isEditing: Bool { link != nil }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespaces)
    }

    /// Anything typed counts as work in progress worth protecting from a swipe.
    private var hasDraft: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty || !trimmedURL.isEmpty
    }

    var body: some View {
        GraftFormScaffold(
            title: isEditing ? "Edit link" : "Add link",
            confirmLabel: isEditing ? "Save" : "Add",
            confirmDisabled: trimmedURL.isEmpty,
            isBusy: isSaving,
            onCancel: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            GraftSection(title: "Link") {
                GraftTextField(label: "Label", placeholder: "e.g. Repo",
                               text: $label, focused: $focus, field: .label)
                GraftRowDivider()
                GraftTextField(label: "Address", placeholder: "https://…",
                               text: $url, focused: $focus, field: .url)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: url) { _, newValue in
                        guard !kindChosenByHand else { return }
                        kind = GraftLinkKind.detect(from: newValue)
                    }
            }

            GraftSection(title: "Kind",
                         footnote: "Guessed from the address. Change it if the guess is wrong.") {
                // A hand-written binding rather than `.onChange(of: kind)`:
                // auto-detection also writes `kind`, and an observer could not
                // tell the two apart — it would latch on the first keystroke
                // and then never detect again.
                GraftChoiceRow(
                    label: "",
                    options: GraftLinkKind.allCases,
                    selection: Binding(
                        get: { kind },
                        set: { newKind in
                            kind = newKind
                            kindChosenByHand = true
                        }
                    ),
                    title: { $0.label }
                )
            }
        }
        .onAppear {
                // Guarded: `onAppear` fires again when the sheet comes back from
                // a keyboard or a backgrounded app, and re-hydrating would wipe
                // what has been typed since.
                guard !loaded else { return }
                loaded = true
                if let link {
                    label = link.label
                    url = link.url
                    kind = GraftLinkKind(rawValue: link.kind) ?? .link
                    kindChosenByHand = true
                }
            }
        .disabled(isSaving)
        // A swipe-down used to throw the draft away without a word.
        .interactiveDismissDisabled(hasDraft)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let normalised = GraftLinkKind.normalise(trimmedURL)
        let finalLabel = label.trimmingCharacters(in: .whitespaces).isEmpty
            ? (URL(string: normalised)?.host ?? normalised)
            : label.trimmingCharacters(in: .whitespaces)

        if var existing = link {
            existing.label = finalLabel
            existing.url = normalised
            existing.kind = kind.rawValue
            try? await store.updateLink(existing)
        } else {
            try? await store.createLink(
                projectId: projectId,
                label: finalLabel,
                url: normalised,
                kind: kind.rawValue
            )
        }
        dismiss()
    }
}
