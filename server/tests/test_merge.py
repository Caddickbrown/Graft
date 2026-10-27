"""Tests for POST /api/merge, a phone-only library joining a server.

Run from the repository root:

    python -m unittest discover -s server/tests

Every test runs against a throwaway database in a temporary directory. app.py
reads GRAFT_DB at import time and runs its migrations there, so the variable is
set before the import, and the import is refused outright if it would land
anywhere else — the default path is the live library on the Pi.
"""

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="graft-test-")
os.environ["GRAFT_DB"] = os.path.join(_TMP, "graft.db")

_db_path = Path(os.environ["GRAFT_DB"]).resolve()
if Path(tempfile.gettempdir()).resolve() not in _db_path.parents:
    raise SystemExit(f"refusing to run: GRAFT_DB points at {_db_path}, not a temporary file")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import app as graft  # noqa: E402

assert Path(graft.DB_PATH).resolve() == _db_path, "app.py did not pick up the throwaway database"


def _reset():
    """Empty every table the merge touches, then put proj_none back."""
    db = sqlite3.connect(graft.DB_PATH)
    for table in ("links", "issues", "milestones", "views", "projects", "areas", "id_aliases"):
        db.execute(f"DELETE FROM {table}")
    db.commit()
    db.close()
    graft._ensure_no_project()


def _snapshot():
    """Every row of every merged table, by table, as plain dicts."""
    db = sqlite3.connect(graft.DB_PATH)
    db.row_factory = sqlite3.Row
    out = {}
    for table in ("areas", "projects", "milestones", "issues", "links", "views"):
        out[table] = {r["id"]: dict(r) for r in db.execute(f"SELECT * FROM {table}")}
    db.close()
    return out


def _project(pid, name, created="2026-01-01T00:00:00", updated="2026-01-01T00:00:00", **extra):
    return {"id": pid, "name": name, "description": "", "status": "active", "colour": "#7C7FC4",
            "icon": "", "area_id": "", "tags": [], "archived": False,
            "created_at": created, "updated_at": updated, **extra}


def _issue(iid, project_id, title, created="2026-01-02T00:00:00", updated="2026-01-02T00:00:00", **extra):
    return {"id": iid, "project_id": project_id, "milestone_id": None, "title": title,
            "description": "", "status": "todo", "priority": "normal", "labels": [],
            "assignee": "", "start_at": "", "due_at": "", "recurrence": "",
            "recurrence_anchor": "schedule", "recurrence_parent": "", "sort_order": 0,
            "archived": False, "created_at": created, "updated_at": updated, **extra}


class MergeTests(unittest.TestCase):

    def setUp(self):
        _reset()
        self.client = graft.app.test_client()

    def post(self, path, body):
        return self.client.post(path, data=json.dumps(body), content_type="application/json")

    def merge(self, library, decisions=None, apply=False):
        body = {"library": library}
        if decisions is not None:
            body["decisions"] = decisions
        return self.post("/api/merge" + ("?apply=1" if apply else ""), body)

    def seed_project(self, pid, name, created="2025-06-01T00:00:00", updated="2025-06-01T00:00:00"):
        r = self.post("/api/projects", _project(pid, name, created, updated))
        self.assertEqual(r.status_code, 201)

    def seed_issue(self, iid, pid, title, created="2025-06-02T00:00:00", updated="2025-06-02T00:00:00"):
        r = self.post("/api/issues", _issue(iid, pid, title, created, updated))
        self.assertEqual(r.status_code, 201)

    # -- the dry run --------------------------------------------------------

    def test_dry_run_writes_nothing(self):
        before = _snapshot()
        r = self.merge({"projects": [_project("proj_aaaa1111", "Garden")]})
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.get_json()["applied"])
        self.assertEqual(r.get_json()["creates"][0]["server_id"], "proj_aaaa1111")
        self.assertEqual(_snapshot(), before)

    # -- an empty server ------------------------------------------------------

    def test_empty_server_is_a_plain_upload(self):
        library = {
            "areas": [{"id": "area_aaaa1111", "name": "Home", "colour": "", "sort_order": 0}],
            "projects": [_project("proj_aaaa1111", "Garden", area_id="area_aaaa1111")],
            "milestones": [{"id": "ms_aaaa1111", "project_id": "proj_aaaa1111", "name": "Spring",
                            "description": "", "due_date": None, "sort_order": 0,
                            "created_at": "2026-01-01T00:00:00", "updated_at": "2026-01-01T00:00:00"}],
            "issues": [_issue("iss_aaaa1111", "proj_aaaa1111", "Dig the beds", milestone_id="ms_aaaa1111")],
            "links": [{"id": "link_aaaa1111", "owner_type": "issue", "owner_id": "iss_aaaa1111",
                       "project_id": "", "label": "Guide", "url": "https://example.com/beds",
                       "kind": "link", "sort_order": 0}],
            "views": [{"id": "view_aaaa1111", "name": "Outdoors", "query": '{"q":"dig"}', "sort_order": 0}],
        }
        r = self.merge(library, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        plan = r.get_json()
        self.assertTrue(plan["applied"])
        self.assertEqual(plan["lookalikes"], [])
        self.assertEqual(plan["collisions"], [])
        self.assertEqual(len(plan["creates"]), 6)

        after = _snapshot()
        self.assertEqual(after["projects"]["proj_aaaa1111"]["area_id"], "area_aaaa1111")
        self.assertEqual(after["projects"]["proj_aaaa1111"]["created_at"], "2026-01-01T00:00:00")
        self.assertEqual(after["issues"]["iss_aaaa1111"]["milestone_id"], "ms_aaaa1111")
        self.assertEqual(after["links"]["link_aaaa1111"]["owner_id"], "iss_aaaa1111")
        self.assertIn("view_aaaa1111", after["views"])
        self.assertIn(graft.NO_PROJECT_ID, after["projects"])

    # -- exact matches ---------------------------------------------------------

    def test_same_id_same_created_at_newer_phone_wins(self):
        self.seed_project("proj_bbbb2222", "Garden", created="2026-01-01T00:00:00",
                          updated="2026-01-05T00:00:00")
        self.seed_issue("iss_bbbb2222", "proj_bbbb2222", "Old title",
                        created="2026-01-02T00:00:00", updated="2026-01-05T00:00:00")
        library = {
            "projects": [_project("proj_bbbb2222", "Garden (phone)", created="2026-01-01T00:00:00",
                                  updated="2026-01-09T00:00:00")],
            "issues": [_issue("iss_bbbb2222", "proj_bbbb2222", "Phone title",
                              created="2026-01-02T00:00:00", updated="2026-01-03T00:00:00")],
        }
        r = self.merge(library, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        plan = r.get_json()
        self.assertEqual({e["reason"] for e in plan["exact"]}, {"same_id"})
        self.assertEqual(plan["updates"], [{"kind": "projects", "server_id": "proj_bbbb2222"}])

        after = _snapshot()
        # The phone's project is newer and wins; the server's issue is newer and stays.
        self.assertEqual(after["projects"]["proj_bbbb2222"]["name"], "Garden (phone)")
        self.assertEqual(after["issues"]["iss_bbbb2222"]["title"], "Old title")

    def test_area_merges_by_name(self):
        self.post("/api/areas", {"id": "area_server01", "name": "Work"})
        library = {
            "areas": [{"id": "area_phone001", "name": " work ", "colour": "", "sort_order": 0}],
            "projects": [_project("proj_cccc3333", "Payroll", area_id="area_phone001")],
        }
        r = self.merge(library, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        after = _snapshot()
        self.assertNotIn("area_phone001", after["areas"])
        self.assertEqual(after["projects"]["proj_cccc3333"]["area_id"], "area_server01")

    # -- collisions ------------------------------------------------------------

    def test_id_collision_is_rekeyed_with_references(self):
        self.seed_project("proj_dddd4444", "Server's own", created="2025-01-01T00:00:00")
        library = {
            "projects": [_project("proj_dddd4444", "Phone's own", created="2026-03-03T00:00:00")],
            "issues": [_issue("iss_dddd4444", "proj_dddd4444", "Belongs to the phone's project")],
        }
        dry = self.merge(library).get_json()
        self.assertEqual(len(dry["collisions"]), 1)
        new_id = dry["collisions"][0]["server_id"]
        self.assertNotEqual(new_id, "proj_dddd4444")
        self.assertTrue(new_id.startswith("proj_"))

        r = self.merge(library, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        plan = r.get_json()
        # The dry run named the id the apply used.
        self.assertEqual(plan["remap"]["proj_dddd4444"], new_id)

        after = _snapshot()
        self.assertEqual(after["projects"]["proj_dddd4444"]["name"], "Server's own")
        self.assertEqual(after["projects"][new_id]["name"], "Phone's own")
        self.assertEqual(after["issues"]["iss_dddd4444"]["project_id"], new_id)

    # -- lookalikes ------------------------------------------------------------

    def test_project_lookalike_is_held_until_decided(self):
        self.seed_project("proj_server01", "Home")
        library = {
            "projects": [_project("proj_phone001", "home")],
            "issues": [_issue("iss_phone001", "proj_phone001", "Fix the gate")],
        }
        before = _snapshot()

        dry = self.merge(library).get_json()
        self.assertEqual(dry["undecided"], ["proj_phone001"])
        self.assertEqual(dry["lookalikes"][0]["server_id"], "proj_server01")

        held = self.merge(library, apply=True)
        self.assertEqual(held.status_code, 409)
        self.assertEqual(_snapshot(), before)

        r = self.merge(library, decisions={"proj_phone001": "merge"}, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        after = _snapshot()
        self.assertNotIn("proj_phone001", after["projects"])
        self.assertEqual(after["issues"]["iss_phone001"]["project_id"], "proj_server01")

    def test_project_lookalike_kept_apart(self):
        self.seed_project("proj_server01", "Home")
        library = {"projects": [_project("proj_phone001", "Home")]}
        r = self.merge(library, decisions={"proj_phone001": "keep"}, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        after = _snapshot()
        self.assertIn("proj_phone001", after["projects"])
        self.assertIn("proj_server01", after["projects"])

    def test_issue_lookalike_in_a_shared_project_defaults_to_keep(self):
        self.seed_project("proj_server01", "Home")
        self.seed_issue("iss_server01", "proj_server01", "Renew passport")
        library = {
            "projects": [_project("proj_phone001", "Home")],
            "issues": [_issue("iss_phone001", "proj_phone001", "renew passport ")],
        }
        dry = self.merge(library, decisions={"proj_phone001": "merge"}).get_json()
        kinds = {(e["kind"], e["default"]) for e in dry["lookalikes"]}
        self.assertIn(("issues", "keep"), kinds)
        self.assertEqual(dry["undecided"], [])

        r = self.merge(library, decisions={"proj_phone001": "merge"}, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())
        after = _snapshot()
        self.assertIn("iss_phone001", after["issues"])
        self.assertIn("iss_server01", after["issues"])

    # -- the guarantees --------------------------------------------------------

    def test_nothing_is_ever_deleted(self):
        self.post("/api/areas", {"id": "area_server01", "name": "Work"})
        self.seed_project("proj_server01", "Home")
        self.seed_project("proj_server02", "Taxes", created="2025-02-01T00:00:00")
        self.seed_issue("iss_server01", "proj_server01", "Renew passport")
        self.post("/api/views", {"id": "view_server01", "name": "Mine", "query": {"q": "x"}})
        before = _snapshot()

        library = {
            "areas": [{"id": "area_server01", "name": "Something else", "colour": "", "sort_order": 0}],
            "projects": [
                _project("proj_server01", "Home"),                                 # lookalike? no: same id, new created_at
                _project("proj_server02", "Taxes", created="2025-02-01T00:00:00",
                         updated="2020-01-01T00:00:00"),                           # exact, server newer
                _project("proj_phone001", "home"),                                 # lookalike
            ],
            "issues": [_issue("iss_server01", "proj_phone001", "Renew passport")],
            "views": [{"id": "view_phone001", "name": "Mine", "query": '{"q":"y"}', "sort_order": 0}],
        }
        decisions = {"proj_server01": "keep", "proj_phone001": "merge", "view_phone001": "keep"}
        r = self.merge(library, decisions=decisions, apply=True)
        self.assertEqual(r.status_code, 200, r.get_json())

        after = _snapshot()
        for table, rows in before.items():
            for rid, row in rows.items():
                self.assertIn(rid, after[table], f"{table} {rid} was deleted")
        self.assertEqual(after["projects"]["proj_server02"]["updated_at"], "2025-06-01T00:00:00")
        self.assertEqual(after["areas"]["area_server01"]["name"], "Work")
        self.assertEqual(after["issues"]["iss_server01"]["title"], "Renew passport")

    def test_replaying_an_apply_writes_nothing(self):
        self.seed_project("proj_server01", "Home")
        self.seed_project("proj_dddd4444", "Server's own", created="2025-01-01T00:00:00")
        library = {
            "areas": [{"id": "area_phone001", "name": "Home life", "colour": "", "sort_order": 0}],
            "projects": [
                _project("proj_phone001", "Home"),
                _project("proj_dddd4444", "Phone's own", created="2026-03-03T00:00:00"),
                _project("proj_phone002", "Garden", area_id="area_phone001"),
            ],
            "issues": [_issue("iss_phone001", "proj_dddd4444", "Collided parent")],
            "links": [{"id": "link_phone001", "owner_type": "project", "owner_id": "proj_phone002",
                       "project_id": "proj_phone002", "label": "Seeds", "url": "https://example.com",
                       "kind": "link", "sort_order": 0}],
        }
        decisions = {"proj_phone001": "merge"}
        first = self.merge(library, decisions=decisions, apply=True)
        self.assertEqual(first.status_code, 200, first.get_json())
        once = _snapshot()

        again = self.merge(library, decisions=decisions, apply=True)
        self.assertEqual(again.status_code, 200, again.get_json())
        self.assertEqual(again.get_json()["creates"], [])
        self.assertEqual(again.get_json()["remap"], first.get_json()["remap"])
        self.assertEqual(_snapshot(), once)

    def test_rejects_a_body_without_a_library(self):
        self.assertEqual(self.post("/api/merge", {"projects": []}).status_code, 400)


if __name__ == "__main__":
    unittest.main()
