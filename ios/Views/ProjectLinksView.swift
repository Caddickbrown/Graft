import SwiftUI

// MARK: - Link kinds
//
// `kind` is only ever a glyph hint, so an unknown value is not an error — it
// falls back to the generic link. It is detected from the hostname when a link
// is created, and can be overridden by hand.
//
// `hub` joined them when links stopped being only about web pages. A hub:// URI
// addresses something in the user's own system — hub://people/tom,
// hub://book/piranesi, hub://day/2026-09-13 — so it is not a page to open but a
// thing to refer to. It is the one kind that is not a guess: the scheme says it,
// and the server derives the same value, so a link written anywhere arrives
// already labelled. Everything about it below follows from that one difference.

enum GraftLinkKind: String, CaseIterable, Identifiable {
    case github
    case docs
    case design
    case deploy
    case hub
    case link

    var id: String { rawValue }

    var label: String {
        switch self {
        case .github: return "Code"
        case .docs: return "Docs"
        case .design: return "Design"
        case .deploy: return "Deploy"
        case .hub: return "In Hub"
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
        // Not a chain link: this one does not go anywhere. Points joined to a
        // centre is what it means — a thing in your own system, related to this.
        case .hub: return "point.3.connected.trianglepath.dotted"
        case .link: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .github: return .gInk2
        case .docs: return .gInk2
        case .design: return .gLavender
        case .deploy: return .gAmber
        // The accent, alone among the kinds: a hub reference is the app talking
        // about the user's own things, and it should read as internal rather
        // than as one more grey row pointing off the device.
        case .hub: return .gAccentText
        case .link: return .gInk2
        }
    }

    /// Guessed from the host, never from the path — a repo URL and an issue URL
    /// on the same host are the same kind of thing.
    static func detect(from urlString: String) -> GraftLinkKind {
        // Before the host is even looked at: hub:// has no host worth reading
        // (`URL(string: "hub://people/tom")?.host` is "people") and the scheme
        // has already answered the question.
        if isHubURL(urlString) { return .hub }
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

    /// True for an address that names something inside the user's own system
    /// rather than a page on the web.
    static func isHubURL(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("hub://")
    }

    /// A typed-in `example.com/x` is a URL the user means; without a scheme
    /// `URL(string:)` parses it as a path and `openURL` does nothing at all.
    /// A `hub://` address already has one and is returned untouched — without
    /// that, the one address this feature exists for is the one that gets
    /// mangled into `https://people/tom`.
    static func normalise(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
    }
}

// MARK: - Links on a project or an issue
//
// Replaces `projects.repo_url`, which was half-built, singular, and shown
// nowhere useful. The column still exists on the server for older clients; this
// client no longer surfaces it.
//
// One section for both owners rather than two that drift apart. The only thing
// that differs between them is the invitation on the empty row — what you
// attach to a project ("repo, docs, deploy") is not what you attach to an issue
// ("the PR, the doc, the person") — and everything else, including a hub://
// reference behaving as a reference rather than a destination, is the same
// component in both places.

struct GraftLinksSection: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.openURL) private var openURL

    let ownerType: String
    let ownerId: String
    /// False where the enclosing screen has already inset its content, as the
    /// issue screen's one padded stack does. Double gutters read as a stray
    /// indent on the one card that has them.
    var insetByGutter: Bool = true

    @State private var editing: GraftLink?
    @State private var showAdd = false
    @State private var pendingDelete: GraftLink?

    private var links: [GraftLink] { store.links(ownerType: ownerType, ownerId: ownerId) }

    private var emptyInvitation: String {
        ownerType == "issue"
            ? "Link something — a PR, a doc, hub://people/tom"
            : "Add a link — repo, docs, deploy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GraftSectionHeader(title: "Links", count: links.isEmpty ? nil : links.count)

            VStack(spacing: 0) {
                ForEach(links) { link in
                    linkButton(link)
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
                        Text(links.isEmpty ? emptyInvitation : "Add a link")
                            .font(GraftFont.text(GraftType.body))
                            .foregroundStyle(Color.gAccentText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
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
            .padding(.horizontal, insetByGutter ? GraftMetrics.gutter : 0)
        }
        .sheet(isPresented: $showAdd) {
            LinkFormView(ownerType: ownerType, ownerId: ownerId, link: nil)
        }
        .sheet(item: $editing) { link in
            LinkFormView(ownerType: ownerType, ownerId: ownerId, link: link)
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

    /// A web link is a button that opens it. A hub:// reference is not: there is
    /// nothing to open — the address names an entity in Hub, and iOS would hand
    /// it to whichever app claims the scheme or, far more likely, do nothing at
    /// all. A row that looks tappable and then does nothing is a worse answer
    /// than one that never claimed to be. Long-press still edits either.
    @ViewBuilder
    private func linkButton(_ link: GraftLink) -> some View {
        if link.isHub {
            LinkRow(link: link)
        } else {
            Button {
                if let url = URL(string: GraftLinkKind.normalise(link.url)) {
                    openURL(url)
                }
            } label: {
                LinkRow(link: link)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The project screen's spelling of the same section, kept so its one call site
/// reads as what it is.
struct ProjectLinksSection: View {
    let projectId: String

    var body: some View {
        GraftLinksSection(ownerType: "project", ownerId: projectId)
    }
}

// MARK: - One link row

private struct LinkRow: View {
    let link: GraftLink

    var body: some View {
        // The stored kind wins where it is one we know, and a hub:// address
        // decides for itself — a row cached before this build carries whatever
        // kind the server gave it, and an unknown one is still not an error.
        let kind: GraftLinkKind = link.isHub ? .hub : (GraftLinkKind(rawValue: link.kind) ?? .link)

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
                    .foregroundStyle(link.isHub ? Color.gAccentText : Color.gInk2)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // The outward arrow is a promise that tapping leaves the app, so a
            // hub reference does not get one — it is a pointer at something the
            // user already owns, and it stays where it is.
            if !link.isHub {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.gInk3)
            }
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        // 44pt minimum, per the design system's hit-target rule.
        .frame(minHeight: GraftMetrics.tap)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(link.isHub
                            ? "\(link.label), in Hub, \(link.host)"
                            : "\(link.label), \(link.host)")
        .accessibilityAddTraits(link.isHub ? [] : .isLink)
    }
}

// MARK: - Add / edit a link

struct LinkFormView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let ownerType: String
    let ownerId: String
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
                GraftTextField(label: "Address", placeholder: "https:// or hub://…",
                               text: $url, focused: $focus, field: .url)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: url) { _, newValue in
                        // A hub:// address overrules a hand-picked kind, which
                        // nothing else does. The scheme is not a guess to be
                        // corrected — the server stores `hub` for it whatever
                        // this form sends, so showing anything else here would
                        // be the app disagreeing with what it is about to save.
                        if GraftLinkKind.isHubURL(newValue) { kind = .hub; return }
                        guard !kindChosenByHand else { return }
                        kind = GraftLinkKind.detect(from: newValue)
                    }
            }

            GraftSection(title: "Kind",
                         footnote: GraftLinkKind.isHubURL(trimmedURL)
                            ? "A hub:// address points at something in your own system, so this one is not a guess."
                            : "Guessed from the address. Change it if the guess is wrong.") {
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
        // A hub address has no host to fall back on, so an unlabelled one is
        // named by what it points at: "people/tom" rather than an empty row.
        let fallbackLabel = GraftLinkKind.isHubURL(normalised)
            ? String(normalised.dropFirst("hub://".count))
            : (URL(string: normalised)?.host ?? normalised)
        let finalLabel = label.trimmingCharacters(in: .whitespaces).isEmpty
            ? fallbackLabel
            : label.trimmingCharacters(in: .whitespaces)
        let finalKind = GraftLinkKind.isHubURL(normalised) ? GraftLinkKind.hub.rawValue : kind.rawValue

        if var existing = link {
            existing.label = finalLabel
            existing.url = normalised
            existing.kind = finalKind
            try? await store.updateLink(existing)
        } else {
            try? await store.createLink(
                ownerType: ownerType,
                ownerId: ownerId,
                label: finalLabel,
                url: normalised,
                kind: finalKind
            )
        }
        dismiss()
    }
}
