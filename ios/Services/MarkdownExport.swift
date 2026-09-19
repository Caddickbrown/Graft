import Foundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Markdown export
//
// Getting work *out* of Graft, as text, without a server round trip.
//
// Markdown rather than JSON or CSV, because the thing people want to do with a
// project at the end of a week is paste it into a message, a note or an issue
// tracker that is not this one — and because it stays readable if nothing ever
// opens it again. The whole thing is built from the local cache, so it works
// with no signal, which is most of the point.
//
// The shape is deliberately round-trippable by eye rather than by parser:
// checkboxes for issues (ticked when done), one heading level per nesting step,
// and every field written as `key: value` on one line so a human can scan a
// column of them. Nothing here is escaped beyond what a heading needs — these
// are titles people typed, and mangling them to survive a parser nobody is
// going to write would make the export worse at its actual job.

/// A Markdown document on its way to the share sheet.
///
/// Wrapped in a `Transferable` rather than shared as a plain `String` so the
/// receiving app gets a *file* with a name — "Graft — Website.md" in Files or
/// Mail, rather than an untitled wall of text in the body of a message.
struct GraftMarkdownFile: Transferable {
    let filename: String
    let title: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { file in
            Data(file.text.utf8)
        }
        .suggestedFileName { $0.filename }
    }
}

extension GraftStore {

    // MARK: - One project

    /// Everything the phone knows about one project, as Markdown.
    func markdown(for project: GraftProject) -> GraftMarkdownFile {
        var out: [String] = []
        out.append(contentsOf: projectSection(project, headingLevel: 1))
        return GraftMarkdownFile(
            filename: GraftMarkdown.filename(project.name),
            title: project.name,
            text: out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        )
    }

    // MARK: - Everything

    /// Every live project, filed under its area, as one document.
    ///
    /// Archived projects are left out for the same reason the Projects tab
    /// leaves them out: they are kept, not current, and an export is a picture
    /// of the work in front of you. Archived *issues* inside a live project are
    /// kept, under their own heading — that is the record of what got done.
    func markdownForEverything() -> GraftMarkdownFile {
        var out: [String] = ["# Graft", ""]
        out.append(GraftMarkdown.stamp())
        out.append("")

        let live = projects.filter { !$0.archived }
        let counts = "\(live.count) project\(live.count == 1 ? "" : "s") · "
            + "\(issues.filter { !$0.archived }.count) open issue"
            + (issues.filter { !$0.archived }.count == 1 ? "" : "s")
        out.append(counts)
        out.append("")

        // Areas in the user's own order, then whatever is unfiled — the same
        // grouping the Projects tab draws, so the file reads like the screen.
        let known = Set(areas.map(\.id))
        for area in sortedAreas {
            let inArea = live.filter { $0.areaKey == area.id }
            guard !inArea.isEmpty else { continue }
            out.append("## \(GraftMarkdown.inline(area.name))")
            out.append("")
            for project in inArea {
                out.append(contentsOf: projectSection(project, headingLevel: 3))
            }
        }
        let unfiled = live.filter { !known.contains($0.areaKey) }
        if !unfiled.isEmpty {
            if !areas.isEmpty {
                out.append("## No area")
                out.append("")
            }
            for project in unfiled {
                out.append(contentsOf: projectSection(project, headingLevel: areas.isEmpty ? 2 : 3))
            }
        }

        return GraftMarkdownFile(
            filename: GraftMarkdown.filename("Graft"),
            title: "Graft",
            text: out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        )
    }

    // MARK: - The body of one project, at whatever depth it is drawn

    private func projectSection(_ project: GraftProject, headingLevel: Int) -> [String] {
        let h = String(repeating: "#", count: headingLevel)
        var out: [String] = []

        let icon = project.icon.isEmpty ? "" : project.icon + " "
        out.append("\(h) \(icon)\(GraftMarkdown.inline(project.name))")
        out.append("")

        if headingLevel == 1 { out.append(GraftMarkdown.stamp()); out.append("") }

        if !project.description.isEmpty {
            // As a quote, so a long description never reads as a loose
            // paragraph belonging to the section under it.
            for line in project.description.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("> \(line)")
            }
            out.append("")
        }

        var facts: [String] = ["**Status:** \(project.status)"]
        if project.isFavourite { facts.append("**Favourite**") }
        if project.archived { facts.append("**Archived**") }
        if let area = area(project.areaId) { facts.append("**Area:** \(GraftMarkdown.inline(area.name))") }
        let tags = project.tagList.uniqued
        if !tags.isEmpty {
            facts.append("**Tags:** " + tags.map { "`\($0)`" }.joined(separator: " "))
        }
        out.append(facts.joined(separator: " · "))

        let all = issues.filter { $0.projectId == project.id }
        let open = all.filter { !$0.archived && $0.status != "done" }.count
        let done = all.filter { !$0.archived && $0.status == "done" }.count
        out.append("**Issues:** \(open) open · \(done) done")
        out.append("")

        let projectLinks = links(ownerType: "project", ownerId: project.id)
        if !projectLinks.isEmpty {
            out.append("\(h)# Links")
            out.append("")
            for link in projectLinks {
                out.append("- [\(GraftMarkdown.inline(link.label.isEmpty ? link.url : link.label))](\(link.url))")
            }
            out.append("")
        }

        let projectMilestones = milestones(for: project.id)
        if !projectMilestones.isEmpty {
            out.append("\(h)# Milestones")
            out.append("")
            for milestone in projectMilestones {
                let due = (milestone.dueDate?.isEmpty == false) ? " — due \(milestone.dueDate!)" : ""
                let using = all.filter { $0.milestoneId == milestone.id && !$0.archived }
                let finished = using.filter { $0.status == "done" }.count
                out.append("- **\(GraftMarkdown.inline(milestone.name))**\(due) — \(finished)/\(using.count) done")
                if !milestone.description.isEmpty {
                    out.append("  \(GraftMarkdown.inline(milestone.description))")
                }
            }
            out.append("")
        }

        // Issues, in board order within each column, so the file matches what
        // the board shows rather than inventing a third ordering.
        let live = all.filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
        for status in IssueStatus.allCases {
            let bucket = live.filter { $0.status == status.rawValue }
            guard !bucket.isEmpty else { continue }
            out.append("\(h)# \(status.label)")
            out.append("")
            for issue in bucket { out.append(contentsOf: GraftMarkdown.issueLines(issue)) }
            out.append("")
        }

        let archived = all.filter(\.archived).sorted { $0.updatedAt > $1.updatedAt }
        if !archived.isEmpty {
            out.append("\(h)# Archived")
            out.append("")
            for issue in archived { out.append(contentsOf: GraftMarkdown.issueLines(issue)) }
            out.append("")
        }

        return out
    }
}

// MARK: - The bits that do not need the store

enum GraftMarkdown {

    /// One issue as a checklist item, with its metadata on the same line and
    /// its description indented under it.
    static func issueLines(_ issue: GraftIssue) -> [String] {
        let box = issue.status == "done" ? "[x]" : "[ ]"
        var line = "- \(box) **\(inline(issue.title))**"

        var meta: [String] = []
        if issue.priority != "normal" { meta.append("`\(issue.priority)`") }
        if !issue.assignee.isEmpty { meta.append("@\(issue.assignee)") }
        if !issue.dueAt.isEmpty { meta.append("due \(issue.dueAt)") }
        if !issue.startAt.isEmpty { meta.append("starts \(issue.startAt)") }
        if let milestone = issue.milestoneName, !milestone.isEmpty {
            meta.append("milestone: \(inline(milestone))")
        }
        if !issue.recurrence.isEmpty { meta.append("repeats: \(issue.recurrence)") }
        let labels = issue.labels.filter { !$0.isEmpty }.uniqued
        if !labels.isEmpty { meta.append(labels.map { "`\($0)`" }.joined(separator: " ")) }
        if !meta.isEmpty { line += " — " + meta.joined(separator: " · ") }

        var out = [line]
        if !issue.description.isEmpty {
            for text in issue.description.split(separator: "\n", omittingEmptySubsequences: false) {
                // Two spaces, so the continuation belongs to the checklist item
                // above it rather than closing the list.
                out.append("  \(text)")
            }
        }
        return out
    }

    /// Text on a line of its own, made safe to put inside one.
    ///
    /// Newlines only. Markdown's other specials are left alone on purpose: a
    /// title with an underscore in it is far more likely to be a filename than
    /// an attempt at italics, and backslashes all over an export is a worse
    /// outcome than the occasional stray emphasis.
    static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The "exported on" line. Local time, because whoever reads it is here.
    static func stamp() -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return "*Exported \(f.string(from: Date()))*"
    }

    /// A filename the share sheet can offer: the title, with everything a file
    /// system objects to taken out, and never empty.
    static func filename(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Graft" : cleaned
        return "\(name).md"
    }
}
