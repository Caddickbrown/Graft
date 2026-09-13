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
| GET | /api/issues/:id/series | Every occurrence of that issue's series, archived included |
| POST/PUT/DELETE | /api/issues/:id | Issue CRUD |
| PATCH | /api/issues/reorder | Batch sort_order update |
| GET | /api/overview | Hub card data |
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
