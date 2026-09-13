import SwiftUI

/// Every occurrence of a recurring issue, oldest first.
///
/// This is where a repeating issue's history lives, and it only exists because
/// the server spawns-and-archives rather than rolling one row forward. Rolling
/// forward is tidier by one row and destroys the answer to "did I actually put
/// the bins out last week"; archiving keeps every completion and joins them up
/// through `recurrence_parent`.
///
/// Which is also why this is a server call and not a filter over the cache. A
/// completed occurrence is archived, and while the phone does hold archived
/// rows, it only has the ones some earlier pull happened to bring back. The
/// endpoint includes archived rows and is not asked to — it is the only thing
/// that knows the series is complete. The cache is the offline fallback, and
/// says so rather than pretending to be the whole story.
struct IssueSeriesView: View {
    @Environment(GraftStore.self) private var store

    let issue: GraftIssue

    @State private var series: GraftIssueSeries?
    @State private var isLoading = true
    /// True when the list below came out of the cache because the server could
    /// not be reached — the one state that must not be dressed up as complete.
    @State private var isPartial = false

    private var occurrences: [GraftIssue] {
        series?.issues ?? store.cachedSeries(root: issue.seriesRoot)
    }

    private var completed: Int {
        series?.completed ?? occurrences.filter { $0.status == "done" }.count
    }

    var body: some View {
        ZStack {
            Color.gBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: GraftMetrics.spaceL) {
                    header

                    if isLoading && series == nil && occurrences.isEmpty {
                        GraftSkeletonList()
                    } else if occurrences.isEmpty {
                        GraftEmptyState(
                            title: "Nothing recorded yet",
                            subtitle: "This is the first one. Finish it and the next occurrence appears here.",
                            systemImage: "repeat"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        if isPartial { partialNote }
                        GraftSectionHeader(title: "Occurrences", count: occurrences.count, inset: false)
                        ForEach(occurrences) { occurrence in
                            row(occurrence)
                        }
                    }

                    Color.clear.frame(height: GraftMetrics.space3XL)
                }
                .padding(.horizontal, GraftMetrics.gutter)
                .padding(.top, GraftMetrics.spaceM)
            }
        }
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        let rule = Recurrence(rule: issue.recurrence)
        let anchor = RecurrenceAnchor(rawValue: issue.recurrenceAnchor) ?? .schedule
        return VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(spacing: GraftMetrics.spaceXS) {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.gAccentText)
                Text(rule.text.isEmpty ? "Does not repeat" : "Repeats \(rule.text)")
                    .font(GraftFont.text(GraftType.title, .semibold))
                    .foregroundStyle(Color.gInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Text(issue.title)
                .font(GraftFont.text(GraftType.secondary))
                .foregroundStyle(Color.gInk2)
                .lineLimit(2)

            if rule.repeats {
                Text(rule.summary(anchor: anchor))
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: GraftMetrics.spaceXS) {
                tally("\(completed)", "done")
                tally("\(max(0, occurrences.count - completed))", "to come")
            }
            .padding(.top, GraftMetrics.spaceXXS)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GraftMetrics.spaceS)
        .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: GraftMetrics.radius)
                .strokeBorder(Color.gHairline, lineWidth: GraftMetrics.border)
        )
    }

    private func tally(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(GraftFont.mono(GraftType.secondary))
                .monospacedDigit()
                .foregroundStyle(Color.gInk)
            Text(label)
                .font(GraftFont.text(GraftType.caption))
                .foregroundStyle(Color.gInk2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.gSurface2, in: Capsule())
    }

    private var partialNote: some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Image(systemName: "iphone")
                .font(.system(size: 12))
                .foregroundStyle(Color.gAmber)
            Text("Showing what's on this phone — the full history is on the server.")
                .font(GraftFont.text(GraftType.caption))
                .foregroundStyle(Color.gInk2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GraftMetrics.spaceS)
        .padding(.vertical, GraftMetrics.spaceXS)
        .background(Color.gAmber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
    }

    private func row(_ occurrence: GraftIssue) -> some View {
        let status = IssueStatus(rawValue: occurrence.status) ?? .backlog
        let isThisOne = occurrence.id == issue.id
        return NavigationLink(destination: IssueDetailView(issue: occurrence)) {
            HStack(spacing: GraftMetrics.spaceS) {
                StatusRing(status: status, size: GraftMetrics.ring)

                VStack(alignment: .leading, spacing: 3) {
                    Text(occurrence.dueAt.isEmpty
                         ? "No date"
                         : (GraftDate.mediumDate(occurrence.dueAt) ?? occurrence.dueAt))
                        .font(GraftFont.text(GraftType.body, .medium))
                        .foregroundStyle(occurrence.dueAt.isEmpty ? Color.gInk3 : Color.gInk)
                    HStack(spacing: GraftMetrics.spaceXS) {
                        Text(status.label)
                            .font(GraftFont.text(GraftType.caption))
                            .foregroundStyle(status.color)
                        if occurrence.status == "done" {
                            // The completion date is the closest thing the row
                            // has to "when I actually did it" — there is no
                            // completed_at column, and the server's own note
                            // says why one cannot be back-filled.
                            Text("· \(GraftDate.relative(occurrence.updatedAt))")
                                .font(GraftFont.text(GraftType.caption))
                                .foregroundStyle(Color.gInk3)
                        }
                    }
                }

                Spacer(minLength: 0)

                if isThisOne {
                    Text("This one")
                        .font(GraftFont.text(GraftType.micro, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.gAccent.opacity(0.12), in: Capsule())
                }
            }
            .padding(GraftMetrics.spaceS)
            .frame(minHeight: GraftMetrics.tap)
            // Archived is the server's way of saying "replaced", not "hidden",
            // so it is dimmed rather than dropped.
            .opacity(occurrence.archived && occurrence.status != "done" ? 0.55 : 1)
            .background(Color.gSurface, in: RoundedRectangle(cornerRadius: GraftMetrics.radius))
            .overlay(
                RoundedRectangle(cornerRadius: GraftMetrics.radius)
                    .strokeBorder(isThisOne ? Color.gAccent.opacity(0.4) : Color.gHairline,
                                  lineWidth: GraftMetrics.border)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        if let fetched = await store.series(forIssue: issue.id) {
            series = fetched
            isPartial = false
        } else {
            // No server, or it did not answer. The cache still has something
            // useful to say; it just must not claim to be everything.
            isPartial = store.connection != .noServer
        }
    }
}
