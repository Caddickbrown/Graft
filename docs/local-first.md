# Local-first iOS

Graft on the phone should work fully with no server at all, and treat the server
as an optional extra it syncs with when it can reach one. With no server it is a
private tracker. Once a server is connected, its data uploads and is shared with
everyone else who uses that server: Dan on the web, plus Hermes and Clawrence,
who write through the API.

## Where things stand

| Area | Before | Target |
|---|---|---|
| Storage | One JSON file (`graft_data.json`) rewritten whole on every edit | SQLite in Application Support, one row per record (**phase 1, done**) |
| Pending-ops queue | Two JSON files beside it | Tables in the same database (**phase 1, done**) |
| Ids | Minted on the phone (`newId`, e.g. `iss_3f9a0c1e`); the server keeps a client's id | Unchanged. This part was already local-first |
| Onboarding | "No server linked", with Settings as the only way forward | "Start using it" first, "Connect a server" second and in Settings later (**phase 2, done**) |
| Writes with no server | Queued forever, to be replayed on whatever server appears | Not queued. The library is the record (**phase 2, done**) |
| Connecting a phone that has its own data | Its rows were replaced by the server's on the first pull | Nothing pulls or queues until the library is merged in (**phase 2, done**) |
| Merge on connect | n/a | Upload with matching, confirmation for lookalikes, nothing deleted (**phase 3, done**) |
| Recurring issues, reminders, digest, series | Computed by the server | Phone-side where it can be (**phase 4, done**) |

## Phase 1: the database (done)

- `ios/Storage/SQLite.swift` is acorn's thin `sqlite3` wrapper. No packages;
  `libsqlite3.tbd` is an SDK dependency in `project.yml`.
- `ios/Storage/GraftDatabase.swift` keeps `projects`, `issues`, `milestones`,
  `areas`, `links` and `saved_views` as `(id, position, data)`. `data` is the
  same JSON encoding the old file used, so decoding doesn't change. `position`
  keeps the order the lists had in memory.
- `GraftStore.saveCachedData()` still runs after every edit, but the database
  now compares each row with what it last wrote and writes only the rows that
  changed. Deleting a row doesn't renumber the rows after it.
- **Import, once:** on first launch the old file is copied in, but only into
  empty tables. The file is removed only once every id in it reads back. If
  that check fails, the rows just written are cleared, so the next launch tries
  again, and this launch runs from the file. If the database can't be opened,
  the store keeps using the file exactly as before.
- The pending and dropped ops move into `pending_ops` and `dropped_ops`, with
  the same import rule. Settings and view state stay as small JSON files.

## Phase 2: no server by default (done)

- A fresh install shows a welcome screen with **Start using it** as the main
  button and **Connect a server** as the second. Settings has a "Connect a
  server" switch at any time.
- With no server, writes are not queued and nothing is labelled "local only",
  "pending" or "unreachable". A queue with nowhere to go is a debt that lands
  all at once on connect, and the wrong shape for it: connecting should upload
  what the library *is*, not replay how it got there.
- A write made with no server sets `GraftSettings.unsyncedLocalWork`. While
  that is set and the library isn't empty, the store **neither pulls nor
  queues**, even with a server set. The first pull from a server replaces
  every list wholesale (`fetchAll`), which would take the phone's own projects
  off the phone. Connecting in that state is done by a merge (phase 3).
- A phone that was connected, disconnected and never edited can reconnect as
  before: its rows came from that server. One that was edited while
  disconnected merges, like a phone that never had a server. Turning the
  server off over a non-empty library asks first and says this.
- With no server, the sync strip says nothing. "Local only" on every list
  was a nag about the normal way to use the app.
- Ops queued by an older build with no server stay in the queue. They replay
  on connect, as they always would have. If writes made since then call for a
  merge instead, the queue is cleared once the merge is confirmed. The library
  it would have rebuilt is newer, and has just been uploaded.

## Phase 3: merge on connect (done)

When a phone with its own data connects to a server that already has projects and
issues, the owner's rule applies: **exact matches merge automatically, lookalikes
are shown for confirmation, nothing is ever deleted.**

### What counts as an exact match

| Record | Exact match (merges with no question) | Lookalike (asked about) |
|---|---|---|
| Project, milestone, issue | Same id **and** same `created_at`: the same row, seen from two sides | — |
| Any of those | Same id, different `created_at` is an id collision, never a match (see below) | — |
| Area | Same id (the server's name wins), or same name, ignoring case and outer spaces | — |
| Project | — | Same name, ignoring case and outer spaces. **Must be answered**; the phone pre-selects Merge |
| Milestone | Same name inside a project both sides now share (matched or confirmed) | — |
| Issue | — | Same title in the project it maps to. Defaults to keep both |
| Link | Same id (the server's URL wins), or the same URL on the same owner (after remapping) | — |
| Saved view | Same id (the server's name wins), or same name and same query | Same name, different query. Defaults to keep both |
| Recurring occurrence | Same id, same series root, and the id is the one both sides derive from the root and dates | — |
| Anything | Its id is in `id_aliases` from an earlier merge | — |

Areas, links and saved views carry no timestamps on the phone, so a same id
with a different name (or URL) can't be told apart from a rename, and the
server's copy wins rather than both being kept. A collision there is 1 in
billions per pair and not worth a duplicate on every rename.

An unanswered same-named project is matched as merged (the phone's
pre-selected answer) for everything below it, so the dry run already lists the
issue lookalikes inside it. The apply is refused until it is answered.

Rows the phone has under an id the server doesn't, created before the phone's
last pull from that server (`last_pulled_at`), are listed as `resurrected`:
most likely deleted on the server since. They are still uploaded, because a
create that never left an old queue looks exactly the same; the review sheet
says how many and why. Dangling project or milestone references are repaired
(filed under "No project", or cleared) and listed, instead of failing the merge.

Why:
- **Ids are the only real identity Graft has.** Unlike a book's ISBN, a
  project's name is typed by a person. Same id plus same `created_at` only
  happens when the row came from this server before, for example on a phone
  that was connected, disconnected and edited.
- **Ids can collide by chance.** Phone and server ids are both a prefix plus 8
  hex digits (32 bits). With a thousand rows on each side the odds are about
  1 in 4,000. A colliding phone row gets a new id on upload, and every reference
  to it is rewritten. It is never merged.
- **Areas merge by name** because an area is nothing but its name and colour,
  and two "Work" areas are always a mistake. A merge only changes which area a
  project is filed under.
- **Projects matched by name are asked about**, not merged. A merge folds two
  issue lists together and can't be undone, and the server is shared with
  Hermes and Clawrence, whose "Home" may not be Dan's. Confirming is one tap,
  and "Merge" is pre-selected.
- **Issues are only asked about inside projects that already matched.** Two
  issues titled "Renew passport" in the same project are probably the same
  issue. The same title in two unrelated projects isn't.
- **Same-id rows that differ:** the newer `updated_at` wins, across the
  whole row, and the merge writes it. The older version isn't kept. Without
  per-field history, edits made on two sides while apart can't be told apart
  any better than this.
- **Merging a lookalike keeps the server's row.** The phone's project, issue
  or view is not written. Its children are filed under the server's row: a
  merged project's milestones, issues and links move across. Its own fields,
  such as a different colour or description, are not folded in. Choosing Keep
  both is the way to keep them.
- `proj_none` ("No project") is created by every server. A phone that has
  it got it from a server, so it always maps to the server's and is never
  updated.

### The server side (done)

`POST /api/merge` in `server/app.py`, documented in the README, with tests in
`server/tests/test_merge.py`:

1. **A dry run by default.** Given the phone's whole library, it answers with
   the plan and writes nothing. The plan lists exact matches, lookalikes,
   creates, collisions with the ids they would get, updates, undecided
   lookalikes, and the remap. Matching runs on the server, against every row
   there. It shouldn't run on a phone holding a pull that may be out of date.
2. **`?apply=1`** with the same library plus the phone's answers (`merge` or
   `keep`). It runs in **one transaction**, under `BEGIN IMMEDIATE`, so the
   plan it carries out is the one it just drew up. It answers `409` and writes
   nothing while a project lookalike is undecided.
3. **Never replace.** `POST /api/<kind>` is `INSERT OR REPLACE` because the
   queue replays creates, so an upload through it would overwrite a colliding
   server row. The merge only inserts, or updates a same-row match whose phone
   copy is newer. It never deletes.
4. **Collision ids are derived** from the phone id and its `created_at`, so the
   dry run shows the id the apply will use.
5. **`id_aliases`** (`old_id`, `new_id`, `kind`) records every re-key and every
   merge by name. A replayed apply resolves through it first, which makes
   applying the same library twice write nothing the second time. No
   `X-Graft-Op-Id` is needed for that. The other routes don't resolve aliases
   yet. Nothing needs them to: a phone-only library has no queue naming its old
   ids, and the phone replaces its rows with a full pull straight after.
6. Not remapped: ids inside a saved view's query blob, such as a project
   filter. A view whose project was re-keyed or merged opens with a filter that
   matches nothing until it is edited.

### The phone side (done)

- With a server set over a phone-only library, Settings shows **Upload this
  phone's library** under the address. The sync strip says "Not on the server
  yet" until it's done.
- **Upload** asks for the dry run (`GraftStore.planMerge`) and opens
  `MergeReviewView`.
  - The view shows what will be created, merged and re-keyed.
  - It lists the lookalikes with a Merge / Keep both choice. Same-named
    projects start on Merge; issues and saved views start on Keep both.
- **Upload** on the sheet applies (`applyMerge`).
  - A `409`, meaning the server changed since the dry run, shows the new plan
    and asks again. Nothing is written on either side.
  - A network failure says so, and nothing on the phone changes.
- **Only after the server confirms** is `unsyncedLocalWork` cleared, the old
  queue dropped, and a full pull run. The pull replaces the lists with the
  server's copy, which now holds everything. If that pull fails, the phone
  keeps its own rows, under their old ids, until the next sync.
- An empty phone connecting is a plain download, with no merge. An empty
  server is a plain upload through the same sheet.

## Phase 4: what the server computes, on the phone (done)

A phone whose writes stay local (no server, or one it hasn't been merged into
yet) now does these for itself, by the server's own rules:

- **Completing a recurring issue** spawns the next occurrence.
  - `ios/Models/RecurrenceSchedule.swift` ports the server's date rules:
    `_parse_recurrence` (strict, so a rule the server would refuse spawns
    nothing), `_next_occurrence` and `_recurrence_next_dates`. Dates are day
    numbers with no time zone, like Python's `date`. "Today" is UTC, as the
    server's `utcnow().date()` is.
  - `GraftStore.spawnLocally` ports `_spawn_next_occurrence` and the
    completion rule in `update_issue`:
    - "done now and not done before";
    - COUNT spends one per row in the series;
    - the id is `iss_` + sha1(`root|start|due`)[:12], so repeats collapse;
    - the completed issue is archived once there is a next one;
    - `lastSpawned` is set, as the server's `spawned` reply sets it.
  - The port was checked against the server's own functions: the date
    arithmetic was transliterated, Swift integer division included, and
    compared on 20,000 random rules and dates.
- **Reminders** come from the phone's own issues.
  - `NotificationScheduler.desiredLocally` ports `_desired_notifications`
    (starting, due, overdue the morning after, and the daily digest), with
    `_note_id`'s ids.
  - The rows go through the same rebuild as the server's: the 64 cap, the
    ledger, catch-up, and no re-firing. Nothing is acked.
  - Because the ids match, a phone that later connects finds its ledger
    already agrees with the server about what has been shown.
  - The rebuild runs two seconds after the last write, and on foreground.

Left, because they need a server by nature:
- **`assigned` notifications.** They tell you someone *else* gave you
  something. On a phone of one, nobody else can.
- **The digest endpoint and the series endpoint.** The digest's notification
  line is already written on the phone (`digestLine`). The series view falls
  back to the local cache, which for a phone-only library is the whole series,
  and says so.
- **Search through the server's `q`** (`refreshIssues`). Filtering is already
  local and complete.

## Hub: edits made somewhere else

Hub, on the same phone, shows Graft's issues and lets them be ticked off and
edited. It reaches Graft two ways, and both refuse an edit that is older than
the issue it would overwrite.

### Through the server: `_ts`

Hub queues edits offline and sends them later through its Pi proxy as
`PUT /api/issues/<id>` with absolute values. A late replay would undo whatever
changed in the meantime, so the body may carry `_ts`: when the edit was made,
ISO 8601 in UTC (`Z`, an offset, or naive meaning UTC).

- The row's `updated_at` strictly newer than `_ts`: **409**
  `{"error": "This issue changed after that edit was made", "issue": {...}}`,
  the issue as it is now, and nothing is written.
- Otherwise the edit applies as any PUT does. `_ts` is never stored.
- `_ts` that isn't a timestamp: **400**.
- No `_ts`: unchanged. The iOS queue and the web client don't send it.

Tested in `server/tests/test_stale_edit.py`.

### On the phone: the App Group hand-off

Hub writes one file per action into the App Group both apps share,
`group.com.caddickbrown.shared`:

    <container>/handoff/graft-actions/<id>.json    written by Hub, atomically
    <container>/handoff/graft-applied/<id>         empty, written by Graft

```json
{"id": "<uuid>", "kind": "graft.update", "issue_id": "iss_xxxxxxxx",
 "fields": {"status": "done"}, "made_at": "2026-10-28T16:20:47Z", "source": "hub"}
```

`fields` holds absolute Graft fields (`title`, `description`, `status`,
`priority`, `assignee`, `labels`, `project_id`, `milestone_id`, `start_at`,
`due_at`, `recurrence`, `recurrence_anchor`, `archived`); anything else is
ignored. A `graft.create` carries `body` instead: the whole create body,
including the `id` Hub minted.

`ios/Services/HubHandoff.swift` reads the folder after the launch sync and on
every foreground, oldest `made_at` first:

- **`graft.update`** applies through `updateIssue` (and `archiveIssue` when
  `archived` differs), so it is saved, queued and sent like a tap — or stays
  in the library in phone-only mode. Skipped when the issue isn't here, or
  its `updatedAt` is newer than `made_at`. Within one pass, a second edit to
  the same issue is compared with the first edit's `made_at`, not with the
  write that edit just made.
- **`graft.create`** goes through `createIssue` with Hub's id. Skipped if an
  issue with that id exists. `created_at` in the body is not used: the issue
  is stamped when Graft creates it.
- An applied action gets its marker; every action file — applied, skipped or
  malformed — is then deleted. Hub settles anything without a marker by its
  own route.

Without the entitlement (an unsigned build, a profile missing the group) there
is no container and nothing happens. A signed build needs the group registered
in the developer portal and enabled for `com.caddickbrown.graft`.

## Risks

- **Swift is compiled first by CI** (`.github/workflows/ios.yml`). Nothing on
  the machine these changes were written on has Xcode.
- **Import:** a cache file that doesn't decode isn't imported and isn't removed.
  The app starts empty, as it did before, and the file stays for a later build
  to read.
- **Between the apply and the pull**, the phone's rows still carry their old
  ids. The review sheet is modal while the apply is in flight, so nothing is
  edited in that window. But a pull that fails afterwards leaves those ids in
  place until the next one, and an edit to a row whose id was merged away
  would be sent to an id the server doesn't have.
- **Large libraries:** the merge sends the whole library in one request, with
  a 60-second timeout. That is fine for thousands of rows. Well beyond that
  it would want paging, which the endpoint doesn't do.
- **Tests:** `server/tests/test_merge.py` has 11 cases, run in CI. They cover:
  - the dry run writing nothing;
  - a plain upload;
  - same-id merges with the newer copy winning;
  - areas merging by name;
  - collision re-keying, references included;
  - a project lookalike held at `409` until answered, then merged or kept;
  - issue lookalikes defaulting to keep;
  - nothing being deleted;
  - an apply replayed writing nothing.

  Nothing in the iOS flow has been run.
- **Backups:** the database is in Application Support, which is in the device
  backup. For a phone with no server, that backup and the Markdown export are
  the only other copies.
