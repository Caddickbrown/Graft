/* Graft — app.js */
(function () {
  'use strict';

  // Served by the Flask app itself, so talk to the same origin. Only fall
  // back to the Pi when the pages are opened from disk or a static server.
  const API = window.GRAFT_API !== undefined
    ? window.GRAFT_API
    : (location.protocol === 'http:' || location.protocol === 'https:'
        ? ''
        : 'http://raspberrypi.local:8911');

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

  // ── Escaping ────────────────────────────────────────────────────
  // Everything below interpolates user text into HTML strings, so it all
  // goes through here. Titles containing < or " used to break the markup.
  function esc(v) {
    return String(v ?? '').replace(/[&<>"']/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  // ── Icons ───────────────────────────────────────────────────────
  // One drawn set, shared by the board, the list and every menu, so a
  // status looks the same everywhere and recolours with the theme.
  const ICON = {
    backlog: '<circle cx="12" cy="12" r="9"/>',
    todo: '<circle cx="12" cy="12" r="9" stroke-dasharray="3.2 3.2"/>',
    'in-progress': '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"/>',
    review: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5" fill="currentColor" stroke="none"/>',
    done: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="m8 12 2.5 2.5L16 9" stroke="var(--bg)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>',
  };

  const PRIORITY_ICON = {
    urgent: '<circle cx="12" cy="12" r="10"/><path d="M12 8v5"/><path d="M12 17h.01"/>',
    high:   '<path d="M12 19V5"/><path d="m5 12 7-7 7 7"/>',
    normal: '<line x1="6" y1="12" x2="18" y2="12"/>',
    low:    '<path d="M12 5v14"/><path d="m5 12 7 7 7-7"/>',
  };

  const PRIORITY_LABELS = { urgent: 'Urgent', high: 'High', normal: 'Normal', low: 'Low' };
  const PRIORITIES = ['urgent', 'high', 'normal', 'low'];
  const STATUSES = ['backlog', 'todo', 'in-progress', 'review', 'done'];

  function svg(paths, size = 16, extra = '') {
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="2" stroke-linecap="round" ${extra}>${paths}</svg>`;
  }

  function statusIcon(status, size = 16) {
    const key = ICON[status] ? status : 'backlog';
    return `<span class="status-icon status-${key}" style="display:inline-flex;color:var(--s-${key})"
      >${svg(ICON[key], size)}</span>`;
  }

  // Normal is the default, so it says nothing — only what stands out shows.
  function priorityBadge(priority) {
    const key = PRIORITY_ICON[priority] ? priority : 'normal';
    if (key === 'normal') return '';
    if (key === 'low') {
      return `<span class="priority-badge low" title="Low priority"
        >${svg(PRIORITY_ICON.low, 12)}<span class="sr-only">Low priority</span></span>`;
    }
    return `<span class="priority-badge ${key}">${svg(PRIORITY_ICON[key], 12)}${PRIORITY_LABELS[key]}</span>`;
  }

  function initials(name) {
    const parts = String(name || '').trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return '';
    return (parts[0][0] + (parts[1]?.[0] || '')).toUpperCase();
  }

  function avatar(name) {
    if (!name) return `<span class="avatar avatar-none" title="Unassigned">+</span>`;
    return `<span class="avatar" title="${esc(name)}">${esc(initials(name))}</span>`;
  }

  // ── Relative time ───────────────────────────────────────────────
  function relTime(iso) {
    if (!iso) return '';
    const then = new Date(iso.endsWith('Z') || iso.includes('+') ? iso : iso + 'Z');
    if (isNaN(then)) return '';
    const mins = Math.round((Date.now() - then.getTime()) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    const days = Math.round(hrs / 24);
    if (days < 30) return `${days}d ago`;
    return then.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }

  // Days until a yyyy-mm-dd date, parsed as local midnight so a due date
  // never slips a day depending on the timezone.
  function daysUntil(dateStr) {
    if (!dateStr) return null;
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(dateStr);
    if (!m) return null;
    const due = new Date(+m[1], +m[2] - 1, +m[3]);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return Math.round((due - today) / 86400000);
  }

  function dueLabel(dateStr) {
    const d = daysUntil(dateStr);
    if (d === null) return '';
    if (d < 0) return `${Math.abs(d)}d overdue`;
    if (d === 0) return 'due today';
    if (d === 1) return 'due tomorrow';
    return `in ${d} days`;
  }

  // ── Undo toast ──────────────────────────────────────────────────
  // Destructive actions apply immediately and offer a way back, instead of
  // asking a browser dialog to guess your intent up front.
  let _undoTimer = null;

  function undoToast(message, onUndo, duration = 7000) {
    let el = document.getElementById('undo-toast');
    if (!el) {
      el = document.createElement('div');
      el.id = 'undo-toast';
      el.className = 'undo-toast';
      el.setAttribute('role', 'status');
      document.body.appendChild(el);
    }
    clearTimeout(_undoTimer);
    el.innerHTML = `<span>${esc(message)}</span><button class="undo-btn" type="button">Undo</button>`;
    el.querySelector('.undo-btn').onclick = async () => {
      clearTimeout(_undoTimer);
      el.classList.remove('show');
      try { await onUndo(); } catch { toast('Could not undo'); }
    };
    requestAnimationFrame(() => el.classList.add('show'));
    _undoTimer = setTimeout(() => el.classList.remove('show'), duration);
  }

  // ── Confirm dialog ──────────────────────────────────────────────
  // Replaces window.confirm(): says what will be destroyed, and for the
  // irreversible cases asks you to type the name.
  function confirmDialog({ title, body = '', confirmLabel = 'Confirm', danger = false, requireText = null }) {
    return new Promise(resolve => {
      const overlay = document.createElement('div');
      overlay.className = 'modal-overlay';
      overlay.style.display = 'flex';
      overlay.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title)}" style="max-width:420px">
          <div class="modal-header">
            <h2 class="modal-title">${esc(title)}</h2>
          </div>
          <div class="modal-body">
            ${body ? `<div class="confirm-text">${body}</div>` : ''}
            ${requireText ? `
              <div class="form-group">
                <label class="form-label" for="confirm-typed">Type <span class="confirm-strong">${esc(requireText)}</span> to confirm</label>
                <input class="form-input" id="confirm-typed" autocomplete="off" spellcheck="false">
              </div>` : ''}
            <div class="modal-footer">
              <button type="button" class="btn btn-ghost" data-act="cancel">Cancel</button>
              <button type="button" class="btn ${danger ? 'btn-ghost btn-danger' : 'btn-primary'}" data-act="ok">${esc(confirmLabel)}</button>
            </div>
          </div>
        </div>`;
      document.body.appendChild(overlay);
      document.body.style.overflow = 'hidden';

      const okBtn = overlay.querySelector('[data-act="ok"]');
      const typed = overlay.querySelector('#confirm-typed');
      if (typed) {
        okBtn.disabled = true;
        okBtn.style.opacity = '.45';
        typed.addEventListener('input', () => {
          const ok = typed.value.trim() === requireText;
          okBtn.disabled = !ok;
          okBtn.style.opacity = ok ? '' : '.45';
        });
      }

      function close(result) {
        document.removeEventListener('keydown', onKey, true);
        overlay.remove();
        document.body.style.overflow = '';
        resolve(result);
      }
      function onKey(e) {
        if (e.key === 'Escape') { e.stopPropagation(); close(false); }
        if (e.key === 'Enter' && !okBtn.disabled) { e.stopPropagation(); close(true); }
      }
      document.addEventListener('keydown', onKey, true);
      overlay.addEventListener('click', e => { if (e.target === overlay) close(false); });
      overlay.querySelector('[data-act="cancel"]').onclick = () => close(false);
      okBtn.onclick = () => { if (!okBtn.disabled) close(true); };
      setTimeout(() => (typed || okBtn).focus(), 30);
    });
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
  function milestoneTag(name) {
    if (!name) return '';
    return `<span class="milestone-tag">${esc(name)}</span>`;
  }

  function assigneeChip(name) {
    if (!name) return '';
    return `<span class="assignee-chip">${esc(name)}</span>`;
  }

  // ── Sidebar project list ────────────────────────────────────────
  async function renderSidebarProjects() {
    const el = document.getElementById('sidebar-projects');
    if (!el) return;
    try {
      const projects = await api('GET', '/api/projects');
      // Paused and done projects were invisible here — you could not navigate
      // to a project you had paused. Archived ones stay out.
      const rank = { active: 0, paused: 1, done: 2 };
      const active = projects
        .filter(p => !p.archived)
        .sort((a, b) => (rank[a.status] ?? 3) - (rank[b.status] ?? 3));
      if (!active.length) { el.innerHTML = ''; return; }
      const current = new URLSearchParams(window.location.search).get('id');
      el.innerHTML = `
        <div class="nav-section-label">Projects</div>
        ${active.map(p => {
          const c = p.issue_counts || {};
          const open = (c.backlog || 0) + (c.todo || 0) + (c.in_progress || 0) + (c.review || 0);
          return `
          <a href="project.html?id=${esc(p.id)}" class="nav-item${p.id === current ? ' active' : ''}"
             ${p.status !== 'active' ? `title="${esc(p.name)} — ${esc(p.status)}" style="opacity:.7"` : ''}>
            ${p.icon ? `<span class="nav-project-icon">${esc(p.icon)}</span>` : `<span class="nav-project-dot" style="background:${esc(p.colour)}"></span>`}
            ${esc(p.name)}
            ${open ? `<span style="margin-left:auto;font-size:11.5px;color:var(--dim)">${open}</span>` : ''}
          </a>`;
        }).join('')}
      `;
      syncDrawer();
    } catch { el.innerHTML = ''; }
  }

  // ── Issue card / row rendering ──────────────────────────────────
  function renderKanbanCard(issue, opts = {}) {
    const labels = (issue.labels || []).slice(0, 2).map(l => `<span class="label-chip">${esc(l)}</span>`).join('');
    const showProject = opts.showProject && issue.project_name
      ? `<span class="assignee-chip">${esc(issue.project_name)}</span>` : '';
    const urgent = issue.priority === 'urgent' || issue.priority === 'high';
    return `
      <div class="kanban-card"
           data-priority="${esc(issue.priority)}"
           data-id="${esc(issue.id)}"
           draggable="true"
           tabindex="0"
           role="button"
           aria-label="${esc(issue.title)}"
           onclick="GRAFT.openIssueSlideover('${esc(issue.id)}')"
           onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();GRAFT.openIssueSlideover('${esc(issue.id)}')}"
           ondragstart="GRAFT._dragStart(event)"
           ondragend="GRAFT._dragEnd(event)">
        <div class="kanban-card-title">${esc(issue.title)}</div>
        <div class="kanban-card-meta">
          ${urgent ? priorityBadge(issue.priority) : ''}
          ${milestoneTag(issue.milestone_name)}
          ${labels}
          ${showProject}
          <span style="margin-left:auto">${avatar(issue.assignee)}</span>
        </div>
      </div>`;
  }

  function renderIssueRow(issue, opts = {}) {
    const id = esc(issue.id);
    const showProject = opts.showProject && issue.project_name
      ? `<span class="issue-row-project">${esc(issue.project_name)}</span>` : '';
    const labels = (issue.labels || []).slice(0, 2).map(l => `<span class="label-chip">${esc(l)}</span>`).join('');
    const archivedClass = issue.archived ? ' issue-row-archived' : '';
    const selected = _selection.has(issue.id) ? ' selected' : '';
    const check = opts.selectable === false ? '' : `
      <input type="checkbox" class="row-check" ${_selection.has(issue.id) ? 'checked' : ''}
             aria-label="Select ${esc(issue.title)}"
             onclick="event.stopPropagation();GRAFT._toggleSelect('${id}',this.checked)">`;
    return `
      <div class="issue-row${archivedClass}${selected}" data-priority="${esc(issue.priority)}" data-id="${id}"
           tabindex="0" role="button" aria-label="${esc(issue.title)}"
           onclick="GRAFT.openIssueSlideover('${id}')"
           onkeydown="if(event.key==='Enter'){GRAFT.openIssueSlideover('${id}')}">
        ${check}
        <button class="status-btn" type="button"
                aria-label="Change status — currently ${esc(STATUS_LABELS[issue.status] || issue.status)}"
                onclick="event.stopPropagation();GRAFT._openStatusMenu(event,'${id}')">${statusIcon(issue.status)}</button>
        <div class="issue-row-title ${issue.status === 'done' ? 'done-title' : ''}">${esc(issue.title)}</div>
        <div class="issue-row-actions">
          <button class="icon-btn" type="button" title="Edit" aria-label="Edit issue"
                  onclick="event.stopPropagation();GRAFT.openEditIssue(GRAFT._issue('${id}'))">${svg(NAV_ICONS.edit, 15)}</button>
          <button class="icon-btn" type="button" title="${issue.archived ? 'Unarchive' : 'Archive'}"
                  aria-label="${issue.archived ? 'Unarchive issue' : 'Archive issue'}"
                  onclick="event.stopPropagation();GRAFT.archiveIssue('${id}')">${svg(NAV_ICONS.archive, 15)}</button>
        </div>
        <div class="issue-row-meta">
          ${milestoneTag(issue.milestone_name)}
          ${labels}
          ${priorityBadge(issue.priority)}
          ${showProject}
          ${avatar(issue.assignee)}
        </div>
      </div>`;
  }

  // ── Inline status menu ──────────────────────────────────────────
  function _openStatusMenu(event, id) {
    document.querySelector('.popover')?.remove();
    const issue = _issue(id);
    if (!issue) return;
    const pop = document.createElement('div');
    pop.className = 'popover';
    pop.innerHTML = `<div class="popover-label">Move to</div>` + STATUSES.map(st => `
      <button class="popover-item" type="button" role="menuitemradio"
              aria-checked="${issue.status === st}" data-status="${st}">
        ${statusIcon(st, 15)}<span>${STATUS_LABELS[st]}</span>
        <span class="popover-check">${svg('<path d="m5 12 5 5 9-10"/>', 14)}</span>
      </button>`).join('');
    document.body.appendChild(pop);

    const r = event.currentTarget.getBoundingClientRect();
    pop.style.top = `${Math.min(r.bottom + 6, window.innerHeight - pop.offsetHeight - 12) + window.scrollY}px`;
    pop.style.left = `${Math.min(r.left, window.innerWidth - pop.offsetWidth - 12)}px`;

    pop.querySelectorAll('[data-status]').forEach(b => {
      b.onclick = async () => {
        pop.remove();
        await setIssueStatus(id, b.dataset.status);
      };
    });
    setTimeout(() => {
      document.addEventListener('click', function off() {
        pop.remove();
        document.removeEventListener('click', off);
      }, { once: true });
    }, 0);
  }

  async function setIssueStatus(id, status) {
    const issue = _issue(id);
    if (!issue || issue.status === status) return;
    const previous = issue.status;
    issue.status = status;
    rerenderCurrentView();
    try {
      await api('PUT', `/api/issues/${id}`, { status });
      undoToast(`Moved to ${STATUS_LABELS[status]}`, async () => {
        issue.status = previous;
        rerenderCurrentView();
        await api('PUT', `/api/issues/${id}`, { status: previous });
      });
    } catch {
      issue.status = previous;
      rerenderCurrentView();
      toast('Could not change status');
    }
  }

  // ── Selection ───────────────────────────────────────────────────
  const _selection = new Set();

  function _toggleSelect(id, on) {
    if (on) _selection.add(id); else _selection.delete(id);
    document.querySelector(`.issue-row[data-id="${CSS.escape(id)}"]`)?.classList.toggle('selected', on);
    renderBulkBar();
  }

  function clearSelection() {
    _selection.clear();
    document.querySelectorAll('.issue-row.selected').forEach(r => r.classList.remove('selected'));
    document.querySelectorAll('.row-check').forEach(c => { c.checked = false; });
    renderBulkBar();
  }

  function renderBulkBar() {
    let bar = document.getElementById('bulk-bar');
    if (!_selection.size) { bar?.remove(); return; }
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'bulk-bar';
      bar.className = 'bulk-bar';
      bar.setAttribute('role', 'toolbar');
      document.body.appendChild(bar);
    }
    const n = _selection.size;
    bar.innerHTML = `
      <span class="bulk-count">${n} selected</span>
      <span class="bulk-sep"></span>
      <button class="btn btn-ghost btn-sm" type="button" data-act="status">${svg(ICON.backlog, 14)} Status</button>
      <button class="btn btn-ghost btn-sm" type="button" data-act="assign">${svg('<circle cx="12" cy="8" r="3.5"/><path d="M5.5 20a6.5 6.5 0 0 1 13 0"/>', 14)} Assign</button>
      <button class="btn btn-ghost btn-sm" type="button" data-act="archive">${svg(NAV_ICONS.archive, 14)} Archive</button>
      <span class="bulk-sep"></span>
      <button class="btn btn-ghost btn-sm" type="button" data-act="done">Done</button>`;
    bar.querySelector('[data-act="status"]').onclick = e => _bulkStatusMenu(e);
    bar.querySelector('[data-act="assign"]').onclick = _bulkAssign;
    bar.querySelector('[data-act="archive"]').onclick = _bulkArchive;
    bar.querySelector('[data-act="done"]').onclick = clearSelection;
  }

  function _bulkStatusMenu(event) {
    document.querySelector('.popover')?.remove();
    const pop = document.createElement('div');
    pop.className = 'popover';
    pop.innerHTML = `<div class="popover-label">Move ${_selection.size} to</div>` + STATUSES.map(st => `
      <button class="popover-item" type="button" data-status="${st}">
        ${statusIcon(st, 15)}<span>${STATUS_LABELS[st]}</span>
      </button>`).join('');
    document.body.appendChild(pop);
    const r = event.currentTarget.getBoundingClientRect();
    pop.style.top = `${r.top + window.scrollY - pop.offsetHeight - 8}px`;
    pop.style.left = `${Math.max(12, Math.min(r.left, window.innerWidth - pop.offsetWidth - 12))}px`;
    pop.querySelectorAll('[data-status]').forEach(b => {
      b.onclick = async () => { pop.remove(); await _bulkSetStatus(b.dataset.status); };
    });
    setTimeout(() => document.addEventListener('click', function off() {
      pop.remove(); document.removeEventListener('click', off);
    }, { once: true }), 0);
  }

  async function _bulkSetStatus(status) {
    const ids = [..._selection];
    const previous = ids.map(id => ({ id, status: _issue(id)?.status }));
    ids.forEach(id => { const i = _issue(id); if (i) i.status = status; });
    clearSelection();
    rerenderCurrentView();
    try {
      await Promise.all(ids.map(id => api('PUT', `/api/issues/${id}`, { status })));
      undoToast(`${ids.length} moved to ${STATUS_LABELS[status]}`, async () => {
        previous.forEach(p => { const i = _issue(p.id); if (i) i.status = p.status; });
        rerenderCurrentView();
        await Promise.all(previous.map(p => api('PUT', `/api/issues/${p.id}`, { status: p.status })));
      });
    } catch { toast('Some changes did not save'); reloadPage(); }
  }

  async function _bulkAssign() {
    const ids = [..._selection];
    const name = await promptDialog('Assign to', 'Name', '');
    if (name === null) return;
    clearSelection();
    try {
      await Promise.all(ids.map(id => api('PUT', `/api/issues/${id}`, { assignee: name })));
      toast(name ? `Assigned ${ids.length} to ${name}` : `Unassigned ${ids.length}`);
      reloadPage();
    } catch { toast('Some changes did not save'); }
  }

  async function _bulkArchive() {
    const ids = [..._selection];
    clearSelection();
    try {
      await Promise.all(ids.map(id => api('PATCH', `/api/issues/${id}/archive`)));
      undoToast(`${ids.length} issue${ids.length !== 1 ? 's' : ''} archived`, async () => {
        await Promise.all(ids.map(id => api('PATCH', `/api/issues/${id}/archive`)));
        reloadPage();
      });
      reloadPage();
    } catch { toast('Could not archive'); }
  }

  function promptDialog(title, label, initial) {
    return new Promise(resolve => {
      const overlay = document.createElement('div');
      overlay.className = 'modal-overlay';
      overlay.style.display = 'flex';
      overlay.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true" style="max-width:380px">
          <div class="modal-header"><h2 class="modal-title">${esc(title)}</h2></div>
          <div class="modal-body">
            <div class="form-group">
              <label class="form-label" for="prompt-input">${esc(label)}</label>
              <input class="form-input" id="prompt-input" value="${esc(initial)}" autocomplete="off">
            </div>
            <div class="modal-footer">
              <button type="button" class="btn btn-ghost" data-act="cancel">Cancel</button>
              <button type="button" class="btn btn-primary" data-act="ok">Save</button>
            </div>
          </div>
        </div>`;
      document.body.appendChild(overlay);
      const input = overlay.querySelector('#prompt-input');
      const done = v => { overlay.remove(); resolve(v); };
      overlay.querySelector('[data-act="cancel"]').onclick = () => done(null);
      overlay.querySelector('[data-act="ok"]').onclick = () => done(input.value.trim());
      input.onkeydown = e => {
        if (e.key === 'Enter') { e.preventDefault(); done(input.value.trim()); }
        if (e.key === 'Escape') { e.preventDefault(); done(null); }
      };
      overlay.addEventListener('click', e => { if (e.target === overlay) done(null); });
      setTimeout(() => input.focus(), 30);
    });
  }

  function rerenderCurrentView() {
    if (window._pageMode === 'project') renderView();
    else if (window._pageMode === 'issues') applyFilters();
    else if (window._pageMode === 'today') renderToday();
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
    closeModal('modal-new-issue');
    await deleteIssueById(editId);
  }

  // Deleting is permanent, so it says what goes and offers archiving instead.
  async function deleteIssueById(id) {
    const issue = _issue(id);
    const ok = await confirmDialog({
      title: 'Delete this issue?',
      body: `<div class="confirm-text">“<span class="confirm-strong">${esc(issue?.title || 'This issue')}</span>” will be deleted permanently.</div>
             <div class="confirm-detail">Archiving keeps it out of the way and can be undone — delete cannot.</div>`,
      confirmLabel: 'Delete permanently',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/issues/${id}`);
      toast('Issue deleted');
      closeSlideover();
      _allIssues = _allIssues.filter(i => i.id !== id);
      if (typeof reloadPage === 'function') reloadPage();
    } catch { toast('Could not delete issue'); }
  }

  // Archive is the reversible one, so it just happens and offers a way back.
  async function archiveIssue(id) {
    const issue = _issue(id);
    const wasArchived = !!issue?.archived;
    try {
      await api('PATCH', `/api/issues/${id}/archive`);
      undoToast(wasArchived ? 'Issue unarchived' : 'Issue archived', async () => {
        await api('PATCH', `/api/issues/${id}/archive`);
        if (typeof reloadPage === 'function') reloadPage();
      });
      closeSlideover();
      if (typeof reloadPage === 'function') reloadPage();
    } catch { toast('Could not archive issue'); }
  }

  // ── Issue slide-over (inline editable) ──────────────────────────
  let _slideoverIssueId = null;

  async function openIssueSlideover(id) {
    const issue = _allIssues.find(i => i.id === id);
    if (!issue) return;
    _slideoverIssueId = id;
    document.getElementById('detail-id').textContent = id.replace('iss_', '#');

    // Build milestone options for this issue's project
    const msOptions = _allMilestones
      .filter(m => m.project_id === issue.project_id)
      .map(m => `<option value="${esc(m.id)}" ${issue.milestone_id === m.id ? 'selected' : ''}>${esc(m.name)}</option>`)
      .join('');

    document.getElementById('slideover-body').innerHTML = `
      <div class="so-field">
        <div class="so-title"
             contenteditable="true"
             data-field="title"
             onblur="GRAFT._soSave()"
             onkeydown="if(event.key==='Enter'){event.preventDefault();this.blur();}"
        >${esc(issue.title)}</div>
      </div>

      <div class="so-field">
        <div class="so-desc"
             contenteditable="true"
             data-field="description"
             onblur="GRAFT._soSave()"
             placeholder="Add a description…"
        >${esc(issue.description || '')}</div>
      </div>

      <div class="so-meta">
        <div class="so-meta-row">
          <span class="so-label">Status</span>
          <select class="so-select" data-field="status" onchange="GRAFT._soSave()">
            <option value="backlog"     ${issue.status==='backlog'     ?'selected':''}>Backlog</option>
            <option value="todo"        ${issue.status==='todo'        ?'selected':''}>Todo</option>
            <option value="in-progress" ${issue.status==='in-progress' ?'selected':''}>In progress</option>
            <option value="review"      ${issue.status==='review'      ?'selected':''}>Review</option>
            <option value="done"        ${issue.status==='done'        ?'selected':''}>Done</option>
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Priority</span>
          <select class="so-select" data-field="priority" onchange="GRAFT._soSave()">
            <option value="urgent" ${issue.priority==='urgent'?'selected':''}>Urgent</option>
            <option value="high"   ${issue.priority==='high'  ?'selected':''}>High</option>
            <option value="normal" ${issue.priority==='normal'?'selected':''}>Normal</option>
            <option value="low"    ${issue.priority==='low'   ?'selected':''}>Low</option>
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Assignee</span>
          <input class="so-input" data-field="assignee"
                 value="${esc(issue.assignee || '')}"
                 placeholder="Unassigned"
                 onblur="GRAFT._soSave()">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Milestone</span>
          <select class="so-select" data-field="milestone_id" onchange="GRAFT._soSave()">
            <option value="">None</option>
            ${msOptions}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Labels</span>
          <input class="so-input" data-field="labels"
                 value="${esc((issue.labels||[]).join(', '))}"
                 placeholder="bug, frontend…"
                 onblur="GRAFT._soSave()">
        </div>
      </div>

      <div class="so-footer">
        <button class="btn btn-ghost btn-sm" onclick="GRAFT._archiveIssueFromSlideover('${id}')" title="${issue.archived ? 'Unarchive' : 'Archive'}">
          ${issue.archived ? '↩ Unarchive' : '⊘ Archive'}
        </button>
        <button class="btn btn-ghost btn-danger btn-sm" onclick="GRAFT._deleteIssueFromSlideover('${id}')">Delete issue</button>
      </div>

      <div class="so-project-section">
        <div class="so-project-header" onclick="GRAFT._toggleProjectSection()" id="so-project-toggle">
          <span class="so-project-label">Project — ${esc(_allProjects.find(p=>p.id===issue.project_id)?.name || '')}</span>
          <svg class="so-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>
        </div>
        <div class="so-project-body" id="so-project-body" style="display:none">
          ${_renderProjectSection(issue.project_id)}
        </div>
      </div>
    `;
    document.getElementById('slideover-overlay').style.display = 'block';
    document.getElementById('issue-slideover').style.display = 'flex';
    document.body.style.overflow = 'hidden';
  }

  async function _soSave() {
    const id = _slideoverIssueId;
    if (!id) return;
    const body = document.getElementById('slideover-body');

    const title = body.querySelector('[data-field="title"]')?.innerText?.trim();
    const description = body.querySelector('[data-field="description"]')?.innerText?.trim();
    const status = body.querySelector('[data-field="status"]')?.value;
    const priority = body.querySelector('[data-field="priority"]')?.value;
    const assignee = body.querySelector('[data-field="assignee"]')?.value?.trim();
    const milestone_id = body.querySelector('[data-field="milestone_id"]')?.value || null;
    const labelsRaw = body.querySelector('[data-field="labels"]')?.value || '';
    const labels = labelsRaw.split(',').map(l => l.trim()).filter(Boolean);

    if (!title) return;

    // Update local cache immediately
    const issue = _allIssues.find(i => i.id === id);
    if (issue) {
      Object.assign(issue, { title, description, status, priority, assignee, milestone_id, labels });
      // Update milestone_name for display
      const ms = _allMilestones.find(m => m.id === milestone_id);
      issue.milestone_name = ms?.name || null;
    }

    // Refresh board/list behind the slideover quietly
    if (_currentView === 'board') renderBoard();
    else renderList();

    try {
      await api('PUT', `/api/issues/${id}`, { title, description, status, priority, assignee, milestone_id, labels });
    } catch {
      toast('Save failed');
    }
  }

  function closeSlideover() {
    _slideoverIssueId = null;
    document.getElementById('slideover-overlay').style.display = 'none';
    document.getElementById('issue-slideover').style.display = 'none';
    document.body.style.overflow = '';
  }

  async function _deleteIssueFromSlideover(id) { await deleteIssueById(id); }

  async function _archiveIssueFromSlideover(id) { await archiveIssue(id); }

  function _issue(id) { return _allIssues.find(i => i.id === id); }

  function _renderProjectSection(pid) {
    const p = _allProjects.find(proj => proj.id === pid);
    if (!p) return '<div class="so-empty">No project</div>';
    return `
      <div class="so-meta" style="margin-top:10px">
        <div class="so-meta-row">
          <span class="so-label">Name</span>
          <input class="so-input" data-pfield="name" value="${esc(p.name)}" onblur="GRAFT._soProjectSave('${pid}')">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Status</span>
          <select class="so-select" data-pfield="status" onchange="GRAFT._soProjectSave('${pid}')">
            <option value="active"  ${p.status==='active' ?'selected':''}>Active</option>
            <option value="paused"  ${p.status==='paused' ?'selected':''}>Paused</option>
            <option value="done"    ${p.status==='done'   ?'selected':''}>Done</option>
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Icon</span>
          <input class="so-input" data-pfield="icon" value="${esc(p.icon||'')}" placeholder="Paste emoji…" onblur="GRAFT._soProjectSave('${pid}')">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Description</span>
          <input class="so-input" data-pfield="description" value="${esc(p.description||'')}" placeholder="Add description…" onblur="GRAFT._soProjectSave('${pid}')">
        </div>
      </div>
    `;
  }

  function _toggleProjectSection() {
    const body = document.getElementById('so-project-body');
    const chevron = document.querySelector('.so-chevron');
    const open = body.style.display !== 'none';
    body.style.display = open ? 'none' : 'block';
    if (chevron) chevron.style.transform = open ? '' : 'rotate(180deg)';
  }

  async function _soProjectSave(pid) {
    const body = document.getElementById('so-project-body');
    if (!body) return;
    const name = body.querySelector('[data-pfield="name"]')?.value?.trim();
    const status = body.querySelector('[data-pfield="status"]')?.value;
    const icon = body.querySelector('[data-pfield="icon"]')?.value?.trim();
    const description = body.querySelector('[data-pfield="description"]')?.value?.trim();
    if (!name) return;
    // Update local cache
    const proj = _allProjects.find(p => p.id === pid);
    if (proj) Object.assign(proj, { name, status, icon, description });
    // Update project toggle label
    const label = document.querySelector('.so-project-label');
    if (label) label.textContent = `Project — ${name}`;
    try {
      await api('PUT', `/api/projects/${pid}`, { name, status, icon, description });
      // Refresh sidebar in case name/icon changed
      renderSidebarProjects();
    } catch { toast('Failed to save project'); }
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: index.html  (Projects)
  // ══════════════════════════════════════════════════════════════
  let _projectFilter = 'all';

  async function init() {
    window._pageMode = 'projects';
    initTheme();
    initChrome('projects', { title: 'Projects', fab: { label: 'New project', action: openNewProject } });
    initColourPicker('colour-picker', 'project-colour');
    initIconPicker('icon-picker', 'project-icon');
    await renderSidebarProjects();
    loadProjects();
  }

  async function loadProjects() {
    try {
      // Fetch both normal and archived in parallel when needed
      const showArchived = _projectFilter === 'archived';
      const url = showArchived ? '/api/projects?archived=1' : '/api/projects';
      _allProjects = await api('GET', url);
      _allMilestones = await api('GET', '/api/milestones');
      renderProjects();
      const sub = document.getElementById('projects-subtitle');
      if (sub) {
        const active = _allProjects.filter(p => p.status === 'active' && !p.archived).length;
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
    loadProjects(); // reload — archived needs a different API call
  }

  function renderProjects() {
    const grid = document.getElementById('projects-grid');
    if (!grid) return;
    let visible;
    if (_projectFilter === 'archived') {
      visible = _allProjects.filter(p => p.archived);
    } else if (_projectFilter === 'all') {
      visible = _allProjects.filter(p => !p.archived);
    } else {
      visible = _allProjects.filter(p => !p.archived && p.status === _projectFilter);
    }
    if (!visible.length) {
      const msg = _projectFilter === 'archived' ? 'No archived projects' : 'No projects yet';
      const hint = _projectFilter === 'archived'
        ? 'Archived projects are kept out of the way but never deleted.'
        : 'Create one to start tracking issues.';
      grid.innerHTML = `<div class="empty-state"><div class="empty-state-icon">🌱</div>
        <div class="empty-state-title">${msg}</div><div>${hint}</div></div>`;
      return;
    }
    grid.innerHTML = visible.map(projectCard).join('');
  }

  function openNewProject() {
    document.getElementById('project-edit-id').value = '';
    document.getElementById('project-name').value = '';
    document.getElementById('project-description').value = '';
    document.getElementById('project-status').value = 'active';
    document.getElementById('project-icon').value = '';
    setColour('colour-picker', 'project-colour', '#6366f1');
    initIconPicker('icon-picker', 'project-icon');
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
      icon: document.getElementById('project-icon').value,
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
    const project = _allProjects.find(p => p.id === editId) || _currentProject;
    const counts = project?.issue_counts || {};
    const total = counts.total ?? Object.values(counts).reduce((a, b) => a + (b || 0), 0);
    const ok = await confirmDialog({
      title: 'Delete this project?',
      body: `<div class="confirm-text">This deletes <span class="confirm-strong">${esc(project?.name || 'the project')}</span>${
              total ? ` and all <span class="confirm-strong">${total}</span> of its issues` : ''}, permanently.</div>
             <div class="confirm-detail">Archiving hides it from the project list and can be undone at any time.</div>`,
      confirmLabel: 'Delete permanently',
      danger: true,
      requireText: project?.name || null,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/projects/${editId}`);
      toast('Project deleted');
      closeModal('modal-edit-project');
      window.location.href = 'index.html';
    } catch { toast('Could not delete project'); }
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: today.html  (What needs you)
  // ══════════════════════════════════════════════════════════════
  let _overview = null;

  async function initToday() {
    window._pageMode = 'today';
    initTheme();
    initChrome('today', { title: 'Today', fab: { label: 'New issue', action: () => openNewIssue() } });
    await renderSidebarProjects();
    try {
      const [projects, issues, milestones, overview] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', '/api/issues'),
        api('GET', '/api/milestones'),
        api('GET', '/api/overview').catch(() => null),
      ]);
      _allProjects = projects;
      _allMilestones = milestones;
      _overview = overview;
      const byId = Object.fromEntries(projects.map(p => [p.id, p]));
      _allIssues = issues.map(i => ({
        ...i,
        project_name: byId[i.project_id]?.name,
        project_icon: byId[i.project_id]?.icon,
      }));
      renderToday();
    } catch (err) {
      document.getElementById('today-content').innerHTML =
        `<div class="empty-state"><div class="empty-state-title">Can't reach the Graft server</div><div>${esc(err.message)}</div></div>`;
    }
  }

  // A milestone's due date is the only real deadline in the data, so
  // "overdue" means the issue is unfinished and its milestone has passed.
  function milestoneDue(issue) {
    if (!issue.milestone_id) return null;
    return _allMilestones.find(m => m.id === issue.milestone_id)?.due_date || null;
  }

  function renderToday() {
    const el = document.getElementById('today-content');
    if (!el) return;

    const open = _allIssues.filter(i => i.status !== 'done' && !i.archived);

    const needsYou = open.filter(i => {
      const d = daysUntil(milestoneDue(i));
      return i.priority === 'urgent' || i.priority === 'high' || (d !== null && d <= 2);
    }).sort((a, b) => {
      const rank = { urgent: 0, high: 1, normal: 2, low: 3 };
      const da = daysUntil(milestoneDue(a)), db = daysUntil(milestoneDue(b));
      if ((da !== null && da < 0) !== (db !== null && db < 0)) return (da !== null && da < 0) ? -1 : 1;
      return rank[a.priority] - rank[b.priority];
    });

    const inProgress = open.filter(i => i.status === 'in-progress' && !needsYou.includes(i));

    const sub = document.getElementById('today-subtitle');
    if (sub) {
      const date = new Date().toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
      const active = _allProjects.filter(p => p.status === 'active' && !p.archived).length;
      sub.textContent = `${date} · ${needsYou.length} need${needsYou.length === 1 ? 's' : ''} you · ${open.length} open across ${active} project${active !== 1 ? 's' : ''}`;
    }

    el.innerHTML = `
      ${todaySection('Needs you', needsYou, 'Nothing urgent or near a deadline. Enjoy it.')}
      ${todaySection('In progress', inProgress, 'Nothing started yet.')}
      <section class="section">
        <div class="section-head">
          <h2 class="section-title">Projects</h2>
          <div class="section-rule"></div>
          <a href="index.html" style="font-size:12.5px;color:var(--sage)">View all</a>
        </div>
        <div class="projects-grid">
          ${_allProjects.filter(p => !p.archived).slice(0, 8).map(projectCard).join('') ||
            '<div class="empty-state"><div class="empty-state-title">No projects yet</div></div>'}
        </div>
      </section>`;
  }

  function todaySection(title, issues, emptyText) {
    return `
      <section class="section">
        <div class="section-head">
          <h2 class="section-title">${esc(title)}</h2>
          <span class="section-count">${issues.length}</span>
          <div class="section-rule"></div>
        </div>
        ${issues.length
          ? `<div class="issue-list">${issues.slice(0, 8).map(todayRow).join('')}</div>`
          : `<div style="font-size:13px;color:var(--muted);padding:4px 2px">${esc(emptyText)}</div>`}
      </section>`;
  }

  function todayRow(issue) {
    const id = esc(issue.id);
    const due = milestoneDue(issue);
    const d = daysUntil(due);
    const flag = d !== null && d <= 2
      ? `<span class="${d < 0 ? 'due-flag' : 'age-flag'}">${esc(dueLabel(due))}</span>`
      : `<span class="age-flag">${esc(relTime(issue.updated_at))}</span>`;
    return `
      <div class="today-row" data-priority="${esc(issue.priority)}" data-id="${id}"
           tabindex="0" role="button" aria-label="${esc(issue.title)}"
           onclick="GRAFT._goToIssue('${id}')"
           onkeydown="if(event.key==='Enter'){GRAFT._goToIssue('${id}')}">
        ${statusIcon(issue.status, 18)}
        <span class="today-row-title">${esc(issue.title)}</span>
        <span class="issue-row-meta">
          ${issue.priority === 'urgent' || issue.priority === 'high' ? priorityBadge(issue.priority) : ''}
          ${flag}
          ${milestoneTag(issue.milestone_name)}
          <span class="today-project">${issue.project_icon ? esc(issue.project_icon) : ''} ${esc(issue.project_name || '')}</span>
          ${avatar(issue.assignee)}
        </span>
      </div>`;
  }

  function _goToIssue(id) {
    const issue = _issue(id);
    if (!issue) return;
    window.location.href = `project.html?id=${encodeURIComponent(issue.project_id)}&issue=${encodeURIComponent(id)}`;
  }

  // Shared project card — a progress bar answers "how far along" in a way
  // two raw counts never did.
  function projectCard(p) {
    const c = p.issue_counts || {};
    const open = (c.backlog || 0) + (c.todo || 0) + (c.in_progress || 0) + (c.review || 0);
    const done = c.done || 0;
    const total = open + done;
    const donePct = total ? Math.round((done / total) * 100) : 0;
    const doingPct = total ? Math.round(((c.in_progress || 0) / total) * 100) : 0;
    const next = _allMilestones
      .filter(m => m.project_id === p.id && m.due_date && daysUntil(m.due_date) !== null)
      .sort((a, b) => a.due_date.localeCompare(b.due_date))[0];
    return `
      <div class="project-card ${p.archived ? 'project-card-archived' : ''}"
           tabindex="0" role="link" aria-label="${esc(p.name)}"
           onclick="window.location.href='project.html?id=${esc(p.id)}'"
           onkeydown="if(event.key==='Enter'){window.location.href='project.html?id=${esc(p.id)}'}">
        <div class="project-card-stripe" style="background:${esc(p.colour)}"></div>
        <div class="project-card-body">
          <div class="project-card-header">
            ${p.icon ? `<span class="project-icon">${esc(p.icon)}</span>` : ''}
            <span class="project-card-name">${esc(p.name)}</span>
            ${p.archived
              ? `<span class="project-card-status" style="background:var(--surface2);color:var(--muted)">archived</span>`
              : `<span class="project-card-status status-${esc(p.status)}">${esc(p.status)}</span>`}
          </div>
          ${p.description ? `<div class="project-card-desc">${esc(p.description)}</div>` : ''}
          <div class="progress-row">
            <div class="progress" role="img" aria-label="${done} of ${total} done">
              <span class="progress-done" style="width:${donePct}%"></span>
              <span class="progress-doing" style="width:${doingPct}%"></span>
            </div>
            <span class="progress-label">${open} open · ${done} done</span>
          </div>
          ${next
            ? `<div style="font-size:12px;color:var(--muted)">Next: <span style="color:var(--sage)">${esc(next.name)}</span> ${esc(dueLabel(next.due_date))}</div>`
            : ''}
        </div>
      </div>`;
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: issues.html  (All issues)
  // ══════════════════════════════════════════════════════════════
  // Filters live in one object so the chips, the count and the list can
  // never disagree about what is being shown.
  let _filters = { project: null, milestone: null, status: [], priority: [], assignee: null, search: '' };

  const FILTER_DEFS = {
    project:   { label: 'Project',   multi: false },
    milestone: { label: 'Milestone', multi: false },
    status:    { label: 'Status',    multi: true  },
    priority:  { label: 'Priority',  multi: true  },
    assignee:  { label: 'Assignee',  multi: false },
  };

  async function initIssues() {
    window._pageMode = 'issues';
    initTheme();
    initChrome('issues', { title: 'All issues', fab: { label: 'New issue', action: () => openNewIssue() } });
    await renderSidebarProjects();
    try {
      const [projects, issues, milestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', '/api/issues?archived=1'),
        api('GET', '/api/milestones'),
      ]);
      _allProjects = projects;
      _allMilestones = milestones;
      const byId = Object.fromEntries(projects.map(p => [p.id, p]));
      _allIssues = issues.map(i => ({
        ...i,
        project_name: byId[i.project_id]?.name,
        project_icon: byId[i.project_id]?.icon,
      }));
      readFiltersFromURL();
      applyFilters();
    } catch {
      document.getElementById('issue-list').innerHTML =
        `<div class="empty-state"><div class="empty-state-title">Can't reach the Graft server</div>
         <div>Check the server is running, then reload.</div></div>`;
    }
  }

  // Filters survive a reload and can be shared as a link.
  function readFiltersFromURL() {
    const q = new URLSearchParams(window.location.search);
    if (q.get('project')) _filters.project = q.get('project');
    if (q.get('milestone')) _filters.milestone = q.get('milestone');
    if (q.get('status')) _filters.status = q.get('status').split(',').filter(Boolean);
    if (q.get('priority')) _filters.priority = q.get('priority').split(',').filter(Boolean);
    if (q.get('assignee')) _filters.assignee = q.get('assignee');
    if (q.get('q')) _filters.search = q.get('q');
    if (q.get('archived') === '1') _filters.archived = true;
  }

  function writeFiltersToURL() {
    const q = new URLSearchParams();
    if (_filters.project) q.set('project', _filters.project);
    if (_filters.milestone) q.set('milestone', _filters.milestone);
    if (_filters.status.length) q.set('status', _filters.status.join(','));
    if (_filters.priority.length) q.set('priority', _filters.priority.join(','));
    if (_filters.assignee) q.set('assignee', _filters.assignee);
    if (_filters.search) q.set('q', _filters.search);
    if (_filters.archived) q.set('archived', '1');
    const url = q.toString() ? `?${q}` : window.location.pathname;
    history.replaceState(null, '', url);
  }

  function activeFilterCount() {
    return (_filters.project ? 1 : 0) + (_filters.milestone ? 1 : 0) +
           (_filters.status.length ? 1 : 0) + (_filters.priority.length ? 1 : 0) +
           (_filters.assignee ? 1 : 0);
  }

  function filterValueLabel(key) {
    const v = _filters[key];
    if (key === 'project') return _allProjects.find(p => p.id === v)?.name || v;
    if (key === 'milestone') return v === 'none' ? 'None' : (_allMilestones.find(m => m.id === v)?.name || v);
    if (key === 'status') return v.map(x => STATUS_LABELS[x] || x).join(', ');
    if (key === 'priority') return v.map(x => PRIORITY_LABELS[x] || x).join(', ');
    return v;
  }

  function renderChips() {
    const bar = document.getElementById('chip-bar');
    if (!bar) return;
    const chips = Object.keys(FILTER_DEFS)
      .filter(k => Array.isArray(_filters[k]) ? _filters[k].length : _filters[k])
      .map(k => `
        <span class="chip">
          <span class="chip-key">${FILTER_DEFS[k].label}</span> is
          <span class="chip-val">${esc(filterValueLabel(k))}</span>
          <button class="chip-x" type="button" aria-label="Remove ${FILTER_DEFS[k].label} filter"
                  onclick="GRAFT._clearFilter('${k}')">${svg(NAV_ICONS.close, 11, 'stroke-width="2.5"')}</button>
        </span>`).join('');

    bar.innerHTML = `
      <button class="chip-add" type="button" id="chip-add" aria-haspopup="menu">
        ${svg(NAV_ICONS.plus, 13, 'stroke-width="2.5"')} Add filter
      </button>
      ${chips}
      ${activeFilterCount() ? `<button class="chip-clear" type="button" onclick="GRAFT._clearAllFilters()">Clear all</button>` : ''}
      <button class="switch-btn" type="button" aria-pressed="${!!_filters.archived}"
              style="margin-left:auto" onclick="GRAFT._toggleArchivedFilter()">
        <span class="switch-track"><span class="switch-knob"></span></span> Show archived
      </button>`;
    document.getElementById('chip-add').onclick = e => _openFilterMenu(e);
  }

  function _openFilterMenu(event) {
    document.querySelector('.popover')?.remove();
    const pop = document.createElement('div');
    pop.className = 'popover';
    pop.innerHTML = `<div class="popover-label">Filter by</div>` +
      Object.entries(FILTER_DEFS).map(([k, d]) =>
        `<button class="popover-item" type="button" data-key="${k}">${esc(d.label)}</button>`).join('');
    document.body.appendChild(pop);
    positionPopover(pop, event.currentTarget);
    pop.querySelectorAll('[data-key]').forEach(b => {
      b.onclick = e => { e.stopPropagation(); pop.remove(); _openFilterValues(event.currentTarget, b.dataset.key); };
    });
    dismissOnOutsideClick(pop);
  }

  function _openFilterValues(anchorEl, key) {
    document.querySelector('.popover')?.remove();
    let options = [];
    if (key === 'project') options = _allProjects.map(p => ({ v: p.id, label: p.name }));
    if (key === 'milestone') options = [{ v: 'none', label: 'No milestone' },
      ..._allMilestones.map(m => ({ v: m.id, label: m.name }))];
    if (key === 'status') options = STATUSES.map(x => ({ v: x, label: STATUS_LABELS[x] }));
    if (key === 'priority') options = PRIORITIES.map(x => ({ v: x, label: PRIORITY_LABELS[x] }));
    if (key === 'assignee') options = [...new Set(_allIssues.map(i => i.assignee).filter(Boolean))]
      .map(a => ({ v: a, label: a }));

    const pop = document.createElement('div');
    pop.className = 'popover';
    const multi = FILTER_DEFS[key].multi;
    pop.innerHTML = `<div class="popover-label">${esc(FILTER_DEFS[key].label)}</div>` +
      (options.length ? options.map(o => {
        const on = multi ? _filters[key].includes(o.v) : _filters[key] === o.v;
        return `<button class="popover-item" type="button" role="menuitemcheckbox" aria-checked="${on}" data-v="${esc(o.v)}">
          ${key === 'status' ? statusIcon(o.v, 15) : ''}
          <span>${esc(o.label)}</span>
          <span class="popover-check">${svg('<path d="m5 12 5 5 9-10"/>', 14)}</span>
        </button>`;
      }).join('') : `<div class="palette-empty" style="padding:14px">Nothing to filter by yet</div>`);
    document.body.appendChild(pop);
    positionPopover(pop, anchorEl);
    pop.querySelectorAll('[data-v]').forEach(b => {
      b.onclick = e => {
        e.stopPropagation();
        const v = b.dataset.v;
        if (multi) {
          const list = _filters[key];
          const at = list.indexOf(v);
          if (at >= 0) list.splice(at, 1); else list.push(v);
          b.setAttribute('aria-checked', String(list.includes(v)));
        } else {
          _filters[key] = _filters[key] === v ? null : v;
          pop.remove();
        }
        applyFilters();
      };
    });
    dismissOnOutsideClick(pop);
  }

  function positionPopover(pop, anchorEl) {
    const r = anchorEl.getBoundingClientRect();
    pop.style.top = `${r.bottom + 6 + window.scrollY}px`;
    pop.style.left = `${Math.max(12, Math.min(r.left, window.innerWidth - pop.offsetWidth - 12))}px`;
  }

  function dismissOnOutsideClick(pop) {
    setTimeout(() => {
      document.addEventListener('click', function off(ev) {
        if (pop.contains(ev.target)) return;
        pop.remove();
        document.removeEventListener('click', off);
      });
    }, 0);
  }

  function _clearFilter(key) {
    _filters[key] = FILTER_DEFS[key].multi ? [] : null;
    applyFilters();
  }

  function _clearAllFilters() {
    _filters = { project: null, milestone: null, status: [], priority: [], assignee: null,
                 search: _filters.search, archived: _filters.archived };
    applyFilters();
  }

  function _toggleArchivedFilter() {
    _filters.archived = !_filters.archived;
    applyFilters();
  }

  function _onSearchInput(value) {
    _filters.search = value;
    applyFilters();
  }

  function applyFilters() {
    const search = (_filters.search || '').toLowerCase();
    let issues = _allIssues;

    if (!_filters.archived) issues = issues.filter(i => !i.archived);
    if (_filters.project) issues = issues.filter(i => i.project_id === _filters.project);
    if (_filters.milestone === 'none') issues = issues.filter(i => !i.milestone_id);
    else if (_filters.milestone) issues = issues.filter(i => i.milestone_id === _filters.milestone);
    if (_filters.status.length) issues = issues.filter(i => _filters.status.includes(i.status));
    if (_filters.priority.length) issues = issues.filter(i => _filters.priority.includes(i.priority));
    if (_filters.assignee) issues = issues.filter(i => i.assignee === _filters.assignee);
    if (search) issues = issues.filter(i =>
      i.title.toLowerCase().includes(search) || (i.description || '').toLowerCase().includes(search));

    renderChips();
    writeFiltersToURL();

    const total = _allIssues.filter(i => _filters.archived || !i.archived).length;
    const sub = document.getElementById('issues-subtitle');
    if (sub) {
      const n = activeFilterCount() + (search ? 1 : 0);
      sub.innerHTML = issues.length === total
        ? `<span class="result-count"><strong>${total}</strong> issue${total !== 1 ? 's' : ''}</span>`
        : `<span class="result-count">Showing <strong>${issues.length}</strong> of ${total} · ${n} filter${n !== 1 ? 's' : ''} active</span>`;
    }

    const el = document.getElementById('issue-list');
    if (!el) return;
    if (!issues.length) {
      el.innerHTML = `
        <div class="empty-state">
          <div class="empty-state-title">No issues match these filters</div>
          <div>${total} issue${total !== 1 ? 's' : ''} are hidden by the filters above.</div>
          <button class="btn btn-ghost" type="button" style="margin-top:8px" onclick="GRAFT._clearAllFilters()">Clear filters</button>
        </div>`;
      return;
    }

    // Grouped by project — the list reads as a set of projects, not 87 rows
    const groups = new Map();
    issues.forEach(i => {
      const key = i.project_id;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(i);
    });
    el.innerHTML = [...groups.entries()].map(([pid, rows]) => {
      const p = _allProjects.find(x => x.id === pid);
      return `
        <div class="section-head" style="margin:14px 0 8px">
          <span style="font-size:12px">${esc(p?.icon || '')}</span>
          <span style="font-size:12.5px;font-weight:600;color:var(--ink)">${esc(p?.name || 'Unknown project')}</span>
          <span class="section-count">${rows.length}</span>
          <div class="section-rule"></div>
        </div>
        ${rows.map(i => renderIssueRow(i)).join('')}`;
    }).join('');
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: project.html  (Single project)
  // ══════════════════════════════════════════════════════════════
  let _currentView = 'board';
  let _activeMilestoneFilter = null;
  let _currentProject = null;
  let _showArchivedIssues = false;

  window.reloadPage = async function () {
    if (window._pageMode === 'project') await loadProjectPage();
    else if (window._pageMode === 'issues') await initIssues();
    else if (window._pageMode === 'today') await initToday();
    else await loadProjects();
  };

  async function initProject() {
    window._pageMode = 'project';
    initTheme();
    const params = new URLSearchParams(window.location.search);
    const id = params.get('id');
    if (!id) { window.location.href = 'index.html'; return; }
    _currentProjectId = id;
    initChrome('project', { title: 'Project', fab: { label: 'New issue', action: () => openNewIssue(_currentProjectId) } });
    await renderSidebarProjects();
    await loadProjectPage();
    // Deep link from Today, search or a shared URL
    const focus = params.get('issue');
    if (focus && _issue(focus)) openIssueSlideover(focus);
  }

  async function loadProjectPage() {
    try {
      const issuesUrl = _showArchivedIssues
        ? `/api/issues?project_id=${_currentProjectId}&archived=1`
        : `/api/issues?project_id=${_currentProjectId}`;
      [_allProjects, _currentProject, _allIssues, _allMilestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', `/api/projects/${_currentProjectId}`),
        api('GET', issuesUrl),
        api('GET', `/api/milestones?project_id=${_currentProjectId}`),
      ]);
      document.title = `${_currentProject.name} — Graft`;
      document.getElementById('project-name-breadcrumb').textContent = _currentProject.name;
      document.getElementById('project-name-title').textContent = (_currentProject.icon ? _currentProject.icon + ' ' : '') + _currentProject.name;
      document.getElementById('project-description-text').textContent = _currentProject.description || '';
      renderProjectProgress();
      // Show archived badge if project is archived
      const hdr = document.getElementById('project-header');
      if (hdr) hdr.dataset.archived = _currentProject.archived ? '1' : '0';
      renderMilestoneFilterBar();
      const saved = localStorage.getItem('graft_view');
      if (saved === 'list' && _currentView !== 'list') {
        _currentView = 'list';
        document.getElementById('btn-board')?.classList.remove('active');
        document.getElementById('btn-list')?.classList.add('active');
        document.getElementById('view-board').style.display = 'none';
        document.getElementById('view-list').style.display = 'flex';
      }
      renderView();
    } catch (err) {
      document.getElementById('project-name-title').textContent = 'Project not found';
    }
  }

  // Board and List are ways of drawing the same issues; archived is a
  // different set of issues. It stays a filter and keeps you in your view.
  // "Are we going to make it" belongs in the header, not in two raw counts.
  function renderProjectProgress() {
    const el = document.getElementById('project-progress');
    if (!el || !_currentProject) return;
    const live = _allIssues.filter(i => !i.archived);
    const done = live.filter(i => i.status === 'done').length;
    const doing = live.filter(i => i.status === 'in-progress').length;
    const total = live.length;
    if (!total) { el.innerHTML = ''; return; }
    const next = _allMilestones
      .filter(m => m.due_date)
      .sort((a, b) => a.due_date.localeCompare(b.due_date))
      .find(m => daysUntil(m.due_date) !== null && daysUntil(m.due_date) >= 0);
    el.innerHTML = `
      <div class="progress" style="max-width:180px" role="img" aria-label="${done} of ${total} issues done">
        <span class="progress-done" style="width:${Math.round(done / total * 100)}%"></span>
        <span class="progress-doing" style="width:${Math.round(doing / total * 100)}%"></span>
      </div>
      <span class="progress-label">${done} of ${total} done${
        next ? ` · <span style="color:var(--sage)">${esc(next.name)}</span> ${esc(dueLabel(next.due_date))}` : ''}</span>`;
  }

  function toggleArchivedIssues(btn) {
    _showArchivedIssues = !_showArchivedIssues;
    btn.setAttribute('aria-pressed', String(_showArchivedIssues));
    loadProjectPage();
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
    document.querySelectorAll('.view-btn').forEach(b => {
      b.classList.remove('active');
      b.setAttribute('aria-selected', 'false');
    });
    btn.classList.add('active');
    btn.setAttribute('aria-selected', 'true');
    localStorage.setItem('graft_view', view);
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

  // Soft limit — the column colours itself when work in progress piles up.
  const WIP_LIMIT = 3;

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
        <div class="kanban-col"
             data-status="${status}"
             ondragover="GRAFT._dragOver(event)"
             ondragenter="GRAFT._dragEnter(event)"
             ondragleave="GRAFT._dragLeave(event)"
             ondrop="GRAFT._drop(event)">
          <div class="kanban-col-header">
            <span class="col-status-dot" style="background:${dotColor}"></span>
            <span class="col-name">${STATUS_LABELS[status]}</span>
            <span class="col-count"${status === 'in-progress' && col.length > WIP_LIMIT
              ? ' style="color:var(--amber);border-color:var(--amber);background:rgba(200,144,63,.12)" title="More work in progress than the limit of ' + WIP_LIMIT + '"'
              : ''}>${col.length}${status === 'in-progress' ? ' / ' + WIP_LIMIT : ''}</span>
          </div>
          ${col.length
            ? col.map(i => renderKanbanCard(i)).join('')
            : `<div style="font-size:12.5px;color:var(--dim);padding:10px 4px 6px">Nothing here yet</div>`}
          <button class="kanban-add-btn" onclick="GRAFT._addIssueInStatus('${status}')">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            Add issue
          </button>
        </div>`;
    }).join('');
  }

  // ── Drag and drop ────────────────────────────────────────────────
  let _dragId = null;
  let _dragSourceStatus = null;

  function _dragStart(e) {
    const card = e.currentTarget;
    _dragId = card.dataset.id;
    _dragSourceStatus = card.closest('.kanban-col')?.dataset.status;
    card.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', _dragId);
    // Slight delay so the drag ghost renders before we dim the card
    setTimeout(() => card.classList.add('drag-ghost'), 0);
  }

  function _dragEnd(e) {
    e.currentTarget.classList.remove('dragging', 'drag-ghost');
    document.querySelectorAll('.kanban-col').forEach(c => c.classList.remove('drop-target'));
    _dragId = null;
    _dragSourceStatus = null;
  }

  function _dragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    // Show insertion indicator: find card we're hovering over
    const col = e.currentTarget;
    const afterCard = _getDragAfterCard(col, e.clientY);
    const placeholder = col.querySelector('.drag-placeholder');
    if (placeholder) placeholder.remove();
    const ph = document.createElement('div');
    ph.className = 'drag-placeholder';
    if (afterCard) {
      col.insertBefore(ph, afterCard);
    } else {
      const addBtn = col.querySelector('.kanban-add-btn');
      col.insertBefore(ph, addBtn);
    }
  }

  function _dragEnter(e) {
    e.preventDefault();
    e.currentTarget.classList.add('drop-target');
  }

  function _dragLeave(e) {
    // Only remove if leaving the column itself, not a child
    if (!e.currentTarget.contains(e.relatedTarget)) {
      e.currentTarget.classList.remove('drop-target');
      const ph = e.currentTarget.querySelector('.drag-placeholder');
      if (ph) ph.remove();
    }
  }

  async function _drop(e) {
    e.preventDefault();
    const col = e.currentTarget;
    col.classList.remove('drop-target');
    const ph = col.querySelector('.drag-placeholder');
    if (ph) ph.remove();

    const newStatus = col.dataset.status;
    if (!_dragId) return;

    // Find new sort_order: cards currently in this col, figure out where placeholder landed
    const cards = [...col.querySelectorAll('.kanban-card[data-id]')];
    const afterCard = _getDragAfterCard(col, e.clientY);
    let newOrder;
    if (afterCard) {
      const idx = cards.indexOf(afterCard);
      newOrder = idx;
    } else {
      newOrder = cards.length;
    }

    // Optimistically update local data
    const issue = _allIssues.find(i => i.id === _dragId);
    if (!issue) return;
    const statusChanged = issue.status !== newStatus;
    issue.status = newStatus;
    issue.sort_order = newOrder;

    // Re-render immediately (snappy feel)
    renderBoard();

    // Persist to API
    try {
      await api('PUT', `/api/issues/${_dragId}`, { status: newStatus, sort_order: newOrder });
    } catch {
      toast('Failed to save — refreshing');
      await loadProjectPage();
    }
  }

  function _getDragAfterCard(col, y) {
    const cards = [...col.querySelectorAll('.kanban-card[data-id]:not(.dragging)')];
    return cards.reduce((closest, card) => {
      const box = card.getBoundingClientRect();
      const offset = y - box.top - box.height / 2;
      if (offset < 0 && offset > (closest.offset ?? -Infinity)) {
        return { offset, element: card };
      }
      return closest;
    }, {}).element ?? null;
  }

  function renderList() {
    const list = document.getElementById('view-list');
    if (!list) return;
    const issues = filteredIssues();
    if (!issues.length) {
      const filtered = _activeMilestoneFilter || _showArchivedIssues;
      list.innerHTML = `<div class="empty-state">
        <div class="empty-state-icon">🌱</div>
        <div class="empty-state-title">${filtered ? 'Nothing matches this filter' : 'No issues yet'}</div>
        <div>${filtered ? 'Try clearing the milestone filter.' : 'Press C, or use New issue, to add the first one.'}</div>
      </div>`;
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
    document.getElementById('project-icon').value = _currentProject.icon || '';
    setColour('colour-picker', 'project-colour', _currentProject.colour);
    initIconPicker('icon-picker', 'project-icon');
    // Update archive button label
    const archBtn = document.getElementById('archive-project-btn');
    if (archBtn) archBtn.textContent = _currentProject.archived ? 'Unarchive' : 'Archive';
    openModal('modal-edit-project');
  }

  async function archiveCurrentProject() {
    if (!_currentProject) return;
    const id = _currentProject.id;
    try {
      const updated = await api('PATCH', `/api/projects/${id}/archive`);
      _currentProject = updated;
      closeModal('modal-edit-project');
      undoToast(`Project ${updated.archived ? 'archived' : 'unarchived'}`, async () => {
        await api('PATCH', `/api/projects/${id}/archive`);
        window.location.href = `project.html?id=${id}`;
      });
      if (updated.archived) setTimeout(() => { window.location.href = 'index.html'; }, 600);
      else if (typeof reloadPage === 'function') reloadPage();
    } catch { toast('Could not archive project'); }
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
    const m = _allMilestones.find(x => x.id === id);
    const used = _allIssues.filter(i => i.milestone_id === id).length;
    const ok = await confirmDialog({
      title: 'Delete this milestone?',
      body: `<div class="confirm-text">“<span class="confirm-strong">${esc(m?.name || '')}</span>” will be removed.</div>
             <div class="confirm-detail">${used
               ? `${used} issue${used !== 1 ? 's' : ''} will lose this milestone. The issues themselves are kept.`
               : 'No issues are using it.'}</div>`,
      confirmLabel: 'Delete milestone',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/milestones/${id}`);
      _allMilestones = await api('GET', `/api/milestones?project_id=${_currentProjectId}`);
      if (_activeMilestoneFilter === id) _activeMilestoneFilter = null;
      renderMilestonesList();
      renderMilestoneFilterBar();
      toast('Milestone deleted');
    } catch { toast('Error deleting milestone'); }
  }

  // ── Theme toggle ─────────────────────────────────────────────────
  const THEME_KEY = 'graft_theme';

  function initTheme() {
    const saved = localStorage.getItem(THEME_KEY) || 'dark';
    applyTheme(saved);
  }

  function applyTheme(theme) {
    document.documentElement.classList.toggle('light', theme === 'light');
    localStorage.setItem(THEME_KEY, theme);
    document.querySelectorAll('.theme-toggle-btn').forEach(btn => {
      btn.innerHTML = theme === 'light'
        ? `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg> Dark mode`
        : `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg> Light mode`;
    });
  }

  function toggleTheme() {
    const current = document.documentElement.classList.contains('light') ? 'light' : 'dark';
    applyTheme(current === 'light' ? 'dark' : 'light');
  }

  // ── Icon picker ───────────────────────────────────────────────────
  const PROJECT_ICONS = [
    '🌱','🌿','🍃','🌲','🌳','🌾','🌊','⚡','🔥','❄️',
    '🏔️','🏝️','🏙️','🚀','🛸','⚙️','🔧','🔨','🛠️','💡',
    '🎯','🎮','🎲','🎨','🎭','🎬','🎵','📚','📖','📝',
    '📊','📈','💰','💳','🏦','🏗️','🏠','🏡','🏢','🏋️',
    '🚗','✈️','🚢','🌍','🔬','🧬','🧪','💊','🩺','🤖',
    '👾','🕹️','🏆','🥇','⭐','✨','💫','🌟','☀️','🌙',
  ];

  function initIconPicker(containerId, inputId) {
    const container = document.getElementById(containerId);
    if (!container) return;
    const current = document.getElementById(inputId)?.value || '';
    container.innerHTML = `
      ${PROJECT_ICONS.map(icon => `
        <button type="button" class="icon-btn-pick ${icon === current ? 'selected' : ''}"
                data-icon="${icon}"
                onclick="GRAFT._pickIcon('${containerId}','${inputId}','${icon}')">${icon}</button>
      `).join('')}
      <button type="button" class="icon-clear" onclick="GRAFT._pickIcon('${containerId}','${inputId}','')">None</button>
    `;
  }

  function _pickIcon(containerId, inputId, icon) {
    document.getElementById(inputId).value = icon;
    document.querySelectorAll(`#${containerId} .icon-btn-pick`).forEach(b => {
      b.classList.toggle('selected', b.dataset.icon === icon);
    });
  }

  // ══════════════════════════════════════════════════════════════
  //  App chrome — mobile nav, command palette, shortcuts
  // ══════════════════════════════════════════════════════════════

  const NAV_ICONS = {
    today: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
    projects: '<rect x="2" y="3" width="9" height="9" rx="1"/><rect x="13" y="3" width="9" height="9" rx="1"/><rect x="2" y="13" width="9" height="9" rx="1"/><rect x="13" y="13" width="9" height="9" rx="1"/>',
    issues: '<circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>',
    search: '<circle cx="11" cy="11" r="7"/><line x1="20" y1="20" x2="16.5" y2="16.5"/>',
    menu: '<line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>',
    plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
    close: '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
    archive: '<rect x="2" y="4" width="20" height="5" rx="1"/><path d="M4 9v9a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9"/><path d="M10 13h4"/>',
    edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/>',
  };

  let _page = 'projects';

  // Builds the phone chrome the desktop sidebar can't provide: a top bar,
  // a drawer holding the same navigation, a tab bar and one primary action.
  function initChrome(page, opts = {}) {
    _page = page;

    const skip = document.createElement('a');
    skip.className = 'skip-link';
    skip.href = '#main';
    skip.textContent = 'Skip to content';
    document.body.prepend(skip);

    const main = document.querySelector('.main');
    if (main && !main.id) main.id = 'main';

    // Top bar
    if (main) {
      const bar = document.createElement('div');
      bar.className = 'mobile-topbar';
      bar.innerHTML = `
        <button class="topbar-btn" type="button" aria-label="Open navigation" data-act="menu">${svg(NAV_ICONS.menu, 20)}</button>
        <span class="topbar-title" id="topbar-title">${esc(opts.title || 'Graft')}</span>
        <button class="topbar-btn" type="button" aria-label="Search" data-act="search">${svg(NAV_ICONS.search, 20)}</button>`;
      main.prepend(bar);
      bar.querySelector('[data-act="menu"]').onclick = openDrawer;
      bar.querySelector('[data-act="search"]').onclick = openPalette;
    }

    // Drawer — the same nav the sidebar shows, reachable on a phone
    const scrim = document.createElement('div');
    scrim.className = 'drawer-scrim';
    scrim.id = 'drawer-scrim';
    scrim.onclick = closeDrawer;
    document.body.appendChild(scrim);

    const drawer = document.createElement('nav');
    drawer.className = 'drawer';
    drawer.id = 'drawer';
    drawer.setAttribute('aria-label', 'Main navigation');
    document.body.appendChild(drawer);
    syncDrawer();

    // Tab bar
    const tabs = document.createElement('nav');
    tabs.className = 'tabbar';
    tabs.setAttribute('aria-label', 'Sections');
    tabs.innerHTML = [
      ['today', 'today.html', 'Today'],
      ['projects', 'index.html', 'Projects'],
      ['issues', 'issues.html', 'Issues'],
    ].map(([key, href, label]) => `
      <a class="tab-item${page === key || (page === 'project' && key === 'projects') ? ' active' : ''}" href="${href}">
        ${svg(NAV_ICONS[key], 22)}<span>${label}</span>
      </a>`).join('');
    document.body.appendChild(tabs);

    // One primary action per page, thumb-reachable
    if (opts.fab) {
      const fab = document.createElement('button');
      fab.className = 'fab';
      fab.type = 'button';
      fab.setAttribute('aria-label', opts.fab.label);
      fab.innerHTML = svg(NAV_ICONS.plus, 24, 'stroke-width="2.5"');
      fab.onclick = opts.fab.action;
      document.body.appendChild(fab);
    }

    initShortcuts();
  }

  // Mirrors the sidebar into the drawer, so the project list added later
  // by renderSidebarProjects() shows up in both.
  function syncDrawer() {
    const drawer = document.getElementById('drawer');
    const sidebar = document.querySelector('.sidebar');
    if (!drawer || !sidebar) return;
    drawer.innerHTML = sidebar.innerHTML;
    const brand = drawer.querySelector('.sidebar-brand');
    if (brand) {
      const close = document.createElement('button');
      close.className = 'topbar-btn';
      close.type = 'button';
      close.setAttribute('aria-label', 'Close navigation');
      close.style.marginLeft = 'auto';
      close.innerHTML = svg(NAV_ICONS.close, 19);
      close.onclick = closeDrawer;
      brand.appendChild(close);
    }
    drawer.querySelectorAll('.theme-toggle-btn').forEach(b => { b.onclick = toggleTheme; });
  }

  function openDrawer() {
    document.getElementById('drawer')?.classList.add('open');
    document.getElementById('drawer-scrim')?.classList.add('open');
    document.body.style.overflow = 'hidden';
  }

  function closeDrawer() {
    document.getElementById('drawer')?.classList.remove('open');
    document.getElementById('drawer-scrim')?.classList.remove('open');
    document.body.style.overflow = '';
  }

  // ── Command palette ─────────────────────────────────────────────
  let _paletteData = null;
  let _paletteIndex = 0;

  async function openPalette() {
    if (document.getElementById('palette')) return;
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.id = 'palette-overlay';
    overlay.style.display = 'block';
    overlay.style.background = 'rgba(0,0,0,.5)';
    overlay.onclick = closePalette;
    document.body.appendChild(overlay);

    const el = document.createElement('div');
    el.className = 'palette';
    el.id = 'palette';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-label', 'Search');
    el.innerHTML = `
      <input class="palette-input" id="palette-input" placeholder="Search issues and projects…"
             autocomplete="off" spellcheck="false" aria-label="Search issues and projects">
      <div class="palette-results" id="palette-results">
        <div class="palette-empty">Loading…</div>
      </div>`;
    document.body.appendChild(el);
    document.body.style.overflow = 'hidden';
    document.getElementById('palette-input').focus();

    if (!_paletteData) {
      try {
        const [projects, issues] = await Promise.all([
          api('GET', '/api/projects'),
          api('GET', '/api/issues'),
        ]);
        const names = Object.fromEntries(projects.map(p => [p.id, p.name]));
        _paletteData = {
          projects,
          issues: issues.map(i => ({ ...i, project_name: names[i.project_id] })),
        };
      } catch {
        _paletteData = { projects: [], issues: [] };
      }
    }
    renderPalette('');
    document.getElementById('palette-input').addEventListener('input', e => renderPalette(e.target.value));
  }

  function renderPalette(query) {
    const box = document.getElementById('palette-results');
    if (!box || !_paletteData) return;
    const q = query.trim().toLowerCase();
    const projects = _paletteData.projects
      .filter(p => !q || p.name.toLowerCase().includes(q))
      .slice(0, 4)
      .map(p => ({ kind: 'project', id: p.id, label: p.name, sub: 'Project', icon: p.icon }));
    const issues = _paletteData.issues
      .filter(i => !q || i.title.toLowerCase().includes(q))
      .slice(0, 8)
      .map(i => ({ kind: 'issue', id: i.id, pid: i.project_id, label: i.title, sub: i.project_name || '', status: i.status }));
    const items = [...projects, ...issues];
    _paletteIndex = 0;

    if (!items.length) {
      box.innerHTML = `<div class="palette-empty">${q ? 'Nothing matches “' + esc(query) + '”' : 'Type to search'}</div>`;
      return;
    }
    box.innerHTML = items.map((it, n) => `
      <button class="palette-item${n === 0 ? ' active' : ''}" type="button" data-n="${n}"
              data-kind="${it.kind}" data-id="${esc(it.id)}" data-pid="${esc(it.pid || '')}">
        ${it.kind === 'issue' ? statusIcon(it.status, 15) : `<span style="font-size:15px">${esc(it.icon || '▪')}</span>`}
        <span>${esc(it.label)}</span>
        <span class="palette-item-sub">${esc(it.sub)}</span>
      </button>`).join('');
    box.querySelectorAll('.palette-item').forEach(b => { b.onclick = () => runPaletteItem(b); });
  }

  function runPaletteItem(btn) {
    const kind = btn.dataset.kind;
    closePalette();
    if (kind === 'project') window.location.href = `project.html?id=${encodeURIComponent(btn.dataset.id)}`;
    else window.location.href = `project.html?id=${encodeURIComponent(btn.dataset.pid)}&issue=${encodeURIComponent(btn.dataset.id)}`;
  }

  function closePalette() {
    document.getElementById('palette')?.remove();
    document.getElementById('palette-overlay')?.remove();
    document.body.style.overflow = '';
  }

  function paletteMove(delta) {
    const items = [...document.querySelectorAll('.palette-item')];
    if (!items.length) return;
    _paletteIndex = (_paletteIndex + delta + items.length) % items.length;
    items.forEach((b, n) => b.classList.toggle('active', n === _paletteIndex));
    items[_paletteIndex].scrollIntoView({ block: 'nearest' });
  }

  // ── Keyboard shortcuts ──────────────────────────────────────────
  function isTyping(e) {
    const t = e.target;
    return t instanceof HTMLElement &&
      (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable);
  }

  function initShortcuts() {
    document.addEventListener('keydown', e => {
      const palette = document.getElementById('palette');

      if (palette) {
        if (e.key === 'Escape') { e.preventDefault(); closePalette(); return; }
        if (e.key === 'ArrowDown') { e.preventDefault(); paletteMove(1); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); paletteMove(-1); return; }
        if (e.key === 'Enter') {
          e.preventDefault();
          const active = document.querySelector('.palette-item.active');
          if (active) runPaletteItem(active);
          return;
        }
        return;
      }

      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault(); openPalette(); return;
      }
      if (e.key === 'Escape') {
        if (document.getElementById('drawer')?.classList.contains('open')) { closeDrawer(); return; }
        if (document.getElementById('issue-slideover')?.style.display === 'flex') { closeSlideover(); return; }
        const open = [...document.querySelectorAll('.modal-overlay')].find(m => m.style.display === 'flex');
        if (open?.id) closeModal(open.id);
        return;
      }
      if (isTyping(e) || e.metaKey || e.ctrlKey || e.altKey) return;

      if (e.key === '/') { e.preventDefault(); openPalette(); return; }
      if (e.key.toLowerCase() === 'c') {
        e.preventDefault();
        if (_page === 'projects') openNewProject();
        else openNewIssue(_currentProjectId || undefined);
      }
    });
  }

  // ── Public API ──────────────────────────────────────────────────
  window.GRAFT = {
    init, initIssues, initProject, initToday,
    filterProjects, applyFilters,
    openNewProject, openNewIssue, openEditIssue,
    submitProject, deleteProject, submitIssue, deleteIssue,
    archiveCurrentProject,
    setView, setMilestoneFilter, toggleArchivedIssues,
    openMilestones, submitMilestone, cancelMilestone,
    openIssueSlideover, closeSlideover,
    editCurrentProject,
    loadMilestonesForProject,
    closeModal, openModal,
    _issue, _deleteIssueFromSlideover, _archiveIssueFromSlideover,
    _addIssueInStatus, _editMilestone, _deleteMilestone,
    _dragStart, _dragEnd, _dragOver, _dragEnter, _dragLeave, _drop,
    _soSave,
    toggleTheme, initIconPicker, _pickIcon,
    _renderProjectSection, _toggleProjectSection, _soProjectSave,
    // chrome
    openDrawer, closeDrawer, openPalette, closePalette,
    // issues page filters
    _clearFilter, _clearAllFilters, _toggleArchivedFilter, _onSearchInput,
    // rows, status, selection
    _openStatusMenu, setIssueStatus, _toggleSelect, clearSelection,
    archiveIssue, deleteIssueById, _goToIssue,
  };
})();
