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

DB_PATH = "/home/dcb/graft/graft.db"
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
            colour      TEXT DEFAULT '#6366f1',
            icon        TEXT DEFAULT '',
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
            created_at   TEXT NOT NULL,
            updated_at   TEXT NOT NULL
        );
    """)
    db.commit()
    db.close()


def _migrate_db():
    """Add columns that didn't exist in earlier schema versions."""
    db = sqlite3.connect(DB_PATH)
    cols = {r[1] for r in db.execute("PRAGMA table_info(projects)")}
    if "icon" not in cols:
        db.execute("ALTER TABLE projects ADD COLUMN icon TEXT DEFAULT ''")
        db.commit()
    db.close()


def now():
    return datetime.utcnow().isoformat()


def row_to_dict(row):
    return dict(row)


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
    counts = db.execute("""
        SELECT
            SUM(CASE WHEN status='backlog'     THEN 1 ELSE 0 END) AS backlog,
            SUM(CASE WHEN status='todo'        THEN 1 ELSE 0 END) AS todo,
            SUM(CASE WHEN status='in-progress' THEN 1 ELSE 0 END) AS in_progress,
            SUM(CASE WHEN status='review'      THEN 1 ELSE 0 END) AS review,
            SUM(CASE WHEN status='done'        THEN 1 ELSE 0 END) AS done,
            COUNT(*)                                               AS total
        FROM issues WHERE project_id = ?
    """, (p["id"],)).fetchone()
    p["issue_counts"] = {
        "backlog":     counts["backlog"] or 0,
        "todo":        counts["todo"] or 0,
        "in_progress": counts["in_progress"] or 0,
        "review":      counts["review"] or 0,
        "done":        counts["done"] or 0,
        "total":       counts["total"] or 0,
    }
    return p


@app.get("/api/projects")
def list_projects():
    db = get_db()
    rows = db.execute("SELECT * FROM projects ORDER BY created_at ASC").fetchall()
    return jsonify([_project_with_counts(db, r) for r in rows])


@app.post("/api/projects")
def create_project():
    data = request.get_json(force=True)
    pid = "proj_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    db.execute(
        "INSERT INTO projects (id,name,description,status,colour,icon,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
        (
            pid,
            data.get("name", "Untitled"),
            data.get("description", ""),
            data.get("status", "active"),
            data.get("colour", "#6366f1"),
            data.get("icon", ""),
            ts, ts,
        ),
    )
    db.commit()
    row = db.execute("SELECT * FROM projects WHERE id=?", (pid,)).fetchone()
    return jsonify(_project_with_counts(db, row)), 201


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
    fields = ["name", "description", "status", "colour", "icon"]
    updates = {f: data[f] for f in fields if f in data}
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
    mid = "ms_" + str(uuid4())[:8]
    ts = now()
    db = get_db()
    db.execute(
        "INSERT INTO milestones (id,project_id,name,description,due_date,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
        (
            mid,
            data["project_id"],
            data.get("name", "Untitled"),
            data.get("description", ""),
            data.get("due_date"),
            ts, ts,
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


@app.get("/api/issues")
def list_issues():
    db = get_db()
    query = "SELECT i.*, m.name AS milestone_name FROM issues i LEFT JOIN milestones m ON i.milestone_id = m.id WHERE 1=1"
    params = []

    project_id = request.args.get("project_id")
    if project_id:
        query += " AND i.project_id=?"
        params.append(project_id)

    milestone_id = request.args.get("milestone_id")
    if milestone_id is not None:
        if milestone_id.lower() == "none":
            query += " AND i.milestone_id IS NULL"
        else:
            query += " AND i.milestone_id=?"
            params.append(milestone_id)

    status = request.args.get("status")
    if status:
        query += " AND i.status=?"
        params.append(status)

    priority = request.args.get("priority")
    if priority:
        query += " AND i.priority=?"
        params.append(priority)

    assignee = request.args.get("assignee")
    if assignee:
        query += " AND i.assignee=?"
        params.append(assignee)

    query += " ORDER BY i.sort_order ASC, i.created_at ASC"
    rows = db.execute(query, params).fetchall()
    return jsonify([_issue_row_to_dict(r) for r in rows])


@app.post("/api/issues")
def create_issue():
    data = request.get_json(force=True)
    iid = "iss_" + str(uuid4())[:8]
    ts = now()
    labels = json.dumps(data.get("labels", []))
    db = get_db()
    db.execute(
        """INSERT INTO issues
           (id,project_id,milestone_id,title,description,status,priority,labels,assignee,sort_order,created_at,updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            iid,
            data["project_id"],
            data.get("milestone_id"),
            data.get("title", "Untitled"),
            data.get("description", ""),
            data.get("status", "backlog"),
            data.get("priority", "normal"),
            labels,
            data.get("assignee", ""),
            data.get("sort_order", 0),
            ts, ts,
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
    fields = ["title", "description", "status", "priority", "assignee", "milestone_id", "sort_order"]
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


@app.patch("/api/issues/reorder")
def reorder_issues():
    data = request.get_json(force=True)
    db = get_db()
    ts = now()
    for item in data.get("issues", []):
        db.execute(
            "UPDATE issues SET sort_order=?, updated_at=? WHERE id=?",
            (item["sort_order"], ts, item["id"]),
        )
    db.commit()
    return jsonify({"updated": len(data.get("issues", []))})


# ---------------------------------------------------------------------------
# /api/overview
# ---------------------------------------------------------------------------

@app.get("/api/overview")
def overview():
    db = get_db()

    projects_active = db.execute(
        "SELECT COUNT(*) AS n FROM projects WHERE status='active'"
    ).fetchone()["n"]

    issues_open = db.execute(
        "SELECT COUNT(*) AS n FROM issues WHERE status != 'done'"
    ).fetchone()["n"]

    issues_urgent = db.execute(
        "SELECT COUNT(*) AS n FROM issues WHERE priority='urgent' AND status != 'done'"
    ).fetchone()["n"]

    top_rows = db.execute("""
        SELECT p.id, p.name, COUNT(i.id) AS open_count
        FROM projects p
        LEFT JOIN issues i ON i.project_id = p.id AND i.status != 'done'
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
    return send_from_directory(WEB_DIR, "index.html")


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
    init_db()
    _migrate_db()
    app.run(host="0.0.0.0", port=8911, debug=False)

