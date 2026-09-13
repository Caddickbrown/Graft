# Graft

Project tracker for Dan, Hermes, and Clawrence. Issues, milestones, no sprints, no nonsense.

## Stack

- **Backend** — Flask + SQLite (`graft.db`), port 8911
- **Web** — Vanilla HTML/CSS/JS (`web/`)
- **iOS** — SwiftUI (`ios/`), XcodeGen project

## Structure

```
graft/
  server/
    app.py          Flask backend
  web/
    index.html      Projects list
    issues.html     All issues (cross-project)
    project.html    Single project (board + list view)
    app.js          Shared JS
    style.css       Design system
  ios/
    project.yml     XcodeGen config
    ...             SwiftUI source
  graft.db          SQLite (auto-created)
  README.md
```

## Running

```bash
# Backend
cd /home/dcb/graft
uv run --with flask python3 server/app.py

# Web (served by Flask at http://raspberrypi.local:8911/)
# or standalone:
cd web && python3 -m http.server 8912

# iOS — open ios/ in Xcode after running xcodegen
```

## Systemd

```bash
sudo systemctl start graft
sudo systemctl enable graft
```

## API overview

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/projects | All projects with issue counts |
| POST | /api/projects | Create project |
| PUT | /api/projects/:id | Update project |
| DELETE | /api/projects/:id | Delete project + cascade |
| GET | /api/milestones?project_id= | Milestones |
| POST/PUT/DELETE | /api/milestones/:id | Milestone CRUD |
| GET | /api/issues?project_id=&milestone_id=&status=&priority=&assignee=&area_id=&label=&q=&sort=&dir= | Issues with filters |
| GET | /api/issues?due_before=&due_after=&starts_before=&starts_after=&updated_before=&updated_after= | Issues by date |
| GET | /api/issues?recurring=true&recurrence_parent= | Recurring issues / one series |
| GET | /api/issues?links_to=&links_to_prefix= | Issues linked to a target (exact / by prefix) |
| GET | /api/issues/:id/series | Every occurrence of that issue's series, archived included |
| POST/PUT/DELETE | /api/issues/:id | Issue CRUD |
| PATCH | /api/issues/reorder | Batch sort_order update |
| GET | /api/overview | Hub card data |
| GET | /api/links?project_id=&issue_id=&owner_type=&owner_id= | Links on one owner, or all of them |
| GET | /api/links/backlinks?target=&prefix=&owner_type=&archived= | What points at a target, with its owner inline |
| POST/PUT/DELETE | /api/links/:id | Link CRUD |
| GET | /api/notifications?since=&before=&undelivered=true&kind= | What a client should be telling the user |
| POST | /api/notifications/:id/ack | Mark one delivered (`{"dismissed":true}` also dismisses) |
| GET | /api/digest?date=&assignee= | What a daily summary would say |
| GET | /api/health | Health check |

### Dates

Issues carry two optional ISO dates, `start_at` and `due_at`. Unset is `''`, not
`null` — the same convention `assignee` and `area_id` use. Both are accepted and
returned by `POST /api/issues` and `PUT /api/issues/:id`; an absent key means
"keep what's there", an explicit `""` (or `null`) clears the date.

The six date filters are single-value, not the comma-separated multi-value form
the other filters take, and both ends are inclusive:

| Parameter | Matches |
|-----------|---------|
| `due_before=2026-09-13` | due on or before that day |
| `due_after=2026-09-13` | due on or after that day |
| `starts_before=`, `starts_after=` | the same, on `start_at` |
| `updated_before=`, `updated_after=` | the same, on `updated_at` |

An issue with no date never matches a bound on that date — undated is not due.
A date-only upper bound covers the whole of that day, so `updated_before=<today>`
includes edits made today.

### No project

`POST /api/issues` with no `project_id` (absent or `""`) files the issue under a
sentinel project, id `proj_none`, name "No project". Naming a project that does
not exist is still a 404. The sentinel is hidden from `GET /api/projects`, from
`projects_active` and from `top_projects`, and cannot be deleted; its issues are
counted everywhere ordinary issues are. It is still readable at
`GET /api/projects/proj_none` so a client can resolve the name.

### /api/overview

`projects_active`, `issues_open`, `issues_urgent` and `top_projects` are
unchanged. Added alongside them:

| Field | Shape |
|-------|-------|
| `status_counts` | `{backlog, todo, in-progress, review, done}` — counts of every non-archived issue, keyed by the status value itself |
| `assignee_counts` | `[{assignee, open_count}]`, busiest first; `assignee: ""` is the unassigned pile, the bucket `?assignee=none` selects |
| `milestone_progress` | `[{id, name, project_id, project_name, due_date, done, total}]`, soonest due first, undated last |
| `done_this_week` | issues `done` and last updated within seven days; the one count that also includes archived rows, because a completed recurring occurrence is archived by the server rather than by the user |

Archived issues are excluded from every one of these, and milestones on archived
projects are left out entirely.

### Recurring issues

Three columns on `issues`:

| Column | Meaning |
|--------|---------|
| `recurrence` | an RRULE subset, `''` for "does not repeat" |
| `recurrence_anchor` | `schedule` (default) or `completion` |
| `recurrence_parent` | the id of the series root; `''` on the root itself |

The supported RRULE parts are `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL=n`,
`BYDAY=MO,TU,…` (with `FREQ=WEEKLY` only), `BYMONTHDAY=n[,n]` (with
`FREQ=MONTHLY` only), and one of `COUNT=n` or `UNTIL=<date>`. Anything else —
`BYSETPOS`, ordinal `BYDAY` such as `2MO`, negative `BYMONTHDAY`, `BYMONTH`,
`WKST`, sub-day parts — is **rejected with a 400** rather than ignored, so a rule
never silently does less than it says. Weeks start Monday.

`recurrence_anchor` is the point of the feature. With `schedule`, the next
occurrence is computed from the previous `due_at`, so finishing late does not
move the series — "bins out every Sunday" stays on Sunday, and occurrences missed
in between are skipped rather than piled up. With `completion`, it is computed
from the moment the issue was completed — "water the plants every three days"
means three days after you actually did.

When an issue carrying a rule moves to `done`, the server creates the next
occurrence (copying project, milestone, title, description, assignee, priority,
labels and the recurrence fields, with `start_at`/`due_at` advanced and any
start-to-due window preserved) and archives the completed one. The PUT's response
carries the new issue under a `spawned` key. If `COUNT` or `UNTIL` has run out,
nothing is spawned and the completed issue is left un-archived so the finished
series stays visible.

A recurrence with no `due_at` falls back to `start_at`, and then to the
completion date — it is never rejected for lacking a date.

### Links

A link is an edge from something in Graft to something outside it. The
something-in-Graft is an **owner**, and an owner is a project *or* an issue:

| Column | Meaning |
|--------|---------|
| `owner_type` | `project` or `issue` |
| `owner_id` | the id of that project or issue |
| `project_id` | the owner's id for a project link, `''` for an issue link |
| `kind` | `github`\|`docs`\|`design`\|`deploy`\|`hub`\|`link` — a glyph hint, never validated |

`project_id` is kept and derived, never taken from the request, so it can never
disagree with the owner pair. An issue link leaves it `''` rather than copying
the issue's project into it: a copy would read as "this link is on that project"
to a client written before owners existed, and would go stale the moment the
issue moved project.

`POST /api/links` accepts three spellings of the owner — `owner_type` +
`owner_id`, the `issue_id` shorthand, or bare `project_id`, which is all an
older client knows how to say. An owner that does not exist is a 404; naming
none at all is a 400. On `PUT`, an absent owner means "leave it alone", and
naming one moves the link.

`GET /api/links?project_id=` still means exactly what it always meant: that
project's own links, never the links on its issues.

**`hub://`.** A link whose url is a `hub://…` URI points at an entity in Hub —
`hub://people/tom`, `hub://book/piranesi`, `hub://day/2026-09-13` — rather than
at a web page. The server stores `kind: "hub"` for it whatever the client asked
for, because the scheme is not a guess. Nothing resolves or validates the
target: Graft has no idea what entities Hub holds, and a guess that says "no
such person" about somebody who exists is worse than saying nothing. Both
clients render it as an internal reference rather than an outbound link — no new
tab on the web, no `openURL` on iOS.

**Backlinks.** `GET /api/links/backlinks` answers "what in Graft points at
this", which is the query the owner columns exist for:

| Parameter | Meaning |
|-----------|---------|
| `target=` | exact match on the link's url |
| `prefix=` | front-of-string match, so `prefix=hub://people/` is everything about anybody |
| `owner_type=` | narrow to `issue` or `project` links only |
| `archived=1` | include links whose owner is archived (excluded by default) |

`target` and `prefix` may be sent together and mean the union. Matching is
case-insensitive. One of the two is required; neither is a 400.

The response is an object, not a bare array — `{target, prefix, count, links}` —
and each link carries an `owner` with enough of the issue or project to render a
row without a second request:

```
owner (issue)   {type, id, title, status, priority, archived, start_at, due_at,
                 project_id, project_name}
owner (project) {type, id, title, status, archived, colour, icon, area_id}
```

`title` is on both so one renderer can print a row without knowing which kind it
is holding. `owner` is `null` when the owner does not exist — the offline queue
is allowed to write a link before its owner arrives, so a missing owner can mean
"not yet" as easily as "gone".

**Filtering issues by what they link to.** `?links_to=` matches a link's url
exactly and `?links_to_prefix=` matches the front of it. Both are multi-value
like every other issue filter and OR together, so an issue qualifies by carrying
any one of the links asked about. Only the issue's own links count — a link on
its project does not make it match.

Deleting an issue or a project now deletes the links owned by it (and, for a
project, the links on every issue inside it).

### Notifications

`notifications` rows say what a client should tell the user and when. The client
schedules its own local notifications from them (iOS only holds 64 pending, so
something has to rank them) and acks what it showed; APNs is not wired up.

| Kind | Fires |
|------|-------|
| `starting` | `start_at`, 09:00 UTC |
| `due` | `due_at`, 09:00 UTC |
| `overdue` | the morning after `due_at`, once |
| `assigned` | when an assignee is set or changed |
| `digest` | 08:00 UTC daily, `issue_id` is `''` |

`starting`, `due`, `overdue` and `digest` are derived from the current issues and
are rebuilt on every `GET /api/notifications`, so moving a due date moves its
notification instead of leaving a stale one behind. Rows already delivered or
dismissed are never rebuilt away — they are a record of what the user was told.
`assigned` is an event, not derivable from a row afterwards, so it is written on
the assignment and the rebuild never touches it.

`POST /api/notifications/:id/ack` is idempotent: a replayed ack keeps the first
`delivered_at`.

`GET /api/digest?date=&assignee=` is a plain read with no side effects and
returns `due_today`, `starting_today`, `overdue`, `in_review`, `waiting_on_you`
and a `counts` object. `waiting_on_you` needs `assignee=` (`none` for the
unassigned pile) and lists that person's `todo`/`in-progress` issues that the
other buckets have not already named; without it, it comes back empty.
