"""
Graft — Project Tracker Backend
Flask + SQLite, port 8911
"""

import hashlib
import json
import os
import sqlite3
from calendar import monthrange
from datetime import date, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from flask import Flask, g, jsonify, request, send_from_directory

DB_PATH = os.environ.get("GRAFT_DB", "/home/dcb/graft/graft.db")
WEB_DIR = Path(__file__).parent.parent / "web"

app = Flask(__name__, static_folder=None)

# The project an issue lands on when it was captured without one. issues.project_id
# is NOT NULL REFERENCES projects(id), and relaxing that in SQLite means rebuilding
# the table — a destructive operation on a live database to answer what is really a
# presentation question. A real project row that the few project-facing surfaces
# know to hide is the additive answer: the foreign key stays satisfied, no client
# has to learn a new shape, and "no project" becomes one id both ends can spell.
NO_PROJECT_ID = "proj_none"


# ---------------------------------------------------------------------------
# CORS
# ---------------------------------------------------------------------------

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE,PATCH,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response


@app.route("/api/<path:path>", methods=["OPTIONS"])
def options_handler(path):
    return jsonify({}), 200


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------

def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS projects (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            description TEXT DEFAULT '',
            status      TEXT DEFAULT 'active',
            colour      TEXT DEFAULT '#7C7FC4',
            icon        TEXT DEFAULT '',
            archived    INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS milestones (
            id          TEXT PRIMARY KEY,
            project_id  TEXT NOT NULL REFERENCES projects(id),
            name        TEXT NOT NULL,
            description TEXT DEFAULT '',
            due_date    TEXT,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS issues (
            id           TEXT PRIMARY KEY,
            project_id   TEXT NOT NULL REFERENCES projects(id),
            milestone_id TEXT REFERENCES milestones(id),
            title        TEXT NOT NULL,
            description  TEXT DEFAULT '',
            status       TEXT DEFAULT 'backlog',
            priority     TEXT DEFAULT 'normal',
            labels       TEXT DEFAULT '[]',
            assignee     TEXT DEFAULT '',
            start_at     TEXT DEFAULT '',
            due_at       TEXT DEFAULT '',
            recurrence         TEXT DEFAULT '',   -- RRULE subset; see _parse_recurrence
            recurrence_anchor  TEXT DEFAULT 'schedule',
            recurrence_parent  TEXT DEFAULT '',   -- the series root; '' on the root itself
            sort_order   INTEGER DEFAULT 0,
            archived     INTEGER DEFAULT 0,
            created_at   TEXT NOT NULL,
            updated_at   TEXT NOT NULL
        );

        -- areas, links and views deliberately carry NO FOREIGN KEY on their
        -- cross-references (links.project_id, projects.area_id), even though
        -- PRAGMA foreign_keys = ON. An offline client builds rows in whatever
        -- order the user touched them and replays them later, so a link can
        -- reach the server before its project does. With a real FK that INSERT
        -- raises IntegrityError, the iOS offline queue stops on an op that can
        -- never succeed, and every later op is stuck behind it. A dangling id
        -- that resolves on the next sync is the cheaper failure.

        CREATE TABLE IF NOT EXISTS areas (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            colour      TEXT DEFAULT '',
            sort_order  INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        -- A link hangs off an owner, and an owner is a project or an issue.
        -- The pair was added rather than relaxing project_id, because
        -- project_id is NOT NULL and SQLite can only drop that by rebuilding
        -- the table — the same destructive operation issues.project_id talked
        -- us out of above. project_id stays as the project owner's id, so every
        -- shipped client's ?project_id= query, and the iOS build that pulls all
        -- links and filters on the field itself, keep answering what they did.
        --
        -- An issue-owned link leaves project_id '' rather than copying the
        -- issue's project into it. A copy would read as "this link is on that
        -- project" to every client written before this, and it would go stale
        -- the moment the issue moved project. The issue already knows its
        -- project; nothing else has to remember it.
        CREATE TABLE IF NOT EXISTS links (
            id          TEXT PRIMARY KEY,
            project_id  TEXT NOT NULL,          -- no FK: see note above; '' when an issue owns it
            owner_type  TEXT NOT NULL DEFAULT 'project',   -- project|issue
            owner_id    TEXT NOT NULL DEFAULT '',
            label       TEXT NOT NULL,
            url         TEXT NOT NULL,
            kind        TEXT DEFAULT 'link',    -- github|docs|design|deploy|hub|link
            sort_order  INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );

        -- What a client should be telling the user about, and when. This exists
        -- rather than leaving it all to on-device scheduling for two reasons:
        -- iOS caps pending local notifications at 64, so something has to decide
        -- which 64 matter, and an assignment made by somebody else on the server
        -- has no device-side trigger to fire from at all.
        --
        -- No FOREIGN KEY on issue_id, for the reason in the note above, and
        -- because a 'digest' row is about the day rather than any one issue and
        -- carries issue_id ''.
        CREATE TABLE IF NOT EXISTS notifications (
            id           TEXT PRIMARY KEY,
            issue_id     TEXT NOT NULL DEFAULT '',   -- no FK: see note above
            kind         TEXT NOT NULL,              -- due|starting|overdue|assigned|digest
            fire_at      TEXT NOT NULL,
            delivered_at TEXT,
            dismissed_at TEXT,
            created_at   TEXT NOT NULL,
            updated_at   TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS views (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            query       TEXT NOT NULL DEFAULT '{}',
            sort_order  INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
    """)
    db.commit()
    db.close()


def _migrate_db():
    """Add columns that didn't exist in earlier schema versions.

    Idempotent: every ALTER is guarded by a PRAGMA table_info check. Because this
    now runs at import time, several WSGI workers can start at once and race; the
    loser gets "duplicate column name", which means the column exists and there is
    nothing left to do.
    """
    db = sqlite3.connect(DB_PATH)
    try:
        proj_cols = {r[1] for r in db.execute("PRAGMA table_info(projects)")}
        issue_cols = {r[1] for r in db.execute("PRAGMA table_info(issues)")}
        if "icon" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN icon TEXT DEFAULT ''")
        if "archived" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN archived INTEGER DEFAULT 0")
        if "repo_url" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN repo_url TEXT DEFAULT ''")
        if "archived" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN archived INTEGER DEFAULT 0")
        # Scheduling dates, ISO date strings ('2026-09-13'). '' is "unset", the
        # convention assignee and area_id already use, so the column is never NULL:
        # ADD COLUMN with a constant DEFAULT back-fills every existing row with it,
        # and '' is also what an empty <input type="date"> sends. milestone_id shows
        # the cost of the other choice — holding both NULL and '' means every filter
        # that touches it needs two comparisons forever.
        if "start_at" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN start_at TEXT DEFAULT ''")
        if "due_at" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN due_at TEXT DEFAULT ''")
        # Recurrence. '' is "does not recur", the same unset convention as the
        # dates above. recurrence_anchor defaults to 'schedule' rather than '',
        # because an issue that recurs always has an anchor and 'schedule' is the
        # one that matches a calendar — the column never holds a third state.
        # recurrence_parent is the series root, '' on the root itself, so a series
        # is `id = root OR recurrence_parent = root` without a self-join.
        if "recurrence" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN recurrence TEXT DEFAULT ''")
        if "recurrence_anchor" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN recurrence_anchor TEXT DEFAULT 'schedule'")
        if "recurrence_parent" not in issue_cols:
            db.execute("ALTER TABLE issues ADD COLUMN recurrence_parent TEXT DEFAULT ''")
        # No FOREIGN KEY on area_id, on purpose — see the note in init_db().
        # '' means "No area", which is also what a deleted area leaves behind.
        if "area_id" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN area_id TEXT DEFAULT ''")
        # tags: JSON array of strings, free-text with autocomplete.
        if "tags" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN tags TEXT DEFAULT '[]'")
        # area descriptions — freeform notes about an area
        area_cols = {row[1] for row in db.execute("PRAGMA table_info(areas)").fetchall()}
        if "description" not in area_cols:
            db.execute("ALTER TABLE areas ADD COLUMN description TEXT DEFAULT ''")
        # A link's owner. Until now a link could only be pinned to a whole
        # project, which is the one thing Linear did that Graft could not: "the
        # PR that closes this" belongs to an issue, not to everything the issue
        # is filed under. Both columns carry a NOT NULL constant DEFAULT, so ADD
        # COLUMN back-fills every existing row with it in one pass and there is
        # never a NULL to test for — the same reason start_at and due_at default
        # to '' rather than allowing one.
        link_cols = {row[1] for row in db.execute("PRAGMA table_info(links)").fetchall()}
        if "owner_type" not in link_cols:
            db.execute("ALTER TABLE links ADD COLUMN owner_type TEXT NOT NULL DEFAULT 'project'")
        if "owner_id" not in link_cols:
            db.execute("ALTER TABLE links ADD COLUMN owner_id TEXT NOT NULL DEFAULT ''")
        # Every row that existed before this was a project link, and the default
        # above already says so; this is the other half of it, copying the id
        # across. Run on every import rather than once, because it is also the
        # repair for a row written by a client that knows only project_id — the
        # condition goes false as soon as a row is whole, so it is a no-op
        # afterwards.
        db.execute("UPDATE links SET owner_id = project_id WHERE owner_type = 'project' AND owner_id = ''")
        # The two lookups this table now exists to answer: every link on one
        # owner, and every link pointing at one target. The url index is not
        # used by the prefix form of the backlink query — a LOWER() around the
        # column puts paid to that — but it serves the exact form and the
        # duplicate check in _backfill_repo_links.
        db.execute("CREATE INDEX IF NOT EXISTS idx_links_owner ON links(owner_type, owner_id)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_links_url ON links(url)")
        db.commit()
    except sqlite3.OperationalError as exc:
        if "duplicate column name" not in str(exc):
            raise
    finally:
        db.close()
    _backfill_repo_links()
    _remap_project_colours()
    _ensure_no_project()


def _backfill_repo_links():
    """Move projects.repo_url into the links table, consuming the source.

    repo_url is superseded by links, but the column stays: dropping a column is
    not additive, and the shipped iOS build still sends the key. Only the data
    moves, so the UI can stop surfacing repo_url without losing anything.

    This runs at every import, so "move" has to mean move: after a project's link
    is written, its repo_url is cleared to '' in the same transaction. The
    selection condition (non-empty repo_url) then goes false permanently and the
    project can never be back-filled twice, whatever happens to its links
    afterwards. An earlier version instead skipped projects that already had any
    link, which meant deleting the back-filled 'Repo' link on a project with no
    other links resurrected it on the next restart — a deletion that silently
    undoes itself — while the same deletion stuck on a project that happened to
    have a second link. Consuming the source removes the inconsistency and takes
    that weight off the link check entirely.

    The link check survives only to avoid writing a literal duplicate of a URL the
    project already lists; repo_url is consumed either way, because in both cases
    the value now lives in links.

    If an old client repopulates repo_url later, a fresh 'Repo' link on the next
    restart is correct rather than a resurrection: that client asserted the value.

    now() is defined below the import-time migration calls, so the timestamp is
    built inline here. It is the identical expression, not an approximation of it
    — see now(), which is exactly `datetime.utcnow().isoformat()`. The iOS client
    parses these naive UTC strings positionally, so the shape must not drift.
    """
    ts = datetime.utcnow().isoformat()
    db = sqlite3.connect(DB_PATH)
    try:
        rows = db.execute(
            "SELECT id, repo_url FROM projects WHERE repo_url IS NOT NULL AND repo_url != ''"
        ).fetchall()
        for pid, repo_url in rows:
            already = db.execute(
                "SELECT 1 FROM links WHERE project_id=? AND url=? LIMIT 1", (pid, repo_url)
            ).fetchone()
            if not already:
                # owner_type/owner_id are written here rather than left to the
                # back-fill in _migrate_db: this runs immediately after it, so a
                # row inserted now would otherwise sit owner-less until the next
                # restart, and every owner-shaped query would miss it.
                db.execute(
                    "INSERT INTO links (id,project_id,owner_type,owner_id,label,url,kind,sort_order,created_at,updated_at)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?)",
                    ("link_" + str(uuid4())[:8], pid, "project", pid, "Repo", repo_url, "github", 0, ts, ts),
                )
            db.execute("UPDATE projects SET repo_url='' WHERE id=?", (pid,))
        db.commit()
    finally:
        db.close()


def _ensure_no_project():
    """Seed the project that issues captured without one hang off.

    INSERT OR IGNORE, so it is written once and never overwrites a row the user
    has since renamed or re-coloured; running it on every import is a no-op.

    It is a plain project row hidden by id, not a row marked by a new `system`
    flag column. A flag would have to be carried forward by hand through
    create_project's INSERT OR REPLACE — exactly the dance repo_url and area_id
    already do above — and an older client replaying a create would clear it,
    turning the sentinel into an ordinary project on someone's Projects screen.
    An id cannot be un-set by a replay.

    now() is defined below the import-time migration calls, so the timestamp is
    built inline here; see _backfill_repo_links for the same note.
    """
    ts = datetime.utcnow().isoformat()
    db = sqlite3.connect(DB_PATH)
    try:
        db.execute(
            "INSERT OR IGNORE INTO projects (id,name,description,status,colour,icon,archived,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (NO_PROJECT_ID, "No project", "Issues captured without a project.",
             "active", "#8A9098", "", 0, ts, ts),
        )
        db.commit()
    finally:
        db.close()


def _remap_project_colours():
    """Move projects off the old stock-Tailwind palette onto Porcelain / One Green.

    The redesign replaced the project swatches with one muted family tuned to sit
    on both the light and the dark surface (every one clears 3:1 on each). Rows
    written before it still held the Tailwind 500s, so a project card's stripe —
    the most prominent colour on the Projects screen — stayed off-system.

    The mapping is hue-preserving and 1:1, so a project keeps the colour its owner
    picked; only the exact old hexes are touched, which makes this idempotent and
    leaves any hand-set colour alone.
    """
    remap = {
        "#6366f1": "#7C7FC4",  # indigo  -> iris
        "#8b5cf6": "#9A6BA8",  # violet  -> plum
        "#ec4899": "#C06784",  # pink    -> rose
        "#ef4444": "#C2705A",  # red     -> clay
        "#f97316": "#B58234",  # orange  -> ochre
        "#eab308": "#848E3E",  # yellow  -> olive
        "#22c55e": "#4F9A6A",  # green   -> moss
        "#06b6d4": "#3E9A93",  # cyan    -> teal
        "#3b82f6": "#5388C0",  # blue    -> harbour
        "#64748b": "#8A9098",  # slate   -> stone
    }
    db = sqlite3.connect(DB_PATH)
    try:
        for old, new in remap.items():
            # COLLATE NOCASE: the picker wrote lowercase, but a hand-edited row
            # or an older client may hold the same colour upper-cased.
            db.execute(
                "UPDATE projects SET colour=? WHERE colour=? COLLATE NOCASE", (new, old)
            )
        db.commit()
    finally:
        db.close()


# Run the schema setup at import time, not just under __main__. The systemd unit
# and any WSGI server import this module without ever executing __main__, so
# migrations placed there never ran in production and every INSERT naming a newly
# added column (e.g. repo_url) failed with "table projects has no column named ...".
# Both calls are idempotent, so importing repeatedly is harmless.
init_db()
_migrate_db()


def now():
    return datetime.utcnow().isoformat()


def row_to_dict(row):
    return dict(row)


def _required_id(data, key):
    """Pull a required id out of a request body.

    Returns (value, None) or (None, error_response). Clients — especially the iOS
    offline queue — can replay a malformed body; a bare data["..."] there raises
    KeyError and Flask turns that into a 500, which reads as a server fault.
    """
    if not isinstance(data, dict):
        return None, (jsonify({"error": "expected a JSON object"}), 400)
    value = data.get(key)
    if not value:
        return None, (jsonify({"error": f"{key} is required"}), 400)
    return value, None


def _project_exists(db, project_id):
    """404 response if project_id names no project, else None.

    PRAGMA foreign_keys = ON means an unknown parent would otherwise surface as an
    uncaught IntegrityError (500) rather than a client error.
    """
    row = db.execute("SELECT id FROM projects WHERE id=?", (project_id,)).fetchone()
    if row is None:
        return jsonify({"error": f"project {project_id} not found"}), 404
    return None


def _multi(name):
    """Read a query parameter that may appear repeatedly and/or comma-separated.

    ?status=todo&status=review and ?status=todo,review are the same filter; the
    web client builds the comma form from a chip row, the iOS client repeats the
    key. Blank fragments are dropped so a trailing comma is harmless.

    The 'none' convention, which both clients must spell identically because
    nothing else records it:

      - Blank fragments are dropped, so `?area_id=` (or `?status=`) is *no
        filter at all*, not a filter for the empty value. Ask for the empty
        value with the literal `none`.
      - `none` means "the unset bucket" for area_id, assignee and milestone_id.
        area_id and assignee store that as '' (not NULL), milestone_id as NULL
        or ''; each call site maps `none` onto whichever its column uses.
      - `none` mixes freely with real ids — `?milestone_id=none,ms_1234` is
        "unscheduled or in this milestone", and `?area_id=none,area_ab12` is
        "unfiled or in Work". It is matched case-insensitively.
      - Only those three params give `none` a meaning. On status, priority or
        project_id it is just a value that will match nothing.
    """
    values = []
    for raw in request.args.getlist(name):
        for part in raw.split(","):
            part = part.strip()
            if part:
                values.append(part)
    return values


def _date_value(value):
    """Normalise an incoming date to the form we store: an ISO string, or ''.

    JSON null, a missing key's fallback and an empty <input type="date"> all mean
    "no date" and all have to land as the same value. A column holding both NULL
    and '' is what forces milestone_id's filters to compare against two things at
    every call site; start_at and due_at only ever hold one of them.
    """
    if value is None:
        return ""
    return str(value).strip()


def _day_bound(value, upper):
    """Widen a date-only upper bound to the end of that day.

    updated_at holds a full timestamp, so ?updated_before=2026-09-13 compared as
    text would exclude every edit actually made on the 13th — '2026-09-13T09:12'
    sorts after '2026-09-13'. Both ends then read the way a person means them: on
    or before, on or after. A lower bound needs no widening, because a bare date
    already sorts before every timestamp inside it.
    """
    if upper and len(value) == 10 and "T" not in value:
        return value + "T23:59:59.999999"
    return value


def _like_escape(text):
    """Escape LIKE metacharacters so a user's own % or _ matches literally.

    Paired with ESCAPE '\\' at every call site; without it, searching for "100%"
    would match every row.
    """
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# ---------------------------------------------------------------------------
# /api/health
# ---------------------------------------------------------------------------

@app.get("/api/health")
def health():
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# /api/projects
# ---------------------------------------------------------------------------

def _project_with_counts(db, proj_row):
    p = row_to_dict(proj_row)
    # Archived issues are excluded everywhere the user sees a count: the project
    # page's progress bar already filters them out client-side, so counting them
    # here made the same project show two different numbers on two screens.
    counts = db.execute("""
        SELECT
            SUM(CASE WHEN status='backlog'     THEN 1 ELSE 0 END) AS backlog,
            SUM(CASE WHEN status='todo'        THEN 1 ELSE 0 END) AS todo,
            SUM(CASE WHEN status='in-progress' THEN 1 ELSE 0 END) AS in_progress,
            SUM(CASE WHEN status='review'      THEN 1 ELSE 0 END) AS review,
            SUM(CASE WHEN status='done'        THEN 1 ELSE 0 END) AS done,
            COUNT(*)                                               AS total
        FROM issues WHERE project_id = ? AND archived = 0
    """, (p["id"],)).fetchone()
    p["issue_counts"] = {
        "backlog":     counts["backlog"] or 0,
        "todo":        counts["todo"] or 0,
        "in_progress": counts["in_progress"] or 0,
        "review":      counts["review"] or 0,
        "done":        counts["done"] or 0,
        "total":       counts["total"] or 0,
    }
    # Decode tags from the JSON column — clients always see a real array.
    try:
        p["tags"] = json.loads(p.get("tags") or "[]")
    except (json.JSONDecodeError, TypeError):
        p["tags"] = []
    return p


@app.get("/api/projects")
def list_projects():
    db = get_db()
    query = "SELECT * FROM projects WHERE 1=1"
    params = []

    show_archived = request.args.get("archived", "0") == "1"
    if not show_archived:
        query += " AND archived=0"

    # The no-project sentinel is a storage detail, not something the user filed
    # anything into, so it never appears in a project list. Only the row is
    # hidden — its issues are ordinary issues and keep counting everywhere.
    # It stays reachable by id at /api/projects/<id> so a client can resolve the
    # name of an issue that points at it.
    query += " AND id != ?"
    params.append(NO_PROJECT_ID)

    # Multi-value like every other filter. '' is a real value here ("No area"),
    # and _multi drops empty fragments, so ?area_id= alone means "no filter";
    # ask for the unfiled ones with ?area_id=none.
    area_ids = _multi("area_id")
    if area_ids:
        area_ids = ["" if a.lower() == "none" else a for a in area_ids]
        query += " AND area_id IN (%s)" % ",".join("?" for _ in area_ids)
        params.extend(area_ids)

    # Tag filter: project must contain ALL requested tags.
    tag_filters = _multi("tag")
    for tag in tag_filters:
        query += " AND tags LIKE ?"
        params.append(f'%"{tag}"%')

    query += " ORDER BY created_at ASC"
    rows = db.execute(query, params).fetchall()
    return jsonify([_project_with_counts(db, r) for r in rows])


@app.post("/api/projects")
def create_project():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected a JSON object"}), 400
    pid = data.get("id") or "proj_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    # INSERT OR REPLACE deletes the existing row first, so any column we don't name
    # reverts to its default. The iOS offline queue replays a create whenever the
    # response was lost after the server committed, which would silently un-archive
    # the project and reset its creation date. Carry both forward from the row on
    # disk unless the client explicitly sent a new value.
    existing = db.execute("SELECT archived, created_at, repo_url, area_id FROM projects WHERE id=?", (pid,)).fetchone()
    archived = data.get("archived", existing["archived"] if existing else 0)
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    # repo_url is newer than the shipped iOS build, so those clients omit the key
    # entirely; treat "absent" as "keep what's there" and only an explicit value
    # (including "") as an edit, so a replayed create can't wipe it.
    repo_url = data["repo_url"] if "repo_url" in data else (existing["repo_url"] if existing else "")
    # area_id is newer still, so the same rule applies: absent means "keep what's
    # there", an explicit "" means "un-file me".
    area_id = data["area_id"] if "area_id" in data else (existing["area_id"] if existing else "")
    tags = data["tags"] if "tags" in data else (existing["tags"] if existing else "[]")
    if not isinstance(tags, str):
        tags = json.dumps(tags)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO projects (id,name,description,status,colour,icon,repo_url,area_id,tags,archived,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (pid,
             data.get("name", "Untitled"),
             data.get("description", ""),
             data.get("status", "active"),
             data.get("colour", "#7C7FC4"),
             data.get("icon", ""),
             repo_url,
             area_id,
             tags,
            archived, created_at, updated_at,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    return jsonify(_project_with_counts(db, row)), 201


@app.get("/api/projects/tags")
def list_project_tags():
    """Return every distinct tag in use across all projects, sorted."""
    db = get_db()
    rows = db.execute("SELECT tags FROM projects WHERE archived=0 AND tags IS NOT NULL AND tags != '' AND tags != '[]'").fetchall()
    seen = set()
    for row in rows:
        try:
            for t in json.loads(row["tags"] or "[]"):
                if t and isinstance(t, str):
                    seen.add(t.strip())
        except (json.JSONDecodeError, TypeError):
            pass
    return jsonify(sorted(seen, key=str.lower))


@app.get("/api/projects/<pid>")
def get_project(pid):
    db = get_db()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(_project_with_counts(db, row))


@app.put("/api/projects/<pid>")
def update_project(pid):
    db = get_db()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    fields = ["name", "description", "status", "colour", "icon", "archived", "repo_url", "area_id", "tags"]
    updates = {f: data[f] for f in fields if f in data}
    if "tags" in updates and not isinstance(updates["tags"], str):
        updates["tags"] = json.dumps(updates["tags"])
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE projects SET {set_clause} WHERE id=?", (*updates.values(), pid))
    db.commit()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    return jsonify(_project_with_counts(db, row))


@app.delete("/api/projects/<pid>")
def delete_project(pid):
    db = get_db()
    row = db.execute("SELECT id FROM projects WHERE id=?", (pid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    # Deleting a project cascades into its issues, and everything captured
    # without a project lives here. The row is re-seeded on the next import
    # anyway, so the delete would destroy the issues and give nothing back.
    if pid == NO_PROJECT_ID:
        return jsonify({"error": "the no-project bucket cannot be deleted"}), 400
    db.execute(
        "DELETE FROM notifications WHERE issue_id IN (SELECT id FROM issues WHERE project_id=?)",
        (pid,),
    )
    # Before the issues go, while their ids are still reachable: the links on
    # the project itself, and the links on every issue inside it.
    db.execute(
        "DELETE FROM links WHERE (owner_type='project' AND owner_id=?)"
        " OR (owner_type='issue' AND owner_id IN (SELECT id FROM issues WHERE project_id=?))",
        (pid, pid),
    )
    db.execute("DELETE FROM issues WHERE project_id=?", (pid,))
    db.execute("DELETE FROM milestones WHERE project_id=?", (pid,))
    db.execute("DELETE FROM projects WHERE id=?", (pid,))
    db.commit()
    return jsonify({"deleted": pid})


@app.patch("/api/projects/<pid>/archive")
def toggle_project_archive(pid):
    db = get_db()
    row = db.execute("SELECT id, archived FROM projects WHERE id=?", (pid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    new_val = 0 if row["archived"] else 1
    db.execute("UPDATE projects SET archived=?, updated_at=? WHERE id=?", (new_val, now(), pid))
    db.commit()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    return jsonify(_project_with_counts(db, row))


# ---------------------------------------------------------------------------
# /api/milestones
# ---------------------------------------------------------------------------

@app.get("/api/milestones")
def list_milestones():
    db = get_db()
    project_id = request.args.get("project_id")
    if project_id:
        rows = db.execute(
            "SELECT * FROM milestones WHERE project_id=? ORDER BY due_date ASC, created_at ASC",
            (project_id,),
        ).fetchall()
    else:
        rows = db.execute(
            "SELECT * FROM milestones ORDER BY due_date ASC, created_at ASC"
        ).fetchall()
    return jsonify([row_to_dict(r) for r in rows])


@app.post("/api/milestones")
def create_milestone():
    data = request.get_json(force=True)
    project_id, err = _required_id(data, "project_id")
    if err:
        return err
    mid = data.get("id") or "ms_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    err = _project_exists(db, project_id)
    if err:
        return err
    # See create_project: a replayed create must not reset created_at.
    existing = db.execute("SELECT created_at FROM milestones WHERE id=?", (mid,)).fetchone()
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO milestones (id,project_id,name,description,due_date,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
        (
            mid,
            project_id,
            data.get("name", "Untitled"),
            data.get("description", ""),
            data.get("due_date"),
            created_at, updated_at,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM milestones WHERE id=?", (mid,)).fetchone()
    return jsonify(row_to_dict(row)), 201


@app.put("/api/milestones/<mid>")
def update_milestone(mid):
    db = get_db()
    row = db.execute("SELECT * FROM milestones WHERE id=?", (mid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    fields = ["name", "description", "due_date"]
    updates = {f: data[f] for f in fields if f in data}
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE milestones SET {set_clause} WHERE id=?", (*updates.values(), mid))
    db.commit()
    row = db.execute("SELECT * FROM milestones WHERE id=?", (mid,)).fetchone()
    return jsonify(row_to_dict(row))


@app.delete("/api/milestones/<mid>")
def delete_milestone(mid):
    db = get_db()
    row = db.execute("SELECT id FROM milestones WHERE id=?", (mid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    # Unlink issues from this milestone
    db.execute("UPDATE issues SET milestone_id=NULL WHERE milestone_id=?", (mid,))
    db.execute("DELETE FROM milestones WHERE id=?", (mid,))
    db.commit()
    return jsonify({"deleted": mid})


# ---------------------------------------------------------------------------
# /api/areas
# ---------------------------------------------------------------------------

@app.get("/api/areas")
def list_areas():
    db = get_db()
    rows = db.execute("SELECT * FROM areas ORDER BY sort_order ASC, created_at ASC").fetchall()
    return jsonify([row_to_dict(r) for r in rows])


@app.get("/api/areas/<aid>")
def get_area(aid):
    db = get_db()
    row = db.execute("SELECT * FROM areas WHERE id=?", (aid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(row_to_dict(row))


@app.post("/api/areas")
def create_area():
    data = request.get_json(force=True)
    name, err = _required_id(data, "name")
    if err:
        return err
    aid = data.get("id") or "area_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    # See create_project: INSERT OR REPLACE deletes the row first, so a replayed
    # create must carry created_at forward rather than reset it.
    existing = db.execute("SELECT created_at FROM areas WHERE id=?", (aid,)).fetchone()
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO areas (id,name,colour,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?)",
        (
            aid,
            name,
            data.get("colour", ""),
            data.get("sort_order", 0),
            created_at, updated_at,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM areas WHERE id=?", (aid,)).fetchone()
    return jsonify(row_to_dict(row)), 201


@app.put("/api/areas/<aid>")
def update_area(aid):
    db = get_db()
    row = db.execute("SELECT * FROM areas WHERE id=?", (aid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    fields = ["name", "colour", "sort_order", "description"]
    updates = {f: data[f] for f in fields if f in data}
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE areas SET {set_clause} WHERE id=?", (*updates.values(), aid))
    db.commit()
    row = db.execute("SELECT * FROM areas WHERE id=?", (aid,)).fetchone()
    return jsonify(row_to_dict(row))


@app.delete("/api/areas/<aid>")
def delete_area(aid):
    db = get_db()
    row = db.execute("SELECT id FROM areas WHERE id=?", (aid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    # Deleting a container must not destroy its contents. An area is a grouping,
    # not an owner: un-file its projects (area_id = '' is "No area") and leave
    # every project, milestone and issue exactly where it was.
    db.execute("UPDATE projects SET area_id='', updated_at=? WHERE area_id=?", (now(), aid))
    db.execute("DELETE FROM areas WHERE id=?", (aid,))
    db.commit()
    return jsonify({"deleted": aid})


# ---------------------------------------------------------------------------
# /api/links
# ---------------------------------------------------------------------------
#
# A link is an edge from something in Graft to something outside it. Until now
# the something-in-Graft could only be a whole project, which is the one thing
# the tracker this replaced was genuinely good at: "the PR that closes this"
# belongs to an issue, not to everything the issue happens to be filed under.
#
# The other end is not always a web page. Hub — the personal system that reads
# Graft — addresses everything it knows about with hub:// URIs, so a link can
# point at hub://people/tom or hub://book/piranesi and "this issue came out of a
# conversation with Tom" stops being a sentence in a description and becomes an
# edge you can query. Graft does not resolve those, and deliberately: it has no
# idea what entities Hub holds, and a guess that says "no such person" about
# somebody who exists is worse than saying nothing at all.

_LINK_OWNER_TYPES = ("project", "issue")

_HUB_SCHEME = "hub://"


def _is_hub_url(url):
    return (url or "").strip().lower().startswith(_HUB_SCHEME)


def _link_kind(url, given):
    """The kind to store for a link.

    kind is a glyph hint and nothing more — both clients guess it from the
    hostname, an unknown value is not an error, and the server has never had an
    opinion about it. hub:// is the one exception, and only because it is not a
    guess: the scheme *is* the answer, and a pointer into the user's own system
    is a different kind of thing from a web page rather than a different picture
    of one. Forcing it here also means Hub can POST a link without knowing our
    vocabulary, and an older client editing that link's label cannot quietly
    turn it back into a web page. Every other value is taken as sent.
    """
    if _is_hub_url(url):
        return "hub"
    return given or "link"


def _issue_exists(db, issue_id):
    """404 response if issue_id names no issue, else None. See _project_exists."""
    row = db.execute("SELECT id FROM issues WHERE id=?", (issue_id,)).fetchone()
    if row is None:
        return jsonify({"error": f"issue {issue_id} not found"}), 404
    return None


def _link_owner(db, data):
    """Work out which project or issue a link body is about.

    Returns (owner_type, owner_id, project_id, None), or (None, None, None,
    response) on a body that names an owner we will not accept.

    Three spellings are accepted because three generations of client exist: the
    explicit owner_type/owner_id pair, an issue_id shorthand that mirrors the
    project_id one, and bare project_id, which is all a shipped client knows how
    to say. A body naming none of them returns owner_type None, which means "the
    client never mentioned this" — keep what is there on an edit, and is an
    error on a create. Absent is keep; it is the rule the dates already follow.

    project_id is derived, never taken: it holds the owner's id for a project
    link and '' for an issue one, so it can never disagree with the owner pair.
    """
    owner_type = str(data.get("owner_type") or "").strip().lower()
    owner_id = str(data.get("owner_id") or "").strip()
    if not owner_type:
        if str(data.get("issue_id") or "").strip():
            owner_type, owner_id = "issue", str(data["issue_id"]).strip()
        elif str(data.get("project_id") or "").strip():
            owner_type, owner_id = "project", str(data["project_id"]).strip()
    if not owner_type:
        return None, None, None, None
    if owner_type not in _LINK_OWNER_TYPES:
        return None, None, None, (jsonify(
            {"error": f"owner_type must be one of {', '.join(_LINK_OWNER_TYPES)}"}), 400)
    if not owner_id:
        return None, None, None, (jsonify({"error": "owner_id is required"}), 400)

    # links carries no FOREIGN KEY (see init_db), so nothing in the engine would
    # reject an unknown owner — check it here so the client gets a 404 instead
    # of a row pointing at nothing.
    err = _project_exists(db, owner_id) if owner_type == "project" else _issue_exists(db, owner_id)
    if err:
        return None, None, None, err

    return owner_type, owner_id, (owner_id if owner_type == "project" else ""), None


@app.get("/api/links")
def list_links():
    """Links on one owner, or all of them.

    ?project_id= still means exactly what it meant before this endpoint grew an
    owner: that project's own links, never the links on its issues. A client
    that has not been rebuilt asks the same question and gets the same answer.
    ?issue_id= is its counterpart, and ?owner_type=/?owner_id= is the general
    form — ?owner_type=issue on its own is every issue link there is.
    """
    db = get_db()
    owner_type = (request.args.get("owner_type") or "").strip().lower()
    owner_id = (request.args.get("owner_id") or "").strip()
    issue_id = (request.args.get("issue_id") or "").strip()
    project_id = (request.args.get("project_id") or "").strip()
    if issue_id:
        owner_type, owner_id = "issue", issue_id
    elif project_id:
        owner_type, owner_id = "project", project_id

    query = "SELECT * FROM links WHERE 1=1"
    params = []
    if owner_type:
        query += " AND owner_type=?"
        params.append(owner_type)
    if owner_id:
        query += " AND owner_id=?"
        params.append(owner_id)
    query += " ORDER BY sort_order ASC, created_at ASC"
    return jsonify([row_to_dict(r) for r in db.execute(query, params).fetchall()])


@app.get("/api/links/backlinks")
def link_backlinks():
    """Everything in Graft that points at a target, with enough of the owner to
    render a row.

    This is the query the owner columns exist for. Hub's person page asks "what
    Graft issues point at hub://people/tom" (?target=), and its people index asks
    the same question about everybody at once (?prefix=hub://people/). Both
    forms are here rather than one, because a prefix is not a search: a caller
    that wants everything about one person must not also get the person whose id
    starts with the same letters, and a caller that wants the whole tier should
    not have to make one request per entity.

    A separate route rather than ?target= on /api/links, because the two answer
    with different shapes. /api/links returns a bare array of link rows and has
    shipped clients parsing it as one; this returns links joined to their owners,
    and that could not be the same list without breaking them.

    Matching is case-insensitive, which costs the url index on the prefix form
    and is worth it: a hub:// address gets typed by hand in the web form, and
    "hub://People/tom finds nothing" is not a failure anyone would diagnose.

    Archived owners are left out unless ?archived=1, the convention everywhere
    else. An owner that has been deleted comes back as null rather than being
    dropped — the offline queue is allowed to write a link before its owner
    exists (see init_db), so a missing owner can mean "not yet" as easily as
    "gone", and silently swallowing the row would hide a real edge.
    """
    db = get_db()
    target = (request.args.get("target") or "").strip()
    prefix = (request.args.get("prefix") or "").strip()
    if not target and not prefix:
        return jsonify({"error": "target or prefix is required"}), 400

    query = """
        SELECT l.*,
               i.title    AS i_title,    i.status   AS i_status,
               i.priority AS i_priority, i.archived AS i_archived,
               i.start_at AS i_start_at, i.due_at   AS i_due_at,
               i.project_id AS i_project_id, ip.name AS i_project_name,
               p.name AS p_name, p.status AS p_status, p.archived AS p_archived,
               p.colour AS p_colour, p.icon AS p_icon, p.area_id AS p_area_id
        FROM links l
        LEFT JOIN issues   i  ON l.owner_type = 'issue'   AND i.id  = l.owner_id
        LEFT JOIN projects ip ON ip.id = i.project_id
        LEFT JOIN projects p  ON l.owner_type = 'project' AND p.id  = l.owner_id
        WHERE 1=1
    """
    params = []
    # OR inside one bracket, not two ANDed clauses: target and prefix are two
    # ways of naming the same set, so a caller sending both means the union of
    # them, not the empty intersection an AND would almost always produce. The
    # bracket matters — the filters below are ANDed onto this, and SQL would
    # otherwise attach them to the prefix half alone.
    matches = []
    if target:
        matches.append("LOWER(l.url) = ?")
        params.append(target.lower())
    if prefix:
        matches.append("LOWER(l.url) LIKE ? ESCAPE '\\'")
        params.append(_like_escape(prefix.lower()) + "%")
    query += " AND (%s)" % " OR ".join(matches)

    owner_type = (request.args.get("owner_type") or "").strip().lower()
    if owner_type:
        query += " AND l.owner_type = ?"
        params.append(owner_type)

    if request.args.get("archived", "0") != "1":
        # COALESCE, because exactly one of the two joins can have matched: a
        # deleted owner leaves both NULL, and 0 keeps that row in the answer.
        query += " AND COALESCE(i.archived, p.archived, 0) = 0"

    # Newest edge first. Links on one owner have a sort_order the user chose,
    # but across owners that number means nothing — this list is "what has been
    # connected to this thing", and recency is the only ordering it can honestly
    # claim.
    query += " ORDER BY l.created_at DESC, l.id ASC"

    out = []
    for row in db.execute(query, params).fetchall():
        d = row_to_dict(row)
        if d["owner_type"] == "issue" and d["i_title"] is not None:
            owner = {
                "type": "issue", "id": d["owner_id"], "title": d["i_title"],
                "status": d["i_status"], "priority": d["i_priority"],
                "archived": d["i_archived"], "start_at": d["i_start_at"],
                "due_at": d["i_due_at"], "project_id": d["i_project_id"],
                "project_name": d["i_project_name"],
            }
        elif d["owner_type"] == "project" and d["p_name"] is not None:
            # `title` on both, so one renderer can print a row without knowing
            # which kind of thing it is holding; the rest is type-specific.
            owner = {
                "type": "project", "id": d["owner_id"], "title": d["p_name"],
                "status": d["p_status"], "archived": d["p_archived"],
                "colour": d["p_colour"], "icon": d["p_icon"], "area_id": d["p_area_id"],
            }
        else:
            owner = None
        link = {k: v for k, v in d.items() if not (k.startswith("i_") or k.startswith("p_"))}
        link["owner"] = owner
        out.append(link)

    return jsonify({
        "target": target,
        "prefix": prefix,
        "count": len(out),
        "links": out,
    })


@app.post("/api/links")
def create_link():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected a JSON object"}), 400
    db = get_db()
    owner_type, owner_id, project_id, err = _link_owner(db, data)
    if err:
        return err
    if owner_type is None:
        return jsonify({"error": "project_id or issue_id is required"}), 400
    label, err = _required_id(data, "label")
    if err:
        return err
    url, err = _required_id(data, "url")
    if err:
        return err
    lid = data.get("id") or "link_" + str(uuid4())[:8]
    ts = now()
    # See create_project: a replayed create must not reset created_at.
    existing = db.execute("SELECT created_at FROM links WHERE id=?", (lid,)).fetchone()
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO links (id,project_id,owner_type,owner_id,label,url,kind,sort_order,created_at,updated_at)"
        " VALUES (?,?,?,?,?,?,?,?,?,?)",
        (
            lid,
            project_id,
            owner_type,
            owner_id,
            label,
            url,
            _link_kind(url, data.get("kind")),
            data.get("sort_order", 0),
            created_at, updated_at,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM links WHERE id=?", (lid,)).fetchone()
    return jsonify(row_to_dict(row)), 201


@app.put("/api/links/<lid>")
def update_link(lid):
    db = get_db()
    row = db.execute("SELECT * FROM links WHERE id=?", (lid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected a JSON object"}), 400
    fields = ["label", "url", "kind", "sort_order"]
    updates = {f: data[f] for f in fields if f in data}
    # A link written on the project and then moved to the issue it is really
    # about should not have to be deleted and re-made — the id is what a
    # replayed offline op is keyed on, and losing it would resurrect the link.
    owner_type, owner_id, project_id, err = _link_owner(db, data)
    if err:
        return err
    if owner_type is not None:
        updates["owner_type"] = owner_type
        updates["owner_id"] = owner_id
        updates["project_id"] = project_id
    # The url may have changed under the kind, or the kind been sent without it;
    # either way hub:// decides, so re-derive from whichever url now applies.
    if "url" in updates or "kind" in updates:
        updates["kind"] = _link_kind(updates.get("url", row["url"]), updates.get("kind", row["kind"]))
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE links SET {set_clause} WHERE id=?", (*updates.values(), lid))
    db.commit()
    row = db.execute("SELECT * FROM links WHERE id=?", (lid,)).fetchone()
    return jsonify(row_to_dict(row))


@app.delete("/api/links/<lid>")
def delete_link(lid):
    db = get_db()
    row = db.execute("SELECT id FROM links WHERE id=?", (lid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    db.execute("DELETE FROM links WHERE id=?", (lid,))
    db.commit()
    return jsonify({"deleted": lid})


# ---------------------------------------------------------------------------
# /api/views
# ---------------------------------------------------------------------------

def _view_row_to_dict(row):
    d = row_to_dict(row)
    # query is stored as a JSON string and handed back parsed, the same way
    # issues.labels is — the clients round-trip it as an object, not a string.
    if isinstance(d.get("query"), str):
        try:
            d["query"] = json.loads(d["query"])
        except Exception:
            d["query"] = {}
    return d


def _view_query_text(value):
    """Normalise an incoming saved-view query blob to the TEXT we store.

    Clients may send it as an object (web) or as an already-serialised string
    (the iOS queue replays whatever it captured). Both land as JSON TEXT.
    """
    if value is None:
        return "{}"
    if isinstance(value, str):
        return value or "{}"
    return json.dumps(value)


@app.get("/api/views")
def list_views():
    db = get_db()
    rows = db.execute("SELECT * FROM views ORDER BY sort_order ASC, created_at ASC").fetchall()
    return jsonify([_view_row_to_dict(r) for r in rows])


@app.post("/api/views")
def create_view():
    data = request.get_json(force=True)
    name, err = _required_id(data, "name")
    if err:
        return err
    vid = data.get("id") or "view_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    # See create_project: a replayed create must not reset created_at.
    existing = db.execute("SELECT created_at FROM views WHERE id=?", (vid,)).fetchone()
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO views (id,name,query,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?)",
        (
            vid,
            name,
            _view_query_text(data.get("query")),
            data.get("sort_order", 0),
            created_at, updated_at,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM views WHERE id=?", (vid,)).fetchone()
    return jsonify(_view_row_to_dict(row)), 201


@app.put("/api/views/<vid>")
def update_view(vid):
    db = get_db()
    row = db.execute("SELECT * FROM views WHERE id=?", (vid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    fields = ["name", "sort_order"]
    updates = {f: data[f] for f in fields if f in data}
    if "query" in data:
        updates["query"] = _view_query_text(data["query"])
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE views SET {set_clause} WHERE id=?", (*updates.values(), vid))
    db.commit()
    row = db.execute("SELECT * FROM views WHERE id=?", (vid,)).fetchone()
    return jsonify(_view_row_to_dict(row))


@app.delete("/api/views/<vid>")
def delete_view(vid):
    db = get_db()
    row = db.execute("SELECT id FROM views WHERE id=?", (vid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    db.execute("DELETE FROM views WHERE id=?", (vid,))
    db.commit()
    return jsonify({"deleted": vid})


# ---------------------------------------------------------------------------
# Recurrence
# ---------------------------------------------------------------------------
#
# The stored rule is an RRULE subset rather than a syntax of our own. EventKit,
# ICS and every calendar server already speak RRULE, and the companion app is
# heading for EventKit — a bespoke DSL would buy nothing now and have to be
# translated later. Everything here works in whole days, because issues.start_at
# and issues.due_at are dates and there is no time of day to honour.
#
# Deliberately NOT supported, each because it cannot be answered without
# expanding a full occurrence set, which this does not do:
#
#   BYSETPOS        "the last Friday of the month"
#   ordinal BYDAY   2MO, -1FR — the same problem wearing a different hat
#   negative BYMONTHDAY (-1 for "last day") — ditto, and it reads as a day count
#   BYMONTH, BYWEEKNO, BYYEARDAY          nothing in Graft is scoped that finely
#   BYHOUR/BYMINUTE/BYSECOND              there is no time of day to attach to
#   WKST            weeks always start Monday here; it only changes an answer in
#                   combination with BYWEEKNO or an interval'd BYDAY, and one
#                   fixed, documented week start is better than a silent one
#   RDATE/EXDATE, multiple RRULEs         not a one-column idea
#
# An unsupported part is rejected at write time rather than ignored. A rule that
# silently drops the half the user cared about is worse than one that refuses:
# "every weekday" quietly becoming "every day" is a wrong answer the user cannot
# see, and the pickers in both clients only ever emit what is supported here.

_RECUR_FREQS = ("DAILY", "WEEKLY", "MONTHLY", "YEARLY")
_RECUR_DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}
_RECUR_KEYS = ("FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "COUNT", "UNTIL")
_RECUR_ANCHORS = ("schedule", "completion")

# How far the search for the next occurrence will walk before giving up. Only a
# rule that matches nothing can reach this — BYMONTHDAY=31 skips at most seven
# months in a row — so it is a guard against a pathological rule looping forever,
# not a real limit on how far ahead a series can reach.
_RECUR_MAX_STEPS = 500


def _parse_date(text):
    """A yyyy-mm-dd string as a date, or None. Never raises."""
    try:
        return date.fromisoformat((text or "")[:10])
    except (ValueError, TypeError):
        return None


def _parse_recurrence(text):
    """Validate and normalise an RRULE string.

    Returns (parts, None) for a usable rule, (None, None) for "does not recur",
    and (None, message) for something we will not run — the message is written
    for a person, because it is handed straight back as a 400.
    """
    text = (text or "").strip()
    if not text:
        return None, None
    # RRULE names and values are case-insensitive; the UNTIL date is digits and
    # separators, so upper-casing the whole string is safe.
    parts = {}
    for chunk in text.upper().split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "=" not in chunk:
            return None, f"'{chunk}' is not a NAME=VALUE pair"
        key, value = (bit.strip() for bit in chunk.split("=", 1))
        if key not in _RECUR_KEYS:
            return None, f"{key} is not supported (supported: {', '.join(_RECUR_KEYS)})"
        if key in parts:
            return None, f"{key} given more than once"
        parts[key] = value

    freq = parts.get("FREQ")
    if not freq:
        return None, "FREQ is required"
    if freq not in _RECUR_FREQS:
        return None, f"FREQ={freq} is not supported (supported: {', '.join(_RECUR_FREQS)})"

    try:
        interval = int(parts.get("INTERVAL", "1"))
    except ValueError:
        return None, "INTERVAL must be a whole number"
    if interval < 1:
        return None, "INTERVAL must be at least 1"

    byday = []
    if "BYDAY" in parts:
        if freq != "WEEKLY":
            return None, "BYDAY is only supported with FREQ=WEEKLY"
        for token in parts["BYDAY"].split(","):
            token = token.strip()
            if token not in _RECUR_DAYS:
                return None, f"BYDAY={token} is not supported (use MO,TU,WE,TH,FR,SA,SU with no ordinal)"
            byday.append(_RECUR_DAYS[token])
        if not byday:
            return None, "BYDAY is empty"
        byday = sorted(set(byday))

    bymonthday = []
    if "BYMONTHDAY" in parts:
        if freq != "MONTHLY":
            return None, "BYMONTHDAY is only supported with FREQ=MONTHLY"
        for token in parts["BYMONTHDAY"].split(","):
            token = token.strip()
            try:
                dom = int(token)
            except ValueError:
                return None, f"BYMONTHDAY={token} is not a whole number"
            if not 1 <= dom <= 31:
                return None, f"BYMONTHDAY={token} is out of range (1-31; negatives are not supported)"
            bymonthday.append(dom)
        bymonthday = sorted(set(bymonthday))

    count = None
    if "COUNT" in parts:
        try:
            count = int(parts["COUNT"])
        except ValueError:
            return None, "COUNT must be a whole number"
        if count < 1:
            return None, "COUNT must be at least 1"

    until = None
    if "UNTIL" in parts:
        raw = parts["UNTIL"]
        # Accept both the ICS form (20261231, 20261231T120000Z) and the ISO form
        # the rest of Graft writes. Only the date half is kept.
        digits = raw.split("T")[0].replace("-", "")
        if len(digits) == 8 and digits.isdigit():
            until = _parse_date(f"{digits[0:4]}-{digits[4:6]}-{digits[6:8]}")
        if until is None:
            return None, f"UNTIL={raw} is not a date"

    if count is not None and until is not None:
        # RFC 5545 forbids both, and for a good reason: they can disagree, and
        # then the series has two different lengths depending on who is asking.
        return None, "COUNT and UNTIL cannot both be given"

    return {
        "freq": freq, "interval": interval, "byday": byday,
        "bymonthday": bymonthday, "count": count, "until": until,
    }, None


def _recurrence_from_body(data):
    """Pull and validate the recurrence pair out of a request body.

    Returns (recurrence, anchor, None). Either value is None for "the client
    never mentioned this key", which is the absent-means-keep rule the dates
    already follow; an explicit '' is still an edit meaning "stop recurring".
    On a bad rule it returns (None, None, response) for the caller to return.
    """
    def text(value):
        return "" if value is None else str(value).strip()

    recurrence = None
    if "recurrence" in data:
        recurrence = text(data["recurrence"])
        _parts, err = _parse_recurrence(recurrence)
        if err:
            return None, None, (jsonify({"error": f"recurrence: {err}"}), 400)

    anchor = None
    if "recurrence_anchor" in data:
        anchor = text(data["recurrence_anchor"]).lower() or "schedule"
        if anchor not in _RECUR_ANCHORS:
            return None, None, (jsonify(
                {"error": f"recurrence_anchor must be one of {', '.join(_RECUR_ANCHORS)}"}), 400)

    return recurrence, anchor, None


def _month_index(d):
    return d.year * 12 + (d.month - 1)


def _next_occurrence(parts, base, after):
    """The first occurrence of `parts` strictly after `after`, cadence from `base`.

    Pure: no database, no clock. `base` sets the phase of the rule (which weekday,
    which day of the month, which week the interval counts from) and `after` is
    the floor. They are usually different — a weekly issue completed three weeks
    late keeps its Sunday from `base` but must land after today, which skips the
    missed Sundays instead of spawning a backlog of them.

    Returns a date, or None if the rule's UNTIL has passed or the search gave up.
    """
    freq, interval = parts["freq"], parts["interval"]
    until = parts["until"]

    def answer(d):
        if d is None or (until is not None and d > until):
            return None
        return d

    if freq == "DAILY" or (freq == "WEEKLY" and not parts["byday"]):
        step = interval * (7 if freq == "WEEKLY" else 1)
        # Straight to the right multiple rather than a loop: base can be years
        # behind after, and every step in between is a date nobody asked for.
        n = max(1, (after - base).days // step + 1)
        return answer(base + timedelta(days=n * step))

    if freq == "WEEKLY":
        # Weeks start Monday (WKST=MO, fixed — see the note above). With
        # INTERVAL>1 the rule is "these weekdays, every n-th week", and the weeks
        # are counted from the block containing base, so the phase survives.
        block = 7 * interval
        week_start = base - timedelta(days=base.weekday())
        skip = max(0, (after - week_start).days // block)
        cursor = week_start + timedelta(days=skip * block)
        for _ in range(_RECUR_MAX_STEPS):
            for weekday in parts["byday"]:
                candidate = cursor + timedelta(days=weekday)
                if candidate > after:
                    return answer(candidate)
            cursor += timedelta(days=block)
        return None

    if freq == "MONTHLY":
        # An explicit BYMONTHDAY is an assertion about the calendar, so a month
        # without that day is skipped — RFC 5545's rule, and the one an ICS
        # export has to agree with. A day merely inherited from the issue's own
        # due date is not an assertion: the user made a task on the 31st, they
        # never said "the 31st or nothing", and dropping February out of a
        # monthly chore would read as the recurrence having broken. So that case
        # clamps to the last day of the month instead.
        strict = bool(parts["bymonthday"])
        days = parts["bymonthday"] or [base.day]
        first = _month_index(base)
        skip = max(0, (_month_index(after) - first) // interval)
        for step in range(skip, skip + _RECUR_MAX_STEPS):
            year, month = divmod(first + step * interval, 12)
            month += 1
            last = monthrange(year, month)[1]
            for dom in days:
                if dom > last:
                    if strict:
                        continue
                    dom = last
                candidate = date(year, month, dom)
                if candidate > after:
                    return answer(candidate)
        return None

    # YEARLY. The month and day come from base; 29 February clamps to the 28th in
    # a common year for the same reason the monthly case clamps — the date was
    # inherited, not asserted.
    skip = max(0, (after.year - base.year) // interval)
    for step in range(skip, skip + _RECUR_MAX_STEPS):
        year = base.year + step * interval
        last = monthrange(year, base.month)[1]
        candidate = date(year, base.month, min(base.day, last))
        if candidate > after:
            return answer(candidate)
    return None


def _recurrence_next_dates(issue, completed_on):
    """The (start_at, due_at) the next occurrence should carry, or None.

    None means the series ends here — UNTIL has passed, or the rule matches
    nothing reachable.

    A recurrence needs an anchor date to count from, and an issue is allowed not
    to have one. Rather than rejecting that at write time — which would make the
    issue form order-dependent, and would leave the iOS offline queue replaying a
    body the server will refuse forever — the anchor falls back: due_at, then
    start_at, then the day it was completed. The last of those makes a dateless
    'schedule' recurrence behave like a 'completion' one for exactly one cycle
    and then settle onto the calendar, which is a better answer than an error on
    a form the user has already left.
    """
    parts, err = _parse_recurrence(issue["recurrence"])
    if parts is None:
        return None

    due = _parse_date(issue["due_at"])
    start = _parse_date(issue["start_at"])
    anchor = (issue["recurrence_anchor"] or "schedule").strip().lower()

    if anchor == "completion":
        # "Water the plants every three days" means three days after I watered
        # them, so the calendar the issue was on is irrelevant — only the doing.
        base = after = completed_on
    else:
        # "Bins out every Sunday" is the calendar's claim, not mine; missing one
        # does not move the next. base keeps the phase, after skips what I missed.
        base = due or start or completed_on
        after = max(base, completed_on)

    nxt = _next_occurrence(parts, base, after)
    if nxt is None:
        return None

    if due and start:
        # Keep the window the user drew. A task that starts three days before it
        # is due should still start three days before it is due.
        return ((nxt - (due - start)).isoformat(), nxt.isoformat())
    if start and not due:
        return (nxt.isoformat(), "")
    # Both the "only a due date" case and the dateless one land here: an issue
    # that recurs gets a due date from its first spawn onward, because that is
    # the date the next cycle will be measured from.
    return ("", nxt.isoformat())


_ISSUE_COPY_FIELDS = ("project_id", "milestone_id", "title", "description",
                      "priority", "labels", "assignee", "sort_order",
                      "recurrence", "recurrence_anchor")


def _spawn_next_occurrence(db, row, ts):
    """Create the next occurrence of a just-completed recurring issue.

    Returns the new issue's id, or None if nothing was spawned (not recurring,
    series exhausted, or the occurrence already exists).

    Spawn-and-archive rather than rolling the one row forward. Rolling forward is
    tidier by one row, but it overwrites the completion the user just made and
    every one before it, so "did I actually put the bins out last week" becomes
    unanswerable. Archiving keeps the board clean and leaves the history joined
    up through recurrence_parent, which is what `archived` was already for.

    The new id is derived from the series root and the dates rather than random,
    which is what makes this safe to run twice. Two racing completions, an iOS
    queue replaying the same PUT, or an unarchive-and-redo all compute the same
    id, and INSERT OR IGNORE turns the second one into nothing.
    """
    if not (row["recurrence"] or "").strip():
        return None
    parts, _err = _parse_recurrence(row["recurrence"])
    if parts is None:
        # Rules are validated on write, so this is a hand-edited or older row.
        # A completion must still be allowed to complete.
        return None

    root = (row["recurrence_parent"] or "").strip() or row["id"]

    if parts["count"] is not None:
        # COUNT limits how many issues the series produces, which is what the
        # user can see and count. Occurrences that were skipped because the issue
        # was completed late were never rows, so they do not spend the budget —
        # counting them would end a series early for no visible reason.
        made = db.execute(
            "SELECT COUNT(*) AS n FROM issues WHERE id=? OR recurrence_parent=?", (root, root)
        ).fetchone()["n"]
        if made >= parts["count"]:
            return None

    nxt = _recurrence_next_dates(row, datetime.utcnow().date())
    if nxt is None:
        return None
    next_start, next_due = nxt

    new_id = "iss_" + hashlib.sha1(f"{root}|{next_start}|{next_due}".encode()).hexdigest()[:12]
    columns = ["id", "start_at", "due_at", "recurrence_parent", "status", "archived",
               "created_at", "updated_at", *_ISSUE_COPY_FIELDS]
    values = [new_id, next_start, next_due, root, "backlog", 0, ts, ts,
              *[row[f] for f in _ISSUE_COPY_FIELDS]]
    db.execute(
        "INSERT OR IGNORE INTO issues (%s) VALUES (%s)"
        % (",".join(columns), ",".join("?" for _ in columns)),
        values,
    )
    # There is no area to copy: an area belongs to the project, so project_id
    # carries it. Labels come across as the stored JSON text, untouched.
    return new_id


# ---------------------------------------------------------------------------
# /api/issues
# ---------------------------------------------------------------------------

def _issue_row_to_dict(row):
    d = row_to_dict(row)
    # labels is stored as JSON string
    if isinstance(d.get("labels"), str):
        try:
            d["labels"] = json.loads(d["labels"])
        except Exception:
            d["labels"] = []
    return d


# sort= and dir= are the only places user input reaches the SQL text rather than
# a parameter, so both go through a hard-coded whitelist: the request picks a key,
# never supplies a fragment. {dir} is filled from _ISSUE_DIRS, which only ever
# yields the literals ASC and DESC.
_ISSUE_SORTS = {
    # manual is the drag-to-reorder order the board and list views use.
    "manual":        "i.sort_order {dir}, i.created_at ASC",
    "updated":       "i.updated_at {dir}, i.id ASC",
    "created":       "i.created_at {dir}, i.id ASC",
    # Rank by meaning, not alphabetically: urgent -> high -> normal -> low.
    # Anything unrecognised sorts after the known values rather than in the middle.
    "priority":      ("CASE i.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 "
                      "WHEN 'normal' THEN 2 WHEN 'low' THEN 3 ELSE 4 END {dir}, i.sort_order ASC"),
    # backlog -> todo -> in-progress -> review -> done, i.e. board column order.
    "status":        ("CASE i.status WHEN 'backlog' THEN 0 WHEN 'todo' THEN 1 "
                      "WHEN 'in-progress' THEN 2 WHEN 'review' THEN 3 WHEN 'done' THEN 4 "
                      "ELSE 5 END {dir}, i.sort_order ASC"),
    "title":         "i.title COLLATE NOCASE {dir}, i.created_at ASC",
    # Nulls last in both directions: the null flag stays ASC so reversing the
    # direction reverses the dated issues without floating the undated ones to
    # the top. An issue with no milestone has no due date either.
    "milestone_due": ("CASE WHEN m.due_date IS NULL OR m.due_date = '' THEN 1 ELSE 0 END ASC, "
                      "m.due_date {dir}, i.sort_order ASC"),
}

_ISSUE_DIRS = {"asc": "ASC", "desc": "DESC"}

# Recency sorts read newest-first unless asked otherwise; everything else reads
# smallest-first. Clients that care send dir= explicitly.
_ISSUE_SORT_DEFAULT_DIR = {"updated": "desc", "created": "desc"}


def _issue_order_by():
    sort = request.args.get("sort", "manual").strip().lower()
    if sort not in _ISSUE_SORTS:
        sort = "manual"
    direction = request.args.get("dir", "").strip().lower()
    if direction not in _ISSUE_DIRS:
        direction = _ISSUE_SORT_DEFAULT_DIR.get(sort, "asc")
    return _ISSUE_SORTS[sort].format(dir=_ISSUE_DIRS[direction])


@app.get("/api/issues")
def list_issues():
    db = get_db()
    query = "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE 1=1"
    params = []

    show_archived = request.args.get("archived", "0") == "1"
    if not show_archived:
        query += " AND i.archived=0"

    # Every filter is multi-value: repeated params or comma-separated, matched
    # with IN (...). The placeholder list is built from the value count, so the
    # values themselves still only ever travel as parameters.
    project_ids = _multi("project_id")
    if project_ids:
        query += " AND i.project_id IN (%s)" % ",".join("?" for _ in project_ids)
        params.extend(project_ids)

    milestone_ids = _multi("milestone_id")
    if milestone_ids:
        # 'none' means "no milestone" and can be mixed with real ids, e.g.
        # ?milestone_id=none,ms_1234 for "unscheduled or in this milestone".
        want_none = any(m.lower() == "none" for m in milestone_ids)
        real = [m for m in milestone_ids if m.lower() != "none"]
        clauses = []
        if want_none:
            clauses.append("i.milestone_id IS NULL OR i.milestone_id = ''")
        if real:
            clauses.append("i.milestone_id IN (%s)" % ",".join("?" for _ in real))
            params.extend(real)
        query += " AND (%s)" % " OR ".join(clauses)

    statuses = _multi("status")
    if statuses:
        query += " AND i.status IN (%s)" % ",".join("?" for _ in statuses)
        params.extend(statuses)

    priorities = _multi("priority")
    if priorities:
        query += " AND i.priority IN (%s)" % ",".join("?" for _ in priorities)
        params.extend(priorities)

    assignees = _multi("assignee")
    if assignees:
        # 'none' covers the unassigned pile, which is stored as '' not NULL.
        assignees = ["" if a.lower() == "none" else a for a in assignees]
        query += " AND i.assignee IN (%s)" % ",".join("?" for _ in assignees)
        params.extend(assignees)

    # Issues whose project sits in one of these areas. A subquery rather than a
    # join, so the row shape the clients parse stays exactly as it was.
    area_ids = _multi("area_id")
    if area_ids:
        area_ids = ["" if a.lower() == "none" else a for a in area_ids]
        query += " AND i.project_id IN (SELECT id FROM projects WHERE area_id IN (%s))" % ",".join("?" for _ in area_ids)
        params.extend(area_ids)

    # A recurring issue is one carrying a rule, not one that happens to be a
    # spawned occurrence — an occurrence carries the rule too, so the series is
    # visible from any member of it.
    recurring = (request.args.get("recurring") or "").strip().lower()
    if recurring in ("true", "1"):
        query += " AND i.recurrence IS NOT NULL AND i.recurrence != ''"
    elif recurring in ("false", "0"):
        query += " AND (i.recurrence IS NULL OR i.recurrence = '')"

    # Composable form of the series lookup — /api/issues/<id>/series is the one
    # that answers "show me this series" properly, because it also knows the root
    # is not its own child. 'none' is the not-spawned-by-anything bucket.
    parents = _multi("recurrence_parent")
    if parents:
        parents = ["" if x.lower() == "none" else x for x in parents]
        query += " AND i.recurrence_parent IN (%s)" % ",".join("?" for _ in parents)
        params.extend(parents)

    # "Show me everything connected to that book." links_to matches a link's
    # url exactly; links_to_prefix matches the front of it, so
    # ?links_to_prefix=hub://people/ is "anything to do with anybody". Both are
    # multi-value and both OR together into one EXISTS — an issue qualifies by
    # having any one of the links asked about, which is what a filter chip row
    # means everywhere else in this query.
    #
    # EXISTS rather than a join: an issue with two links to the same target
    # would come back twice from a join, and the row shape the clients parse has
    # to stay exactly one row per issue.
    links_to = _multi("links_to")
    links_to_prefix = _multi("links_to_prefix")
    if links_to or links_to_prefix:
        clauses = []
        for value in links_to:
            clauses.append("LOWER(l.url) = ?")
            params.append(value.lower())
        for value in links_to_prefix:
            clauses.append("LOWER(l.url) LIKE ? ESCAPE '\\'")
            params.append(_like_escape(value.lower()) + "%")
        query += (" AND EXISTS (SELECT 1 FROM links l"
                  " WHERE l.owner_type='issue' AND l.owner_id = i.id AND (%s))" % " OR ".join(clauses))

    has_milestone = request.args.get("has_milestone")
    if has_milestone == "1":
        query += " AND i.milestone_id IS NOT NULL AND i.milestone_id != ''"
    elif has_milestone == "0":
        query += " AND (i.milestone_id IS NULL OR i.milestone_id = '')"

    q = (request.args.get("q") or "").strip()
    if q:
        # Case-insensitive substring over everything the user can see on a row,
        # including the id so pasting 'iss_1a2b' finds it. LOWER() on both sides
        # because SQLite's LIKE is only case-insensitive for ASCII. labels is
        # matched against its raw JSON text, which is close enough for a search
        # box (it can also match the brackets/quotes, which no one types).
        pattern = "%" + _like_escape(q.lower()) + "%"
        query += (" AND (LOWER(i.title) LIKE ? ESCAPE '\\'"
                  " OR LOWER(i.description) LIKE ? ESCAPE '\\'"
                  " OR LOWER(i.assignee) LIKE ? ESCAPE '\\'"
                  " OR LOWER(i.labels) LIKE ? ESCAPE '\\'"
                  " OR LOWER(i.id) LIKE ? ESCAPE '\\')")
        params.extend([pattern] * 5)

    # labels is a JSON TEXT array, so there is no join to make; match the
    # serialised form instead. The trap is that a naive LIKE '%bug%' also matches
    # ["debug"]. Including the JSON quotes in the pattern — LIKE '%"bug"%' —
    # makes it exact: '"debug"' has no quote immediately before 'bug', so it
    # cannot contain '"bug"', and '["bug", "ui"]' does. json.dumps always emits
    # those quotes, and _issue_row_to_dict/create_issue are the only writers, so
    # the serialisation is ours to rely on. A label containing a literal quote or
    # backslash would be JSON-escaped in storage and is not searchable this way;
    # the clients don't offer such labels. Multi-value = OR (contains any).
    labels = _multi("label")
    if labels:
        clauses = []
        for label in labels:
            clauses.append("LOWER(i.labels) LIKE ? ESCAPE '\\'")
            params.append('%"' + _like_escape(label.lower()) + '"%')
        query += " AND (%s)" % " OR ".join(clauses)

    # Date bounds are deliberately single-value: these do not go through _multi().
    # "due before X" has exactly one X, and a second one could only contradict the
    # first — ?due_before=a,b as a set would have to mean "before a OR before b",
    # which is just the later of the two, so the multi form would be a trap.
    # Both ends are inclusive: due_before=today is "due today or already overdue",
    # which is the question the caller is actually asking.
    #
    # The column names come from this table, never from the request, the same way
    # sort= is whitelisted in _ISSUE_SORTS; only the values travel as parameters.
    for name, column, op in (
        ("due_before",     "i.due_at",     "<="),
        ("due_after",      "i.due_at",     ">="),
        ("starts_before",  "i.start_at",   "<="),
        ("starts_after",   "i.start_at",   ">="),
        ("updated_before", "i.updated_at", "<="),
        ("updated_after",  "i.updated_at", ">="),
    ):
        bound = (request.args.get(name) or "").strip()
        if not bound:
            # Blank means no filter, matching _multi()'s handling of ?status= —
            # a cleared date input must not silently become a filter for ''.
            continue
        # An issue with no due date is not due. '' sorts before every real date,
        # so without this guard every undated issue would satisfy due_before and
        # the "what is due today" list would be the whole backlog. The IS NOT NULL
        # half costs nothing and covers a row written before the column had its
        # default, or by hand.
        query += f" AND {column} IS NOT NULL AND {column} != '' AND {column} {op} ?"
        params.append(_day_bound(bound, op == "<="))

    query += " ORDER BY " + _issue_order_by()
    rows = db.execute(query, params).fetchall()
    return jsonify([_issue_row_to_dict(r) for r in rows])


@app.post("/api/issues")
def create_issue():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected a JSON object"}), 400
    # A capture flow produces far more "a thing to do" than "a thing to do on
    # project X", and rejecting the first kind pushed the client into inventing a
    # project to satisfy the column. An absent or empty project_id falls back to
    # the no-project bucket instead of a 400. Naming a project that does not
    # exist is still a 404 below: that is a client bug, not an omission.
    project_id = (data.get("project_id") or "").strip() or NO_PROJECT_ID
    iid = data.get("id") or "iss_" + str(uuid4())[:8]
    ts = now()
    labels = json.dumps(data.get("labels", []))
    db = get_db()
    err = _project_exists(db, project_id)
    if err:
        return err
    milestone_id = data.get("milestone_id")
    if milestone_id:
        row = db.execute("SELECT id FROM milestones WHERE id=?", (milestone_id,)).fetchone()
        if row is None:
            return jsonify({"error": f"milestone {milestone_id} not found"}), 404
    # See create_project: INSERT OR REPLACE resets any column it doesn't name, so a
    # replayed create would un-archive the issue and reset its creation date.
    recurrence, recurrence_anchor, err = _recurrence_from_body(data)
    if err:
        return err
    existing = db.execute(
        "SELECT archived, created_at, start_at, due_at, recurrence, recurrence_anchor, recurrence_parent, assignee"
        " FROM issues WHERE id=?", (iid,)
    ).fetchone()
    archived = data.get("archived", existing["archived"] if existing else 0)
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    # The dates are newer than the shipped iOS build, which omits both keys
    # entirely, so create_project's rule applies here too: absent means "keep
    # what's there", an explicit value (including "") is an edit. Without it a
    # replayed create would quietly strip the dates off a scheduled issue.
    start_at = _date_value(data["start_at"]) if "start_at" in data else ((existing["start_at"] or "") if existing else "")
    due_at = _date_value(data["due_at"]) if "due_at" in data else ((existing["due_at"] or "") if existing else "")
    # Same rule again for the recurrence trio, and it matters more here: a client
    # that has never heard of recurrence replaying a create would otherwise turn a
    # repeating chore into a one-off, silently, and only the next Sunday would say so.
    if recurrence is None:
        recurrence = (existing["recurrence"] or "") if existing else ""
    if recurrence_anchor is None:
        recurrence_anchor = (existing["recurrence_anchor"] or "schedule") if existing else "schedule"
    recurrence_parent = (data["recurrence_parent"].strip() if isinstance(data.get("recurrence_parent"), str)
                         else ((existing["recurrence_parent"] or "") if existing else ""))
    updated_at = data.get("updated_at") or ts
    db.execute(
        """INSERT OR REPLACE INTO issues
           (id,project_id,milestone_id,title,description,status,priority,labels,assignee,start_at,due_at,
            recurrence,recurrence_anchor,recurrence_parent,sort_order,archived,created_at,updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            iid,
            project_id,
            milestone_id,
            data.get("title", "Untitled"),
            data.get("description", ""),
            data.get("status", "backlog"),
            data.get("priority", "normal"),
            labels,
            data.get("assignee", ""),
            start_at,
            due_at,
            recurrence,
            recurrence_anchor,
            recurrence_parent,
            data.get("sort_order", 0),
            archived, created_at, updated_at,
        ),
    )
    # An assignment is an event, not a state, so it cannot be derived later from
    # the row (see _desired_notifications). Record it while we can still see that
    # the row is new — a replayed create is not a fresh assignment.
    if existing is None:
        _record_assignment(db, iid, data.get("assignee", ""), ts)
    db.commit()
    row = db.execute(
        "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE i.id=?",
        (iid,),
    ).fetchone()
    return jsonify(_issue_row_to_dict(row)), 201


@app.put("/api/issues/<iid>")
def update_issue(iid):
    db = get_db()
    row = db.execute("SELECT * FROM issues WHERE id=?", (iid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(force=True)
    fields = ["title", "description", "status", "priority", "assignee", "milestone_id",
              "start_at", "due_at", "recurrence_parent", "sort_order", "archived"]
    updates = {f: data[f] for f in fields if f in data}
    recurrence, recurrence_anchor, err = _recurrence_from_body(data)
    if err:
        return err
    if recurrence is not None:
        updates["recurrence"] = recurrence
    if recurrence_anchor is not None:
        updates["recurrence_anchor"] = recurrence_anchor
    # Absent already means "keep what's there" — the comprehension above never
    # names a key the client didn't send. Present and null is the other half of
    # that rule: an explicit clear, which must land as '' rather than NULL so the
    # column keeps holding exactly one kind of empty.
    for key in ("start_at", "due_at"):
        if key in updates:
            updates[key] = _date_value(updates[key])
    if "labels" in data:
        updates["labels"] = json.dumps(data["labels"])
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE issues SET {set_clause} WHERE id=?", (*updates.values(), iid))

    # A completion is a transition, not a state, and this is the only handler that
    # can see one: `row` is the issue as it was before this PUT. Both halves are
    # needed. Without "the client asked for done", a PUT that only renames a
    # finished issue would spawn another occurrence; without "it was not done
    # already", re-sending done — which the iOS queue does whenever a response is
    # lost — would spawn one per replay. The deterministic id in
    # _spawn_next_occurrence is the third guard, for the case where two of these
    # race each other.
    completed = updates.get("status") == "done" and row["status"] != "done"
    if "assignee" in updates and (updates["assignee"] or "") != (row["assignee"] or ""):
        _record_assignment(db, iid, updates["assignee"], updates["updated_at"])
    db.commit()

    spawned = None
    if completed:
        fresh = db.execute("SELECT * FROM issues WHERE id=?", (iid,)).fetchone()
        # Spawn from the issue as it now is, not as it was: a PUT that renames and
        # completes in one go should carry the new name into the next occurrence.
        spawned = _spawn_next_occurrence(db, fresh, updates["updated_at"])
        if spawned:
            # Only archive when the series actually continues. A COUNT or UNTIL
            # that has run out leaves the last one sitting there, done, where the
            # user can see the series finished rather than silently vanish.
            db.execute("UPDATE issues SET archived=1, updated_at=? WHERE id=?",
                       (updates["updated_at"], iid))
        db.commit()

    row = db.execute(
        "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE i.id=?",
        (iid,),
    ).fetchone()
    payload = _issue_row_to_dict(row)
    if spawned:
        # The client has to learn about the new row somehow, and the alternative
        # is every completion being followed by a blind refetch.
        nxt = db.execute(
            "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE i.id=?",
            (spawned,),
        ).fetchone()
        payload["spawned"] = _issue_row_to_dict(nxt)
    return jsonify(payload)


@app.get("/api/issues/<iid>/series")
def issue_series(iid):
    """Every occurrence of the series this issue belongs to, oldest first.

    Archived rows are included and not optional here: a completed occurrence is
    archived by design, so a series that hid them would be almost entirely empty
    and the endpoint would answer the opposite of the question it was asked.
    """
    db = get_db()
    row = db.execute("SELECT id, recurrence_parent FROM issues WHERE id=?", (iid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    root = (row["recurrence_parent"] or "").strip() or row["id"]
    rows = db.execute("""
        SELECT i.*, m.name AS milestone_name
        FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id
        WHERE i.id = ? OR i.recurrence_parent = ?
        ORDER BY CASE WHEN i.due_at IS NULL OR i.due_at = '' THEN 1 ELSE 0 END ASC,
                 i.due_at ASC, i.created_at ASC
    """, (root, root)).fetchall()
    issues = [_issue_row_to_dict(r) for r in rows]
    return jsonify({
        "root": root,
        "count": len(issues),
        "completed": sum(1 for i in issues if i["status"] == "done"),
        "issues": issues,
    })


@app.delete("/api/issues/<iid>")
def delete_issue(iid):
    db = get_db()
    row = db.execute("SELECT id FROM issues WHERE id=?", (iid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    db.execute("DELETE FROM issues WHERE id=?", (iid,))
    # The derived rows would be reaped by the next reconcile anyway, but a
    # delivered or dismissed one would not — it is kept on purpose, and once the
    # issue is gone it is a record of nothing.
    db.execute("DELETE FROM notifications WHERE issue_id=?", (iid,))
    # Same argument for its links. Nothing reaps these, and an orphan would keep
    # turning up in the backlinks Hub renders — an edge to an issue that no
    # longer exists, which it can only draw as a blank row.
    db.execute("DELETE FROM links WHERE owner_type='issue' AND owner_id=?", (iid,))
    db.commit()
    return jsonify({"deleted": iid})


@app.patch("/api/issues/<iid>/archive")
def toggle_issue_archive(iid):
    db = get_db()
    row = db.execute("SELECT id, archived FROM issues WHERE id=?", (iid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    new_val = 0 if row["archived"] else 1
    db.execute("UPDATE issues SET archived=?, updated_at=? WHERE id=?", (new_val, now(), iid))
    db.commit()
    row = db.execute(
        "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE i.id=?",
        (iid,),
    ).fetchone()
    return jsonify(_issue_row_to_dict(row))


@app.patch("/api/issues/reorder")
def reorder_issues():
    data = request.get_json(force=True)
    if not isinstance(data, dict):
        return jsonify({"error": "expected a JSON object"}), 400
    items = data.get("issues", [])
    if not isinstance(items, list):
        return jsonify({"error": "issues must be a list"}), 400
    # Validate the whole batch before touching the DB: a malformed entry halfway
    # through would otherwise commit a partial reorder (or raise KeyError -> 500).
    for item in items:
        if not isinstance(item, dict) or "id" not in item or "sort_order" not in item:
            return jsonify({"error": "each issue needs an id and a sort_order"}), 400
    db = get_db()
    ts = now()
    for item in items:
        db.execute(
            "UPDATE issues SET sort_order=?, updated_at=? WHERE id=?",
            (item["sort_order"], ts, item["id"]),
        )
    db.commit()
    return jsonify({"updated": len(items)})


# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------
#
# What a client should be telling the user about, and when. The rows exist on the
# server rather than being scheduled purely on the device because iOS will only
# hold 64 pending local notifications — something has to rank them, and only the
# server can see the whole set — and because an issue assigned by somebody else
# has no device-side trigger to fire from at all. A client reads this, schedules
# its 64 best, and acks what it showed. APNs can be layered on later without any
# of this changing shape.
#
# Two kinds of row, and the difference is the whole design:
#
#   Derived rows (due, starting, overdue, digest) are a function of the current
#   issues and today's date. They are rebuilt from scratch on read, so moving a
#   due date moves its notification instead of leaving the old one behind.
#
#   Event rows (assigned) are not derivable. "This was assigned to Hermes" is
#   something that happened at a moment; the row afterwards only says who owns it
#   now, so nothing can reconstruct the event later. They are written when the
#   assignment happens and the reconciler never touches them.

_DERIVED_NOTE_KINDS = ("due", "starting", "overdue", "digest")

# Whole-day dates need a time before they can be a notification. These are UTC,
# like every other timestamp here; a client that wants 9am local can shift them,
# and it knows the user's timezone, which the server does not.
_NOTE_HOUR = "09:00:00"
_DIGEST_HOUR = "08:00:00"


def _note_id(kind, issue_id, fire_at):
    """A notification's id, derived from what it is about rather than random.

    This is what makes the reconciler idempotent: recomputing the same desired
    notification yields the same id, so INSERT OR IGNORE turns the second and
    every later pass into nothing, and an id that stops being computed is exactly
    the one to delete.
    """
    return "note_" + hashlib.sha1(f"{kind}|{issue_id}|{fire_at}".encode()).hexdigest()[:12]


def _desired_notifications(issues, today):
    """Pure: the notifications that should exist for this issue set on this day.

    No database, no clock — both are arguments — so it can be tested directly and
    run as many times as you like. `issues` is a list of dicts with at least id,
    status, archived, start_at and due_at.

    'assigned' is deliberately absent: see the note above. It cannot be recovered
    from the state of a row, so it is written where it happens instead.
    """
    today_iso = today.isoformat()
    wanted = []

    for issue in issues:
        # A finished or archived issue is not news. This is also what retires a
        # notification: the row stops being desired and the reconciler drops it.
        if issue.get("archived") or issue.get("status") == "done":
            continue
        start = (issue.get("start_at") or "").strip()
        due = (issue.get("due_at") or "").strip()
        if start:
            wanted.append({"kind": "starting", "issue_id": issue["id"],
                           "fire_at": f"{start}T{_NOTE_HOUR}"})
        if due:
            wanted.append({"kind": "due", "issue_id": issue["id"],
                           "fire_at": f"{due}T{_NOTE_HOUR}"})
            if due < today_iso:
                # Fired from the morning after the due date, not from today, so
                # the row stops moving once it exists. An overdue notification
                # re-dated to "today" every day would be a new id every day, and
                # the user would be told about the same lateness indefinitely.
                after = _parse_date(due)
                if after is not None:
                    nag = (after + timedelta(days=1)).isoformat()
                    wanted.append({"kind": "overdue", "issue_id": issue["id"],
                                   "fire_at": f"{nag}T{_NOTE_HOUR}"})

    # One digest a day, about the day rather than any one issue, so issue_id ''.
    wanted.append({"kind": "digest", "issue_id": "", "fire_at": f"{today_iso}T{_DIGEST_HOUR}"})

    for note in wanted:
        note["id"] = _note_id(note["kind"], note["issue_id"], note["fire_at"])
    return wanted


def _reconcile_notifications(db, today=None):
    """Make the derived notification rows match _desired_notifications.

    Recomputed on read rather than on write, on purpose. Most of what changes
    here changes with no write at all: an issue due tomorrow becomes overdue
    because a day passed, and a write-triggered rebuild would simply never
    produce that row. Rebuilding on write would also mean a fifty-row drag
    reorder doing fifty full rebuilds to reach the same answer. The cost is one
    scan of the issues table on a GET that was already asking about all of them.
    """
    ts = now()
    today = today or datetime.utcnow().date()
    issues = [dict(r) for r in db.execute(
        "SELECT id, status, archived, start_at, due_at FROM issues"
    ).fetchall()]
    wanted = _desired_notifications(issues, today)
    wanted_ids = {w["id"] for w in wanted}

    for note in wanted:
        db.execute(
            "INSERT OR IGNORE INTO notifications (id,issue_id,kind,fire_at,created_at,updated_at)"
            " VALUES (?,?,?,?,?,?)",
            (note["id"], note["issue_id"], note["kind"], note["fire_at"], ts, ts),
        )

    # Drop derived rows nobody wants any more — but only ones nobody has seen.
    # A delivered or dismissed row is a record of something the user was actually
    # told, and deleting it would let the same notification be told again the
    # moment the date drifted back.
    stale = [r["id"] for r in db.execute(
        "SELECT id FROM notifications"
        " WHERE kind IN (%s) AND delivered_at IS NULL AND dismissed_at IS NULL"
        % ",".join("?" for _ in _DERIVED_NOTE_KINDS),
        _DERIVED_NOTE_KINDS,
    ).fetchall() if r["id"] not in wanted_ids]
    for i in range(0, len(stale), 400):
        batch = stale[i:i + 400]
        db.execute("DELETE FROM notifications WHERE id IN (%s)" % ",".join("?" for _ in batch), batch)
    db.commit()


def _record_assignment(db, issue_id, assignee, ts):
    """Write the 'assigned' event row, if there is an assignee to name.

    Called from the write path because nothing downstream can reconstruct it; see
    the note at the top of this section. Unassigning is not an event worth waking
    a phone for, so an empty assignee writes nothing.
    """
    assignee = (assignee or "").strip()
    if not assignee:
        return
    nid = "note_" + hashlib.sha1(f"assigned|{issue_id}|{assignee}|{ts}".encode()).hexdigest()[:12]
    db.execute(
        "INSERT OR IGNORE INTO notifications (id,issue_id,kind,fire_at,created_at,updated_at)"
        " VALUES (?,?,?,?,?,?)",
        (nid, issue_id, "assigned", ts, ts, ts),
    )


@app.get("/api/notifications")
def list_notifications():
    db = get_db()
    # Reconciling here is why a GET writes. It is the only moment that knows both
    # the current issues and the current date; see _reconcile_notifications.
    _reconcile_notifications(db)

    query = ("SELECT n.*, i.title AS issue_title, i.status AS issue_status,"
             " i.priority AS issue_priority, i.project_id AS issue_project_id"
             " FROM notifications n LEFT JOIN issues i ON i.id = n.issue_id WHERE 1=1")
    params = []

    since = (request.args.get("since") or "").strip()
    if since:
        query += " AND n.fire_at >= ?"
        params.append(since)
    before = (request.args.get("before") or "").strip()
    if before:
        query += " AND n.fire_at <= ?"
        params.append(_day_bound(before, True))

    if (request.args.get("undelivered") or "").strip().lower() in ("true", "1"):
        # Dismissed counts as handled: the user said no, and asking again is how a
        # notification system teaches people to ignore it.
        query += " AND n.delivered_at IS NULL AND n.dismissed_at IS NULL"

    kinds = _multi("kind")
    if kinds:
        query += " AND n.kind IN (%s)" % ",".join("?" for _ in kinds)
        params.extend(kinds)

    query += " ORDER BY n.fire_at ASC, n.kind ASC"
    rows = db.execute(query, params).fetchall()
    return jsonify([row_to_dict(r) for r in rows])


@app.post("/api/notifications/<nid>/ack")
def ack_notification(nid):
    """Mark a notification shown, and optionally dismissed.

    COALESCE rather than a plain assignment, so a replayed ack — which the iOS
    queue will send whenever a response went missing — reports when the user was
    first told, not when the network recovered.
    """
    db = get_db()
    row = db.execute("SELECT id FROM notifications WHERE id=?", (nid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    data = request.get_json(silent=True) or {}
    ts = now()
    sets = ["delivered_at = COALESCE(delivered_at, ?)", "updated_at = ?"]
    params = [ts, ts]
    if data.get("dismissed"):
        sets.insert(1, "dismissed_at = COALESCE(dismissed_at, ?)")
        params.insert(1, ts)
    db.execute(f"UPDATE notifications SET {', '.join(sets)} WHERE id=?", (*params, nid))
    db.commit()
    row = db.execute("SELECT * FROM notifications WHERE id=?", (nid,)).fetchone()
    return jsonify(row_to_dict(row))


@app.get("/api/digest")
def digest():
    """What a daily summary would say, for one day.

    A read with no side effects — it does not reconcile. The digest answers "what
    does today look like", which is a question about issues; the notifications
    table answers "what should I interrupt you about", and a client asking the
    first should not silently rewrite the second.

    ?assignee= scopes "waiting on you" to one person ('none' for the unassigned
    pile, as everywhere else). Without it there is no "you" to be waiting on
    anyone, so that bucket comes back empty rather than guessing.
    """
    db = get_db()
    day = (request.args.get("date") or "").strip() or datetime.utcnow().date().isoformat()
    if _parse_date(day) is None:
        return jsonify({"error": "date must be yyyy-mm-dd"}), 400

    rows = db.execute("""
        SELECT i.*, m.name AS milestone_name, p.name AS project_name
        FROM issues i
        LEFT JOIN milestones m ON i.milestone_id = m.id
        LEFT JOIN projects p ON p.id = i.project_id
        WHERE i.archived = 0 AND i.status != 'done'
        ORDER BY i.due_at ASC, i.sort_order ASC
    """).fetchall()
    issues = [_issue_row_to_dict(r) for r in rows]

    def dated(field, op):
        out = []
        for issue in issues:
            value = (issue.get(field) or "").strip()
            if value and op(value):
                out.append(issue)
        return out

    due_today = dated("due_at", lambda v: v == day)
    starting_today = dated("start_at", lambda v: v == day)
    overdue = dated("due_at", lambda v: v < day)
    in_review = [i for i in issues if i["status"] == "review"]

    assignee = (request.args.get("assignee") or "").strip()
    waiting_on_you = []
    if assignee:
        want = "" if assignee.lower() == "none" else assignee
        # Everything already named above is today's work; this is the rest of the
        # plate, so the digest doesn't say the same issue three times.
        spoken_for = {i["id"] for i in due_today + starting_today + overdue + in_review}
        waiting_on_you = [i for i in issues
                          if (i.get("assignee") or "") == want
                          and i["status"] in ("todo", "in-progress")
                          and i["id"] not in spoken_for]

    return jsonify({
        "date": day,
        "assignee": assignee,
        "due_today": due_today,
        "starting_today": starting_today,
        "overdue": overdue,
        "in_review": in_review,
        "waiting_on_you": waiting_on_you,
        "counts": {
            "due_today": len(due_today),
            "starting_today": len(starting_today),
            "overdue": len(overdue),
            "in_review": len(in_review),
            "waiting_on_you": len(waiting_on_you),
        },
    })


# ---------------------------------------------------------------------------
# /api/overview
# ---------------------------------------------------------------------------

@app.get("/api/overview")
def overview():
    db = get_db()

    # Archived rows are hidden from every list view, so counting them here made the
    # overview disagree with the project cards and the project page progress bar.
    # The no-project bucket is excluded wherever a *project* is being counted or
    # listed (see list_projects); the issues inside it are counted normally.
    projects_active = db.execute(
        "SELECT COUNT(*) AS n FROM projects WHERE status='active' AND archived=0 AND id != ?",
        (NO_PROJECT_ID,),
    ).fetchone()["n"]

    issues_open = db.execute(
        "SELECT COUNT(*) AS n FROM issues WHERE status != 'done' AND archived=0"
    ).fetchone()["n"]

    issues_urgent = db.execute(
        "SELECT COUNT(*) AS n FROM issues WHERE priority='urgent' AND status != 'done' AND archived=0"
    ).fetchone()["n"]

    top_rows = db.execute("""
        SELECT p.id, p.name, COUNT(i.id) AS open_count
        FROM projects p
        LEFT JOIN issues i ON i.project_id = p.id AND i.status != 'done' AND i.archived = 0
        WHERE p.archived = 0 AND p.id != ?
        GROUP BY p.id
        ORDER BY open_count DESC
        LIMIT 5
    """, (NO_PROJECT_ID,)).fetchall()

    top_projects = [{"id": r["id"], "name": r["name"], "open_count": r["open_count"]} for r in top_rows]

    # Status histogram over everything not archived, done included — this is the
    # shape of the whole board, not a count of what is left.
    #
    # Keyed by the status value itself, so 'in-progress' rather than the
    # 'in_progress' that _project_with_counts emits. The two answer different
    # questions and no client reads both, and this form lets a caller index the
    # histogram with an issue's own status string. The five keys are always
    # present, so a client never has to guess whether a missing key means zero;
    # a row carrying some sixth status is not in the vocabulary and is left out
    # rather than changing the shape of the response.
    counted = {r["status"]: r["n"] for r in db.execute(
        "SELECT status, COUNT(*) AS n FROM issues WHERE archived=0 GROUP BY status"
    ).fetchall()}
    status_counts = {st: counted.get(st, 0)
                     for st in ("backlog", "todo", "in-progress", "review", "done")}

    # Open issues per assignee, the unassigned pile included rather than dropped:
    # "who has what" with a silent hole in it is the wrong answer. That pile is
    # '' (issues.assignee stores '' not NULL), which is the same bucket
    # /api/issues?assignee=none selects, so a caller can hand the value it reads
    # here straight back as a filter.
    assignee_rows = db.execute("""
        SELECT COALESCE(assignee, '') AS assignee, COUNT(*) AS n
        FROM issues
        WHERE status != 'done' AND archived = 0
        GROUP BY COALESCE(assignee, '')
        ORDER BY n DESC, assignee COLLATE NOCASE ASC
    """).fetchall()
    assignee_counts = [{"assignee": r["assignee"], "open_count": r["n"]} for r in assignee_rows]

    # Milestone progress. Archived issues leave both halves of the fraction: in
    # the total but not the numerator, an archived unfinished issue would keep a
    # finished milestone reading as incomplete forever. Milestones on archived
    # projects are dropped whole, the way top_projects drops the projects.
    # Undated milestones sort last rather than first, matching the milestone_due
    # issue sort — no due date is not the most urgent thing on the list.
    ms_rows = db.execute("""
        SELECT m.id, m.name, m.due_date,
               p.id AS project_id, p.name AS project_name,
               SUM(CASE WHEN i.status = 'done' THEN 1 ELSE 0 END) AS done_count,
               COUNT(i.id) AS total_count
        FROM milestones m
        JOIN projects p ON p.id = m.project_id
        LEFT JOIN issues i ON i.milestone_id = m.id AND i.archived = 0
        WHERE p.archived = 0
        GROUP BY m.id
        ORDER BY CASE WHEN m.due_date IS NULL OR m.due_date = '' THEN 1 ELSE 0 END ASC,
                 m.due_date ASC, m.name COLLATE NOCASE ASC
    """).fetchall()
    milestone_progress = [{
        "id":           r["id"],
        "name":         r["name"],
        "project_id":   r["project_id"],
        "project_name": r["project_name"],
        "due_date":     r["due_date"],
        "done":         r["done_count"] or 0,
        "total":        r["total_count"] or 0,
    } for r in ms_rows]

    # "This week" is the last seven days, not the calendar week: the question is
    # "have I been moving", and a Monday morning should not answer it with zero.
    #
    # updated_at is the only timestamp on the row, so this really means "finished
    # and last touched within the week" — an issue closed last month and edited
    # today is counted. Answering it exactly needs a completed_at column, which
    # could be added but not back-filled, so everything already done would read
    # as never done. The approximation is the honest one until there is a reason
    # to start recording it.
    #
    # The one place archived rows are not simply excluded, and the exception has
    # a reason: a completed recurring occurrence is archived by the server, not
    # by the user, because its replacement has already taken its place on the
    # board. Counting only unarchived rows would mean every chore you actually
    # did this week — the bins, the plants — was invisible in the one number
    # that asks whether you did anything. So an archived row still counts when
    # it carries a recurrence, and not otherwise.
    week_ago = (datetime.utcnow() - timedelta(days=7)).isoformat()
    done_this_week = db.execute(
        "SELECT COUNT(*) AS n FROM issues WHERE status='done' AND updated_at >= ?"
        " AND (archived=0 OR (recurrence IS NOT NULL AND recurrence != ''))",
        (week_ago,),
    ).fetchone()["n"]

    return jsonify({
        # These four are the original payload and are read by shipped clients;
        # their names and meanings are fixed. Everything below is additive.
        "projects_active": projects_active,
        "issues_open": issues_open,
        "issues_urgent": issues_urgent,
        "top_projects": top_projects,
        "status_counts": status_counts,
        "assignee_counts": assignee_counts,
        "milestone_progress": milestone_progress,
        "done_this_week": done_this_week,
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Static web frontend — served at /
# ---------------------------------------------------------------------------

@app.get("/")
def serve_index():
    # Today answers "what needs me" — the project grid is one tab away.
    return send_from_directory(WEB_DIR, "today.html")


@app.get("/<path:filename>")
def serve_static(filename):
    # Don't intercept /api/* routes
    if filename.startswith("api/"):
        from flask import abort
        abort(404)
    return send_from_directory(WEB_DIR, filename)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # init_db()/_migrate_db() now run at import time (see above) so that systemd and
    # any WSGI entry point migrate too; only the dev server lives here.
    import ssl
    cert = "/home/dcb/nanoclaw/groups/telegram_main/feed/cert.pem"
    key  = "/home/dcb/nanoclaw/groups/telegram_main/feed/cert-key.pem"
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    app.run(host="0.0.0.0", port=8911, ssl_context=ctx, debug=False)

