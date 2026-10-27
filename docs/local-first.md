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
| Connecting a phone that has its own data | Its rows were replaced by the server's on the first pull | Refused, with the reason, until phase 3 exists (**phase 2, done**) |
| Merge on connect | n/a | Upload with matching, confirmation for lookalikes, nothing deleted (phase 3) |
| Recurring issues, reminders, digest, series | Computed by the server | Phone-side where it matters (phase 4) |

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
  that is set and the library isn't empty, **Connect a server is refused**,
  and the app says why. The first pull from a server replaces every list
  wholesale (`fetchAll`), which would take the phone's own projects off the
  phone. The store refuses the pull too, not just the Settings switch.
- A phone that was connected, disconnected and never edited can reconnect as
  before: its rows came from that server. Turning the server off over a
  non-empty library asks first and says this.
- With no server, the sync strip says nothing. "Local only" on every list
  was a nag about the normal way to use the app.
- Ops queued by an older build with no server stay in the queue. They replay
  on connect, as they always would have, unless writes made since then have
  turned on the refusal above.

## Phase 3: merge on connect

When a phone with its own data connects to a server that already has projects and
issues, the owner's rule applies: **exact matches merge automatically, lookalikes
are shown for confirmation, nothing is ever deleted.**

### What counts as an exact match

| Record | Exact match (merges with no question) | Lookalike (asked about) |
|---|---|---|
| Any record | Same id **and** same `created_at`: it is the same row, seen from two sides | Same id, different `created_at`: an id collision, never a match (see below) |
| Area | Same name, ignoring case and outer spaces | — |
| Project | Same id only | Same name, ignoring case and outer spaces |
| Milestone | Same name inside projects that matched | Same name inside a project matched by confirmation |
| Issue | Same id only | Same title in the same (matched) project |
| Link | Same owner (after remapping) and same URL | — |
| Saved view | Same name and same query | Same name, different query |

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
- **Same-id rows that differ:** the newer `updated_at` wins, field for field
  across the whole row, sent as an ordinary `PUT`. The older version isn't
  kept. Edits made on two sides while apart can't be told apart any better
  than this without per-field history.
- `proj_none` ("No project") is created by every server. A phone-only library
  never has it, so it can't collide.

### What the server needs

1. **`POST /api/merge?dry_run=1`**, given the phone's whole library. It
   returns the plan: exact matches, lookalikes, uploads and id collisions, with
   the ids the server would assign. Matching runs on the server, against every
   row there, inside one read. It shouldn't run on a phone holding a pull that
   may be out of date.
2. **`POST /api/merge`** with the same library plus the phone's answer for each
   lookalike (`merge` or `keep both`). It runs in **one transaction**. It's
   idempotent under `X-Graft-Op-Id`, like the toggles, so a lost reply can be
   retried. It returns the id remap (`{phone_id: server_id}`).
3. **Never replace on merge.** `POST /api/<kind>` is `INSERT OR REPLACE` today
   because the queue replays creates, so an upload through it would overwrite
   a colliding server row. The merge endpoint inserts only, and remaps when an
   id is taken.
4. **An `id_aliases` table** (`old_id`, `new_id`, `kind`) written by the merge.
   An op still in a queue, or a deep link, naming a phone id that was merged
   away then resolves instead of answering 404. Old ids are never reused.
5. **No deletes.** A merge doesn't touch any row it didn't match, and a
   matched row is only updated.
6. Docs for both endpoints in the README's API table, in the same change.

On the phone: Settings' Connect becomes *fetch the plan, show the lookalikes,
apply, take the remap, pull*. `unsyncedLocalWork` clears only after the apply
succeeds. An empty phone connecting is a plain download, and an empty server a
plain upload through the same endpoint.

## Phase 4: what the server still computes

These things work today only because the server does them. A phone-only Graft
lacks them until they move:
- **Completing a recurring issue** spawns the next occurrence on the server
  (`spawned` in the `PUT` reply). With no server, the series stops at the one
  completed. `Recurrence.swift` already parses the rule, and computing the next
  due date is the missing half.
- **Reminders** are built from `/api/notifications`. With no server there are
  none, and Settings says so.
- **The series view and the digest** read server endpoints. Both already fall
  back to the local cache, which says less.

## Risks

- **Swift is compiled first by CI** (`.github/workflows/ios.yml`). Nothing on
  the machine these changes were written on has Xcode.
- **Import:** a cache file that doesn't decode isn't imported and isn't removed.
  The app starts empty, as it did before, and the file stays for a later build
  to read.
- **Refusing to connect** is deliberately blunt. A phone-only user can't join a
  server until phase 3, except by starting from an empty library. Markdown
  export (Settings) keeps a readable copy meanwhile.
- **Backups:** the database is in Application Support, which is in the device
  backup. For a phone with no server, that backup and the Markdown export are
  the only other copies.
