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
| GET | /api/issues?project_id=&milestone_id=&status=&priority=&assignee= | Issues with filters |
| POST/PUT/DELETE | /api/issues/:id | Issue CRUD |
| PATCH | /api/issues/reorder | Batch sort_order update |
| GET | /api/overview | Hub card data |
| GET | /api/health | Health check |
