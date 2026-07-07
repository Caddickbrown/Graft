/* Graft — app.js */
(function () {
  'use strict';

  const API = window.GRAFT_API || 'http://raspberrypi.local:8911';

  // ── Core API ────────────────────────────────────────────────────
  async function api(method, path, body) {
    const opts = { method, headers: { 'Content-Type': 'application/json' } };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const r = await fetch(API + path, opts);
    if (!r.ok) throw new Error(`${method} ${path} → ${r.status}`);
    if (r.status === 204) return null;
    return r.json();
  }

  // ── Toast ───────────────────────────────────────────────────────
  function toast(msg, duration = 2200) {
    const el = document.getElementById('toast');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), duration);
  }

  // ── Modal helpers ───────────────────────────────────────────────
  function openModal(id) {
    document.getElementById(id).style.display = 'flex';
    document.body.style.overflow = 'hidden';
  }
  function closeModal(id) {
    document.getElementById(id).style.display = 'none';
    document.body.style.overflow = '';
  }

  // Dismiss modals on overlay click
  document.addEventListener('click', (e) => {
    if (e.target.classList.contains('modal-overlay')) {
      e.target.style.display = 'none';
      document.body.style.overflow = '';
    }
  });

  // ── Colour picker ───────────────────────────────────────────────
  function initColourPicker(containerId, inputId) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.querySelectorAll('.colour-swatch').forEach(sw => {
      sw.addEventListener('click', () => {
        container.querySelectorAll('.colour-swatch').forEach(s => s.classList.remove('selected'));
        sw.classList.add('selected');
        document.getElementById(inputId).value = sw.dataset.colour;
      });
    });
  }

  function setColour(containerId, inputId, colour) {
    const container = document.getElementById(containerId);
    if (!container) return;
    document.getElementById(inputId).value = colour;
    container.querySelectorAll('.colour-swatch').forEach(sw => {
      sw.classList.toggle('selected', sw.dataset.colour === colour);
    });
  }

  // ── Status helpers ──────────────────────────────────────────────
  const STATUS_LABELS = {
    backlog: 'Backlog', todo: 'Todo', 'in-progress': 'In progress',
    review: 'Review', done: 'Done',
  };
  const STATUS_COLORS = {
    backlog: '#9ca3af', todo: '#6366f1', 'in-progress': '#f59e0b',
    review: '#8b5cf6', done: '#22c55e',
  };

  function statusIcon(status) {
    const icons = {
      backlog:       { sym: '○', cls: 'status-backlog' },
      todo:          { sym: '◌', cls: 'status-todo' },
      'in-progress': { sym: '◑', cls: 'status-in-progress' },
      review:        { sym: '✦', cls: 'status-review' },
      done:          { sym: '●', cls: 'status-done' },
    };
    const i = icons[status] || icons.backlog;
    return `<span class="status-icon ${i.cls}" title="${STATUS_LABELS[status] || status}" style="font-size:15px;line-height:1">${i.sym}</span>`;
  }

  function priorityDot(priority) {
    return `<span class="priority-dot priority-${priority}" title="${priority}"></span>`;
  }

  function milestoneTag(name) {
    if (!name) return '';
    return `<span class="milestone-tag">${name}</span>`;
  }

  function assigneeChip(name) {
    if (!name) return '';
    return `<span class="assignee-chip">${name}</span>`;
  }

  // ── Sidebar project list ────────────────────────────────────────
  async function renderSidebarProjects() {
    const el = document.getElementById('sidebar-projects');
    if (!el) return;
    try {
      const projects = await api('GET', '/api/projects');
      const active = projects.filter(p => p.status === 'active');
      if (!active.length) { el.innerHTML = ''; return; }
      const current = new URLSearchParams(window.location.search).get('id');
      el.innerHTML = `
        <div class="nav-section-label">Projects</div>
        ${active.map(p => `
          <a href="project.html?id=${p.id}" class="nav-item${p.id === current ? ' active' : ''}">
            <span class="nav-project-dot" style="background:${p.colour}"></span>
            ${p.name}
          </a>`).join('')}
      `;
    } catch { el.innerHTML = ''; }
  }

  // ── Issue card / row rendering ──────────────────────────────────
  function renderKanbanCard(issue, opts = {}) {
    const labels = (issue.labels || []).map(l => `<span class="label-chip">${l}</span>`).join('');
    const showProject = opts.showProject && issue.project_name
      ? `<span class="assignee-chip">${issue.project_name}</span>` : '';
    return `
      <div class="kanban-card" data-priority="${issue.priority}" onclick="GRAFT.openIssueSlideover('${issue.id}')">
        <div class="kanban-card-title">${issue.title}</div>
        <div class="kanban-card-meta">
          ${priorityDot(issue.priority)}
          ${milestoneTag(issue.milestone_name)}
          ${assigneeChip(issue.assignee)}
          ${labels}
          ${showProject}
        </div>
      </div>`;
  }

  function renderIssueRow(issue, opts = {}) {
    const showProject = opts.showProject && issue.project_name
      ? `<span class="issue-row-project">${issue.project_name}</span>` : '';
    const labels = (issue.labels || []).slice(0, 2).map(l => `<span class="label-chip">${l}</span>`).join('');
    return `
      <div class="issue-row" data-priority="${issue.priority}" onclick="GRAFT.openIssueSlideover('${issue.id}')">
        <div class="issue-row-status">${statusIcon(issue.status)}</div>
        <div class="issue-row-title ${issue.status === 'done' ? 'done-title' : ''}">${issue.title}</div>
        <div class="issue-row-meta">
          ${milestoneTag(issue.milestone_name)}
          ${labels}
          ${assigneeChip(issue.assignee)}
          ${priorityDot(issue.priority)}
          ${showProject}
        </div>
      </div>`;
  }

  // ── Issue modal population ──────────────────────────────────────
  let _allProjects = [];
  let _allMilestones = [];
  let _allIssues = [];
  let _currentProjectId = null;

  async function loadMilestonesForProject() {
    const pid = document.getElementById('issue-project')?.value || _currentProjectId;
    const sel = document.getElementById('issue-milestone');
    if (!sel) return;
    sel.innerHTML = '<option value="">No milestone</option>';
    if (!pid) return;
    const ms = _allMilestones.filter(m => m.project_id === pid);
    ms.forEach(m => {
      const o = document.createElement('option');
      o.value = m.id; o.textContent = m.name;
      sel.appendChild(o);
    });
  }

  function openNewIssue(prefillProjectId) {
    const editId = document.getElementById('issue-edit-id');
    if (editId) editId.value = '';
    document.getElementById('issue-title').value = '';
    const desc = document.getElementById('issue-description');
    if (desc) desc.value = '';
    document.getElementById('issue-status').value = 'backlog';
    document.getElementById('issue-priority').value = 'normal';
    const assignee = document.getElementById('issue-assignee');
    if (assignee) assignee.value = '';
    const labels = document.getElementById('issue-labels');
    if (labels) labels.value = '';
    document.getElementById('modal-issue-title').textContent = 'New issue';
    const delBtn = document.getElementById('issue-delete-btn');
    if (delBtn) delBtn.style.display = 'none';

    // Populate project dropdown
    const projectSel = document.getElementById('issue-project');
    if (projectSel) {
      projectSel.innerHTML = '<option value="">Select project</option>';
      _allProjects.forEach(p => {
        const o = document.createElement('option');
        o.value = p.id; o.textContent = p.name;
        if (p.id === (prefillProjectId || _currentProjectId)) o.selected = true;
        projectSel.appendChild(o);
      });
    }
    loadMilestonesForProject();
    openModal('modal-new-issue');
  }

  function openEditIssue(issue) {
    document.getElementById('issue-edit-id').value = issue.id;
    document.getElementById('issue-title').value = issue.title;
    const desc = document.getElementById('issue-description');
    if (desc) desc.value = issue.description || '';
    document.getElementById('issue-status').value = issue.status;
    document.getElementById('issue-priority').value = issue.priority;
    const assignee = document.getElementById('issue-assignee');
    if (assignee) assignee.value = issue.assignee || '';
    const labels = document.getElementById('issue-labels');
    if (labels) labels.value = (issue.labels || []).join(', ');
    document.getElementById('modal-issue-title').textContent = 'Edit issue';
    const delBtn = document.getElementById('issue-delete-btn');
    if (delBtn) delBtn.style.display = 'inline-flex';

    const projectSel = document.getElementById('issue-project');
    if (projectSel) {
      projectSel.innerHTML = '<option value="">Select project</option>';
      _allProjects.forEach(p => {
        const o = document.createElement('option');
        o.value = p.id; o.textContent = p.name;
        if (p.id === issue.project_id) o.selected = true;
        projectSel.appendChild(o);
      });
    }
    loadMilestonesForProject();
    setTimeout(() => {
      const msSel = document.getElementById('issue-milestone');
      if (msSel && issue.milestone_id) msSel.value = issue.milestone_id;
    }, 50);
    openModal('modal-new-issue');
  }

  async function submitIssue(e) {
    e.preventDefault();
    const editId = document.getElementById('issue-edit-id').value;
    const projectId = document.getElementById('issue-project')?.value || _currentProjectId;
    const labelsRaw = document.getElementById('issue-labels')?.value || '';
    const labels = labelsRaw.split(',').map(l => l.trim()).filter(Boolean);
    const body = {
      project_id: projectId,
      milestone_id: document.getElementById('issue-milestone')?.value || null,
      title: document.getElementById('issue-title').value.trim(),
      description: document.getElementById('issue-description')?.value?.trim() || '',
      status: document.getElementById('issue-status').value,
      priority: document.getElementById('issue-priority').value,
      assignee: document.getElementById('issue-assignee')?.value?.trim() || '',
      labels,
    };
    if (!body.milestone_id) body.milestone_id = null;
    try {
      if (editId) {
        await api('PUT', `/api/issues/${editId}`, body);
        toast('Issue updated');
      } else {
        await api('POST', '/api/issues', body);
        toast('Issue created');
      }
      closeModal('modal-new-issue');
      if (typeof reloadPage === 'function') reloadPage();
    } catch (err) {
      toast('Error saving issue');
      console.error(err);
    }
  }

  async function deleteIssue() {
    const editId = document.getElementById('issue-edit-id').value;
    if (!editId) return;
    if (!confirm('Delete this issue?')) return;
    try {
      await api('DELETE', `/api/issues/${editId}`);
      toast('Issue deleted');
      closeModal('modal-new-issue');
      closeSlideover();
      if (typeof reloadPage === 'function') reloadPage();
    } catch { toast('Error deleting issue'); }
  }

  // ── Issue slide-over ────────────────────────────────────────────
  async function openIssueSlideover(id) {
    const issue = _allIssues.find(i => i.id === id);
    if (!issue) return;
    document.getElementById('detail-id').textContent = id;
    document.getElementById('slideover-body').innerHTML = `
      <div class="detail-title">${issue.title}</div>
      ${issue.description ? `<div class="detail-desc">${issue.description}</div>` : ''}
      <div class="detail-meta">
        <div class="detail-meta-row">
          <span class="detail-meta-label">Status</span>
          <span>${STATUS_LABELS[issue.status] || issue.status}</span>
        </div>
        <div class="detail-meta-row">
          <span class="detail-meta-label">Priority</span>
          ${priorityDot(issue.priority)} <span>${issue.priority.charAt(0).toUpperCase() + issue.priority.slice(1)}</span>
        </div>
        ${issue.assignee ? `<div class="detail-meta-row"><span class="detail-meta-label">Assignee</span><span>${issue.assignee}</span></div>` : ''}
        ${issue.milestone_name ? `<div class="detail-meta-row"><span class="detail-meta-label">Milestone</span>${milestoneTag(issue.milestone_name)}</div>` : ''}
        ${(issue.labels||[]).length ? `<div class="detail-meta-row"><span class="detail-meta-label">Labels</span><div style="display:flex;gap:4px;flex-wrap:wrap">${(issue.labels||[]).map(l=>`<span class="label-chip">${l}</span>`).join('')}</div></div>` : ''}
      </div>
      <div class="detail-actions">
        <button class="btn btn-ghost" onclick="GRAFT.openEditIssue(GRAFT._issue('${id}'))">Edit</button>
        <button class="btn btn-ghost btn-danger" onclick="GRAFT._deleteIssueFromSlideover('${id}')">Delete</button>
      </div>
    `;
    document.getElementById('slideover-overlay').style.display = 'block';
    document.getElementById('issue-slideover').style.display = 'flex';
    document.body.style.overflow = 'hidden';
  }

  function closeSlideover() {
    document.getElementById('slideover-overlay').style.display = 'none';
    document.getElementById('issue-slideover').style.display = 'none';
    document.body.style.overflow = '';
  }

  async function _deleteIssueFromSlideover(id) {
    if (!confirm('Delete this issue?')) return;
    try {
      await api('DELETE', `/api/issues/${id}`);
      toast('Issue deleted');
      closeSlideover();
      if (typeof reloadPage === 'function') reloadPage();
    } catch { toast('Error deleting issue'); }
  }

  function _issue(id) { return _allIssues.find(i => i.id === id); }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: index.html  (Projects)
  // ══════════════════════════════════════════════════════════════
  let _projectFilter = 'all';

  async function init() {
    initColourPicker('colour-picker', 'project-colour');
    renderSidebarProjects();
    loadProjects();
  }

  async function loadProjects() {
    try {
      _allProjects = await api('GET', '/api/projects');
      _allMilestones = await api('GET', '/api/milestones');
      renderProjects();
      const sub = document.getElementById('projects-subtitle');
      if (sub) {
        const active = _allProjects.filter(p => p.status === 'active').length;
        sub.textContent = `${_allProjects.length} project${_allProjects.length !== 1 ? 's' : ''} · ${active} active`;
      }
    } catch (err) {
      document.getElementById('projects-grid').innerHTML = `<div class="empty-state"><div class="empty-state-title">Can't reach Graft server</div><div>${err.message}</div></div>`;
    }
  }

  function filterProjects(status, btn) {
    _projectFilter = status;
    document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    renderProjects();
  }

  function renderProjects() {
    const grid = document.getElementById('projects-grid');
    if (!grid) return;
    const visible = _projectFilter === 'all' ? _allProjects : _allProjects.filter(p => p.status === _projectFilter);
    if (!visible.length) {
      grid.innerHTML = `<div class="empty-state"><div class="empty-state-icon">🌱</div><div class="empty-state-title">No projects yet</div><div>Time to get grafting.</div></div>`;
      return;
    }
    grid.innerHTML = visible.map(p => {
      const c = p.issue_counts || {};
      const open = (c.backlog||0) + (c.todo||0) + (c['in_progress']||0) + (c.review||0);
      return `
        <div class="project-card" onclick="window.location.href='project.html?id=${p.id}'">
          <div class="project-card-stripe" style="background:${p.colour}"></div>
          <div class="project-card-body">
            <div class="project-card-header">
              <span class="project-card-name">${p.name}</span>
              <span class="project-card-status status-${p.status}">${p.status}</span>
            </div>
            ${p.description ? `<div class="project-card-desc">${p.description}</div>` : ''}
            <div class="issue-counts">
              <span class="count-pill"><span class="count-dot" style="background:var(--sage)"></span>${open} open</span>
              <span class="count-pill"><span class="count-dot" style="background:var(--teal)"></span>${c.done||0} done</span>
            </div>
          </div>
        </div>`;
    }).join('');
  }

  function openNewProject() {
    document.getElementById('project-edit-id').value = '';
    document.getElementById('project-name').value = '';
    document.getElementById('project-description').value = '';
    document.getElementById('project-status').value = 'active';
    setColour('colour-picker', 'project-colour', '#6366f1');
    document.getElementById('modal-project-title').textContent = 'New project';
    openModal('modal-new-project');
  }

  async function submitProject(e) {
    e.preventDefault();
    const editId = document.getElementById('project-edit-id').value;
    const body = {
      name: document.getElementById('project-name').value.trim(),
      description: document.getElementById('project-description').value.trim(),
      status: document.getElementById('project-status').value,
      colour: document.getElementById('project-colour').value,
    };
    try {
      if (editId) {
        await api('PUT', `/api/projects/${editId}`, body);
        toast('Project saved');
      } else {
        const p = await api('POST', '/api/projects', body);
        toast('Project created');
        closeModal('modal-new-project');
        closeModal('modal-edit-project');
        window.location.href = `project.html?id=${p.id}`;
        return;
      }
      closeModal('modal-new-project');
      closeModal('modal-edit-project');
      if (typeof reloadPage === 'function') reloadPage();
      else loadProjects();
    } catch { toast('Error saving project'); }
  }

  async function deleteProject() {
    const editId = document.getElementById('project-edit-id').value;
    if (!editId) return;
    if (!confirm('Delete this project and all its issues?')) return;
    try {
      await api('DELETE', `/api/projects/${editId}`);
      toast('Project deleted');
      closeModal('modal-edit-project');
      window.location.href = 'index.html';
    } catch { toast('Error deleting project'); }
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: issues.html  (All issues)
  // ══════════════════════════════════════════════════════════════
  async function initIssues() {
    renderSidebarProjects();
    try {
      [_allProjects, _allIssues, _allMilestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', '/api/issues'),
        api('GET', '/api/milestones'),
      ]);
      const projectSel = document.getElementById('filter-project');
      _allProjects.forEach(p => {
        const o = document.createElement('option'); o.value = p.id; o.textContent = p.name;
        projectSel.appendChild(o);
      });
      const assignees = [...new Set(_allIssues.map(i => i.assignee).filter(Boolean))];
      const aSel = document.getElementById('filter-assignee');
      assignees.forEach(a => { const o = document.createElement('option'); o.value = a; o.textContent = a; aSel.appendChild(o); });
      // Attach project_name to issues for display
      const projMap = Object.fromEntries(_allProjects.map(p => [p.id, p.name]));
      _allIssues = _allIssues.map(i => ({ ...i, project_name: projMap[i.project_id] }));
      applyFilters();
      const sub = document.getElementById('issues-subtitle');
      if (sub) sub.textContent = `${_allIssues.length} issue${_allIssues.length !== 1 ? 's' : ''}`;
    } catch (err) {
      document.getElementById('issue-list').innerHTML = `<div class="empty-state"><div class="empty-state-title">Can't reach server</div></div>`;
    }
  }

  function applyFilters() {
    const project = document.getElementById('filter-project')?.value;
    const milestone = document.getElementById('filter-milestone')?.value;
    const status = document.getElementById('filter-status')?.value;
    const priority = document.getElementById('filter-priority')?.value;
    const assignee = document.getElementById('filter-assignee')?.value;
    const search = (document.getElementById('filter-search')?.value || '').toLowerCase();

    // Update milestone filter options when project changes
    if (project) {
      const msSel = document.getElementById('filter-milestone');
      if (msSel) {
        const current = msSel.value;
        msSel.innerHTML = '<option value="">All milestones</option><option value="none">No milestone</option>';
        _allMilestones.filter(m => m.project_id === project).forEach(m => {
          const o = document.createElement('option'); o.value = m.id; o.textContent = m.name;
          msSel.appendChild(o);
        });
        msSel.value = current;
      }
    }

    let issues = _allIssues;
    if (project) issues = issues.filter(i => i.project_id === project);
    if (milestone === 'none') issues = issues.filter(i => !i.milestone_id);
    else if (milestone) issues = issues.filter(i => i.milestone_id === milestone);
    if (status) issues = issues.filter(i => i.status === status);
    if (priority) issues = issues.filter(i => i.priority === priority);
    if (assignee) issues = issues.filter(i => i.assignee === assignee);
    if (search) issues = issues.filter(i => i.title.toLowerCase().includes(search) || (i.description||'').toLowerCase().includes(search));

    const el = document.getElementById('issue-list');
    if (!el) return;
    if (!issues.length) {
      el.innerHTML = `<div class="empty-state"><div class="empty-state-title">No issues found</div></div>`;
      return;
    }
    el.innerHTML = issues.map(i => renderIssueRow(i, { showProject: true })).join('');
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: project.html  (Single project)
  // ══════════════════════════════════════════════════════════════
  let _currentView = 'board';
  let _activeMilestoneFilter = null;
  let _currentProject = null;

  window.reloadPage = async function () {
    if (window._pageMode === 'project') await loadProjectPage();
    else if (window._pageMode === 'issues') await initIssues();
    else await loadProjects();
  };

  async function initProject() {
    window._pageMode = 'project';
    const id = new URLSearchParams(window.location.search).get('id');
    if (!id) { window.location.href = 'index.html'; return; }
    _currentProjectId = id;
    renderSidebarProjects();
    await loadProjectPage();
  }

  async function loadProjectPage() {
    try {
      [_allProjects, _currentProject, _allIssues, _allMilestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', `/api/projects/${_currentProjectId}`),
        api('GET', `/api/issues?project_id=${_currentProjectId}`),
        api('GET', `/api/milestones?project_id=${_currentProjectId}`),
      ]);
      document.title = `${_currentProject.name} — Graft`;
      document.getElementById('project-name-breadcrumb').textContent = _currentProject.name;
      document.getElementById('project-name-title').textContent = _currentProject.name;
      document.getElementById('project-description-text').textContent = _currentProject.description || '';
      renderMilestoneFilterBar();
      renderView();
    } catch (err) {
      document.getElementById('project-name-title').textContent = 'Project not found';
    }
  }

  function renderMilestoneFilterBar() {
    const bar = document.getElementById('milestone-filter-bar');
    const btns = document.getElementById('milestone-filter-buttons');
    if (!bar || !btns || !_allMilestones.length) { if (bar) bar.style.display = 'none'; return; }
    bar.style.display = 'flex';
    btns.innerHTML = `
      <button class="filter-btn ${!_activeMilestoneFilter ? 'active' : ''}" onclick="GRAFT.setMilestoneFilter(null)">All</button>
      <button class="filter-btn ${_activeMilestoneFilter === 'none' ? 'active' : ''}" onclick="GRAFT.setMilestoneFilter('none')">No milestone</button>
      ${_allMilestones.map(m => `<button class="filter-btn ${_activeMilestoneFilter === m.id ? 'active' : ''}" onclick="GRAFT.setMilestoneFilter('${m.id}')">${m.name}</button>`).join('')}
    `;
  }

  function setMilestoneFilter(id) {
    _activeMilestoneFilter = id;
    renderMilestoneFilterBar();
    renderView();
  }

  function setView(view, btn) {
    _currentView = view;
    document.querySelectorAll('.view-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('view-board').style.display = view === 'board' ? 'flex' : 'none';
    document.getElementById('view-list').style.display = view === 'list' ? 'flex' : 'none';
    renderView();
  }

  function filteredIssues() {
    let issues = _allIssues;
    if (_activeMilestoneFilter === 'none') issues = issues.filter(i => !i.milestone_id);
    else if (_activeMilestoneFilter) issues = issues.filter(i => i.milestone_id === _activeMilestoneFilter);
    return issues;
  }

  function renderView() {
    if (_currentView === 'board') renderBoard();
    else renderList();
  }

  const STATUS_COL_COLORS = {
    backlog: '#4a5a49', todo: '#96b86e', 'in-progress': '#c8903f',
    review: '#9b7fc9', done: '#5eaa8e',
  };

  function renderBoard() {
    const board = document.getElementById('view-board');
    if (!board) return;
    const issues = filteredIssues();
    const statuses = ['backlog', 'todo', 'in-progress', 'review', 'done'];
    board.innerHTML = statuses.map(status => {
      const col = issues.filter(i => i.status === status);
      const dotColor = STATUS_COL_COLORS[status];
      return `
        <div class="kanban-col">
          <div class="kanban-col-header">
            <span class="col-status-dot" style="background:${dotColor}"></span>
            <span class="col-name">${STATUS_LABELS[status]}</span>
            <span class="col-count">${col.length}</span>
          </div>
          ${col.map(i => renderKanbanCard(i)).join('')}
          <button class="kanban-add-btn" onclick="GRAFT._addIssueInStatus('${status}')">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            Add issue
          </button>
        </div>`;
    }).join('');
  }

  function renderList() {
    const list = document.getElementById('view-list');
    if (!list) return;
    const issues = filteredIssues();
    if (!issues.length) {
      list.innerHTML = `<div class="empty-state"><div class="empty-state-title">No issues</div><div>Add one with the button above.</div></div>`;
      return;
    }
    list.innerHTML = issues.map(i => renderIssueRow(i)).join('');
  }

  function _addIssueInStatus(status) {
    openNewIssue(_currentProjectId);
    setTimeout(() => { document.getElementById('issue-status').value = status; }, 50);
  }

  function editCurrentProject() {
    if (!_currentProject) return;
    document.getElementById('project-edit-id').value = _currentProject.id;
    document.getElementById('project-name').value = _currentProject.name;
    document.getElementById('project-description').value = _currentProject.description || '';
    document.getElementById('project-status').value = _currentProject.status;
    setColour('colour-picker', 'project-colour', _currentProject.colour);
    openModal('modal-edit-project');
  }

  // ── Milestones CRUD ─────────────────────────────────────────────
  function openMilestones() {
    renderMilestonesList();
    clearMilestoneForm();
    openModal('modal-milestones');
  }

  function renderMilestonesList() {
    const el = document.getElementById('milestones-list');
    if (!el) return;
    if (!_allMilestones.length) {
      el.innerHTML = `<div class="loading-state" style="padding:12px 0">No milestones yet.</div>`;
      return;
    }
    el.innerHTML = _allMilestones.map(m => `
      <div class="milestone-row" id="ms-row-${m.id}">
        <span class="milestone-row-name">${m.name}</span>
        ${m.due_date ? `<span class="milestone-row-due">${m.due_date}</span>` : ''}
        <div class="milestone-row-actions">
          <button class="icon-btn" onclick="GRAFT._editMilestone('${m.id}')" title="Edit">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
          </button>
          <button class="icon-btn" onclick="GRAFT._deleteMilestone('${m.id}')" title="Delete">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/></svg>
          </button>
        </div>
      </div>`).join('');
  }

  function clearMilestoneForm() {
    document.getElementById('milestone-edit-id').value = '';
    document.getElementById('milestone-name').value = '';
    document.getElementById('milestone-due').value = '';
    document.getElementById('milestone-description').value = '';
    document.getElementById('milestone-cancel-btn').style.display = 'none';
    const btn = document.querySelector('#modal-milestones .btn-primary');
    if (btn) btn.textContent = 'Add milestone';
  }

  function cancelMilestone() { clearMilestoneForm(); }

  function _editMilestone(id) {
    const m = _allMilestones.find(x => x.id === id);
    if (!m) return;
    document.getElementById('milestone-edit-id').value = m.id;
    document.getElementById('milestone-name').value = m.name;
    document.getElementById('milestone-due').value = m.due_date || '';
    document.getElementById('milestone-description').value = m.description || '';
    document.getElementById('milestone-cancel-btn').style.display = 'inline-flex';
    const btn = document.querySelector('#modal-milestones .btn-primary');
    if (btn) btn.textContent = 'Save milestone';
  }

  async function submitMilestone() {
    const editId = document.getElementById('milestone-edit-id').value;
    const name = document.getElementById('milestone-name').value.trim();
    if (!name) return toast('Milestone name is required');
    const body = {
      project_id: _currentProjectId,
      name,
      description: document.getElementById('milestone-description').value.trim(),
      due_date: document.getElementById('milestone-due').value || null,
    };
    try {
      if (editId) await api('PUT', `/api/milestones/${editId}`, body);
      else await api('POST', '/api/milestones', body);
      _allMilestones = await api('GET', `/api/milestones?project_id=${_currentProjectId}`);
      renderMilestonesList();
      renderMilestoneFilterBar();
      clearMilestoneForm();
      toast(editId ? 'Milestone updated' : 'Milestone added');
    } catch { toast('Error saving milestone'); }
  }

  async function _deleteMilestone(id) {
    if (!confirm('Delete this milestone? Issues won\'t be deleted.')) return;
    try {
      await api('DELETE', `/api/milestones/${id}`);
      _allMilestones = await api('GET', `/api/milestones?project_id=${_currentProjectId}`);
      if (_activeMilestoneFilter === id) _activeMilestoneFilter = null;
      renderMilestonesList();
      renderMilestoneFilterBar();
      toast('Milestone deleted');
    } catch { toast('Error deleting milestone'); }
  }

  // ── Public API ──────────────────────────────────────────────────
  window.GRAFT = {
    init, initIssues, initProject,
    filterProjects, applyFilters,
    openNewProject, openNewIssue, openEditIssue,
    submitProject, deleteProject, submitIssue, deleteIssue,
    setView, setMilestoneFilter,
    openMilestones, submitMilestone, cancelMilestone,
    openIssueSlideover, closeSlideover,
    editCurrentProject,
    loadMilestonesForProject,
    closeModal, openModal,
    _issue, _deleteIssueFromSlideover,
    _addIssueInStatus, _editMilestone, _deleteMilestone,
  };
})();
