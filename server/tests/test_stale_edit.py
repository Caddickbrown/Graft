"""Tests for _ts on PUT /api/issues/<id>, which refuses an edit older than the row.

Run from the repository root:

    python -m unittest discover -s server/tests

Every test runs against a throwaway database in a temporary directory, as in
test_merge.py. When that module has already imported app.py in this process,
its throwaway database is reused rather than a second one created — app.py
reads GRAFT_DB once, at import — and the guard below checks it all the same.
"""

import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

if "app" not in sys.modules:
    _TMP = tempfile.mkdtemp(prefix="graft-test-")
    os.environ["GRAFT_DB"] = os.path.join(_TMP, "graft.db")

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import app as graft  # noqa: E402

_db_path = Path(graft.DB_PATH).resolve()
if Path(tempfile.gettempdir()).resolve() not in _db_path.parents:
    raise SystemExit(f"refusing to run: app.py is using {_db_path}, not a temporary file")

IID = "iss_stale001"


def _set_updated_at(value):
    db = sqlite3.connect(graft.DB_PATH)
    db.execute("UPDATE issues SET updated_at=? WHERE id=?", (value, IID))
    db.commit()
    db.close()


def _row():
    db = sqlite3.connect(graft.DB_PATH)
    db.row_factory = sqlite3.Row
    row = dict(db.execute("SELECT * FROM issues WHERE id=?", (IID,)).fetchone())
    db.close()
    return row


class StaleEditTests(unittest.TestCase):

    def setUp(self):
        db = sqlite3.connect(graft.DB_PATH)
        db.execute("DELETE FROM issues")
        db.commit()
        db.close()
        graft._ensure_no_project()
        self.client = graft.app.test_client()
        r = self.client.post("/api/issues", data=json.dumps({
            "id": IID, "project_id": graft.NO_PROJECT_ID, "title": "Water the plants",
            "status": "todo", "priority": "normal",
        }), content_type="application/json")
        self.assertEqual(r.status_code, 201, r.get_json())
        # What now() writes: naive UTC with microseconds.
        _set_updated_at("2026-01-10T16:30:00.123456")

    def put(self, body):
        return self.client.put(f"/api/issues/{IID}", data=json.dumps(body),
                               content_type="application/json")

    def test_newer_row_refuses_the_edit(self):
        before = _row()
        r = self.put({"status": "done", "title": "Renamed", "_ts": "2026-01-10T16:20:47Z"})
        self.assertEqual(r.status_code, 409, r.get_json())
        body = r.get_json()
        self.assertEqual(body["error"], "This issue changed after that edit was made")
        self.assertEqual(body["issue"]["id"], IID)
        self.assertEqual(body["issue"]["status"], "todo")
        self.assertEqual(body["issue"]["title"], "Water the plants")
        self.assertEqual(_row(), before)

    def test_offset_is_compared_as_utc(self):
        # 17:20 at +01:00 is 16:20 UTC, ten minutes before the row changed.
        r = self.put({"status": "done", "_ts": "2026-01-10T17:20:47+01:00"})
        self.assertEqual(r.status_code, 409, r.get_json())
        self.assertEqual(_row()["status"], "todo")

    def test_older_row_takes_the_edit(self):
        r = self.put({"status": "done", "priority": "high", "_ts": "2026-01-10T16:40:00Z"})
        self.assertEqual(r.status_code, 200, r.get_json())
        row = _row()
        self.assertEqual(row["status"], "done")
        self.assertEqual(row["priority"], "high")
        self.assertNotIn("_ts", row)
        self.assertGreater(row["updated_at"], "2026-01-10T16:30:00.123456")

    def test_naive_ts_means_utc(self):
        r = self.put({"title": "Naive", "_ts": "2026-01-10T16:40:00"})
        self.assertEqual(r.status_code, 200, r.get_json())
        self.assertEqual(_row()["title"], "Naive")

    def test_without_ts_the_edit_applies(self):
        _set_updated_at("2099-01-01T00:00:00.000000")
        r = self.put({"status": "in_progress"})
        self.assertEqual(r.status_code, 200, r.get_json())
        self.assertEqual(_row()["status"], "in_progress")

    def test_garbage_ts_is_a_400(self):
        before = _row()
        for bad in ("yesterday", "", 1730132447, None):
            r = self.put({"status": "done", "_ts": bad})
            self.assertEqual(r.status_code, 400, (bad, r.get_json()))
        self.assertEqual(_row(), before)


if __name__ == "__main__":
    unittest.main()
