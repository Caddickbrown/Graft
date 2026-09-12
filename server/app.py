"""
Graft — Project Tracker Backend
Flask + SQLite, port 8911
"""

import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path
from uuid import uuid4

from flask import Flask, g, jsonify, request, send_from_directory

DB_PATH = os.environ.get("GRAFT_DB", "/home/dcb/graft/graft.db")
WEB_DIR = Path(__file__).parent.parent / "web"

app = Flask(__name__, static_folder=None)


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

        CREATE TABLE IF NOT EXISTS links (
            id          TEXT PRIMARY KEY,
            project_id  TEXT NOT NULL,          -- no FK: see note above
            label       TEXT NOT NULL,
            url         TEXT NOT NULL,
            kind        TEXT DEFAULT 'link',    -- github|docs|design|deploy|link
            sort_order  INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
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
        # No FOREIGN KEY on area_id, on purpose — see the note in init_db().
        # '' means "No area", which is also what a deleted area leaves behind.
        if "area_id" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN area_id TEXT DEFAULT ''")
        # tags: JSON array of strings, free-text with autocomplete.
        if "tags" not in proj_cols:
            db.execute("ALTER TABLE projects ADD COLUMN tags TEXT DEFAULT '[]'")
        db.commit()
    except sqlite3.OperationalError as exc:
        if "duplicate column name" not in str(exc):
            raise
    finally:
        db.close()
    _backfill_repo_links()
    _remap_project_colours()


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
                db.execute(
                    "INSERT INTO links (id,project_id,label,url,kind,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                    ("link_" + str(uuid4())[:8], pid, "Repo", repo_url, "github", 0, ts, ts),
                )
            db.execute("UPDATE projects SET repo_url='' WHERE id=?", (pid,))
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
    fields = ["name", "colour", "sort_order"]
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

@app.get("/api/links")
def list_links():
    db = get_db()
    project_id = request.args.get("project_id")
    if project_id:
        rows = db.execute(
            "SELECT * FROM links WHERE project_id=? ORDER BY sort_order ASC, created_at ASC",
            (project_id,),
        ).fetchall()
    else:
        rows = db.execute(
            "SELECT * FROM links ORDER BY sort_order ASC, created_at ASC"
        ).fetchall()
    return jsonify([row_to_dict(r) for r in rows])


@app.post("/api/links")
def create_link():
    data = request.get_json(force=True)
    project_id, err = _required_id(data, "project_id")
    if err:
        return err
    label, err = _required_id(data, "label")
    if err:
        return err
    url, err = _required_id(data, "url")
    if err:
        return err
    lid = data.get("id") or "link_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    # links.project_id carries no FOREIGN KEY (see init_db), so nothing in the
    # engine would reject an unknown parent — check it here so the client gets a
    # 404 instead of a row pointing at nothing.
    err = _project_exists(db, project_id)
    if err:
        return err
    # See create_project: a replayed create must not reset created_at.
    existing = db.execute("SELECT created_at FROM links WHERE id=?", (lid,)).fetchone()
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        "INSERT OR REPLACE INTO links (id,project_id,label,url,kind,sort_order,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
        (
            lid,
            project_id,
            label,
            url,
            data.get("kind", "link"),
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
    fields = ["label", "url", "kind", "sort_order"]
    updates = {f: data[f] for f in fields if f in data}
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

    query += " ORDER BY " + _issue_order_by()
    rows = db.execute(query, params).fetchall()
    return jsonify([_issue_row_to_dict(r) for r in rows])


@app.post("/api/issues")
def create_issue():
    data = request.get_json(force=True)
    project_id, err = _required_id(data, "project_id")
    if err:
        return err
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
    existing = db.execute("SELECT archived, created_at FROM issues WHERE id=?", (iid,)).fetchone()
    archived = data.get("archived", existing["archived"] if existing else 0)
    created_at = data.get("created_at") or (existing["created_at"] if existing else ts)
    updated_at = data.get("updated_at") or ts
    db.execute(
        """INSERT OR REPLACE INTO issues
           (id,project_id,milestone_id,title,description,status,priority,labels,assignee,sort_order,archived,created_at,updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
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
            data.get("sort_order", 0),
            archived, created_at, updated_at,
        ),
    )
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
    fields = ["title", "description", "status", "priority", "assignee", "milestone_id", "sort_order", "archived"]
    updates = {f: data[f] for f in fields if f in data}
    if "labels" in data:
        updates["labels"] = json.dumps(data["labels"])
    updates["updated_at"] = now()
    set_clause = ", ".join(f"{k}=?" for k in updates)
    db.execute(f"UPDATE issues SET {set_clause} WHERE id=?", (*updates.values(), iid))
    db.commit()
    row = db.execute(
        "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE i.id=?",
        (iid,),
    ).fetchone()
    return jsonify(_issue_row_to_dict(row))


@app.delete("/api/issues/<iid>")
def delete_issue(iid):
    db = get_db()
    row = db.execute("SELECT id FROM issues WHERE id=?", (iid,)).fetchone()
    if row is None:
        return jsonify({"error": "not found"}), 404
    db.execute("DELETE FROM issues WHERE id=?", (iid,))
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
# /api/overview
# ---------------------------------------------------------------------------

@app.get("/api/overview")
def overview():
    db = get_db()

    # Archived rows are hidden from every list view, so counting them here made the
    # overview disagree with the project cards and the project page progress bar.
    projects_active = db.execute(
        "SELECT COUNT(*) AS n FROM projects WHERE status='active' AND archived=0"
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
        WHERE p.archived = 0
        GROUP BY p.id
        ORDER BY open_count DESC
        LIMIT 5
    """).fetchall()

    top_projects = [{"id": r["id"], "name": r["name"], "open_count": r["open_count"]} for r in top_rows]

    return jsonify({
        "projects_active": projects_active,
        "issues_open": issues_open,
        "issues_urgent": issues_urgent,
        "top_projects": top_projects,
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

