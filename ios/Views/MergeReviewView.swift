import SwiftUI

/// The step between "Connect a server" and a phone-only library being on it.
///
/// Opened from Settings with the server's dry-run plan. It says what will
/// happen, asks about the lookalikes, and uploads only when told to. Same-named
/// projects start on Merge, which is the answer almost every time; issues and
/// saved views that only look alike start on Keep both, because a duplicate is
/// cheaper to tidy than two pieces of work folded into one. The rules are the
/// server's — see docs/local-first.md.
struct MergeReviewView: View {
    @Environment(GraftStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var plan: GraftMergePlan
    /// Phone id to `merge` or `keep`, for every lookalike on screen.
    @State private var choices: [String: String]
    @State private var isApplying = false
    @State private var errorText: String?

    /// Called once the server has confirmed the merge, with what it did.
    let onDone: (GraftMergePlan) -> Void

    init(plan: GraftMergePlan, onDone: @escaping (GraftMergePlan) -> Void) {
        _plan = State(initialValue: plan)
        _choices = State(initialValue: Self.defaults(for: plan, keeping: [:]))
        self.onDone = onDone
    }

    enum Choice: String, CaseIterable, Hashable {
        case merge, keep

        var label: String {
            switch self {
            case .merge: return "Merge"
            case .keep: return "Keep both"
            }
        }
    }

    /// The answers to start from: whatever was already chosen, else the
    /// server's default, else Merge (a same-named project has no default).
    private static func defaults(for plan: GraftMergePlan, keeping chosen: [String: String]) -> [String: String] {
        var answers: [String: String] = [:]
        for entry in plan.lookalikes {
            answers[entry.phoneId] = chosen[entry.phoneId] ?? entry.defaultChoice ?? Choice.merge.rawValue
        }
        return answers
    }

    var body: some View {
        GraftFormScaffold(
            title: "Upload to server",
            confirmLabel: "Upload",
            isBusy: isApplying,
            onCancel: { dismiss() },
            onConfirm: { Task { await apply() } }
        ) {
            GraftSection(title: "What happens",
                         footnote: "Nothing on the server or on this phone is deleted.") {
                summaryRow(count: plan.creates.count, text: "uploaded as new")
                GraftRowDivider()
                summaryRow(count: plan.exact.count, text: "already on the server, merged")
                if !plan.collisions.isEmpty {
                    GraftRowDivider()
                    summaryRow(count: plan.collisions.count,
                               text: "given a new id, because the server already uses theirs")
                }
            }

            if !plan.lookalikes.isEmpty {
                GraftSection(title: "These look alike",
                             footnote: "Merge folds this phone's one into the server's. Keep both uploads it alongside.") {
                    ForEach(Array(plan.lookalikes.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { GraftRowDivider() }
                        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
                            Text("\(kindLabel(entry.kind)) · \(entry.name ?? entry.phoneId)")
                                .font(GraftFont.text(GraftType.secondary, .medium))
                                .foregroundStyle(Color.gInk)
                            GraftChoiceRow(
                                label: "",
                                options: Choice.allCases,
                                selection: choiceBinding(entry.phoneId),
                                title: { $0.label }
                            )
                        }
                        .padding(.vertical, GraftMetrics.spaceXS)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isApplying)
        .interactiveDismissDisabled(isApplying)
    }

    private func summaryRow(count: Int, text: String) -> some View {
        HStack(spacing: GraftMetrics.spaceS) {
            Text("\(count)")
                .font(GraftFont.mono(GraftType.secondary, .medium))
                .foregroundStyle(Color.gInk)
                .frame(minWidth: 32, alignment: .leading)
            Text(text)
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: GraftMetrics.tap)
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "projects": return "Project"
        case "issues": return "Issue"
        case "views": return "Saved view"
        default: return kind.capitalized
        }
    }

    private func choiceBinding(_ phoneId: String) -> Binding<Choice> {
        Binding(
            get: { Choice(rawValue: choices[phoneId] ?? "") ?? .merge },
            set: { choices[phoneId] = $0.rawValue }
        )
    }

    private func apply() async {
        isApplying = true
        errorText = nil
        defer { isApplying = false }
        do {
            let result = try await store.applyMerge(decisions: choices)
            if result.applied {
                onDone(result)
                dismiss()
            } else {
                // Held back: something on the server changed since the dry
                // run. Nothing was written; show the new plan and ask again.
                plan = result
                choices = Self.defaults(for: result, keeping: choices)
                errorText = "The server changed while this was open. Check the list again, then upload."
            }
        } catch {
            errorText = "Couldn't upload: \(error.localizedDescription). Nothing on this phone has changed."
        }
    }
}
