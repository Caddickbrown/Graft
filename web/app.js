/* Graft — app.js */
(function () {
  'use strict';

  // Served by the Flask app itself, so talk to the same origin. Only fall
  // back to the Pi when the pages are opened from disk or a static server.
  // The server is HTTPS-only now: an http:// fallback is refused outright
  // rather than redirected, so the fallback moved with it.
  const API = window.GRAFT_API !== undefined
    ? window.GRAFT_API
    : (location.protocol === 'http:' || location.protocol === 'https:'
        ? ''
        : 'https://raspberrypi.local:8911');

  // ── Core API ────────────────────────────────────────────────────
  async function api(method, path, body) {
    const opts = { method, headers: { 'Content-Type': 'application/json' } };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const r = await fetch(API + path, opts);
    if (!r.ok) {
      // Callers need to tell "the server said no" from "the request never
      // arrived", so the status rides along on the error. It is for the code
      // to branch on — never for the user to read.
      const err = new Error(`${method} ${path} → ${r.status}`);
      err.status = r.status;
      throw err;
    }
    if (r.status === 204) return null;
    return r.json();
  }

  // ── Toast ───────────────────────────────────────────────────────
  function toast(msg, duration = 2200) {
    const el = document.getElementById('toast');
    if (!el) return;
    // Every failure message in the client arrives through here. Without a live
    // region a screen reader never heard one of them.
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.setAttribute('aria-atomic', 'true');
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

  // Ids are ours, not the user's, but they still end up inside a quoted JS
  // string in an attribute — so they go through the same door.
  function jsStr(v) { return esc(String(v ?? '').replace(/\\/g, '\\\\').replace(/'/g, "\\'")); }

  // ── Icons ───────────────────────────────────────────────────────
  // One drawn set, shared by the board, the list and every menu, so a
  // status looks the same everywhere and recolours with the theme.
  const ICON = {
    backlog: '<circle cx="12" cy="12" r="9"/>',
    todo: '<circle cx="12" cy="12" r="9" stroke-dasharray="3.2 3.2"/>',
    'in-progress': '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"/>',
    review: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5" fill="currentColor" stroke="none"/>',
    done: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="m8 12 2.5 2.5L16 9" stroke="var(--on-accent)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>',
  };

  const PRIORITY_ICON = {
    urgent: '<circle cx="12" cy="12" r="10"/><path d="M12 8v5"/><path d="M12 17h.01"/>',
    high:   '<path d="M12 19V5"/><path d="m5 12 7-7 7 7"/>',
    normal: '<line x1="6" y1="12" x2="18" y2="12"/>',
    low:    '<path d="M12 5v14"/><path d="m5 12 7 7 7-7"/>',
  };

  // A link's kind is a glyph, never a wordmark. The code-branch mark stands in
  // for GitHub deliberately: the Octocat is copyrighted and this says the same
  // thing without borrowing anyone's logo.
  const LINK_ICON = {
    github: '<line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/>',
    docs:   '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="13" y2="17"/>',
    design: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.2 2.2M16.9 16.9l2.2 2.2M19.1 4.9l-2.2 2.2M7.1 16.9l-2.2 2.2"/>',
    deploy: '<path d="M12 2 4 7v10l8 5 8-5V7z"/><path d="m4 7 8 5 8-5"/><path d="M12 12v10"/>',
    link:   '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  };

  const EXTERNAL_ICON = '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/>';
  const CHEVRON_DOWN = '<polyline points="6 9 12 15 18 9"/>';
  const DOTS_ICON = '<circle cx="5" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.6" fill="currentColor" stroke="none"/>';
  const STAR_ICON = '<path d="m12 3 2.6 5.6 6.1.8-4.5 4.2 1.2 6.1L12 16.8 6.6 19.7l1.2-6.1L3.3 9.4l6.1-.8z"/>';

  const PRIORITY_LABELS = { urgent: 'Urgent', high: 'High', normal: 'Normal', low: 'Low' };
  const PRIORITIES = ['urgent', 'high', 'normal', 'low'];
  const STATUSES = ['backlog', 'todo', 'in-progress', 'review', 'done'];
  const PROJECT_STATUSES = ['active', 'paused', 'done'];
  const PROJECT_STATUS_LABELS = { active: 'Active', paused: 'Paused', done: 'Done' };

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

  // ══════════════════════════════════════════════════════════════
  //  The states — loading, empty, zero-results, error, stale
  // ══════════════════════════════════════════════════════════════
  // Six of the ten worst findings in the design review were a missing or a
  // wrong state, so they are built once here and used by every surface. The
  // four have to stay tellable apart at a glance: a skeleton is shaped like
  // the content, an empty state names the thing and offers the one action, a
  // zero-results state counts what it is hiding, and an error never pretends
  // to be emptiness.

  // Alternating the line lengths stops five identical bars reading as a
  // spinner that has jammed.
  function skeleton(kind = 'issue', n = 5) {
    let rows = '';
    for (let i = 0; i < n; i++) {
      const width = i % 3 === 1 ? ' short' : (i % 3 === 2 ? '' : ' short');
      if (kind === 'project') {
        rows += `<div class="skeleton-card">
            <span class="skeleton skeleton-line"></span>
            <span class="skeleton skeleton-line short"></span>
            <span class="skeleton skeleton-line tiny"></span>
          </div>`;
      } else if (kind === 'card') {
        rows += `<div class="skeleton-card">
            <span class="skeleton skeleton-line${width}"></span>
            <span class="skeleton skeleton-line tiny"></span>
          </div>`;
      } else if (kind === 'link') {
        rows += `<div class="skeleton-row">
            <span class="skeleton skeleton-ring"></span>
            <span class="skeleton skeleton-line short"></span>
          </div>`;
      } else {
        rows += `<div class="skeleton-row">
            <span class="skeleton skeleton-ring"></span>
            <span class="skeleton skeleton-line${width}"></span>
            <span class="skeleton skeleton-line tiny"></span>
          </div>`;
      }
    }
    return `<div class="skeleton-list" aria-hidden="true">${rows}</div>
      <span class="sr-only" role="status">Loading…</span>`;
  }

  // The board's skeleton has to be board-shaped, or the columns snap into
  // existence and shove the page down when the data lands.
  function boardSkeleton() {
    return `<div class="kanban-board">${STATUSES.map((st, n) => `
      <div class="kanban-col" aria-hidden="true">
        <div class="kanban-col-header">
          <span class="skeleton skeleton-ring"></span>
          <span class="skeleton skeleton-line short"></span>
        </div>
        ${skeleton('card', n === 4 ? 1 : 2)}
      </div>`).join('')}</div>
      <span class="sr-only" role="status">Loading the board…</span>`;
  }

  function emptyState({ icon = '', title, body = '', actionLabel = '', onAction = '' }) {
    return `<div class="empty-state">
      ${icon ? `<div class="empty-state-icon">${esc(icon)}</div>` : ''}
      <div class="empty-state-title">${esc(title)}</div>
      ${body ? `<div class="empty-state-body">${esc(body)}</div>` : ''}
      ${actionLabel ? `<button class="btn btn-primary" type="button" style="margin-top:14px"
         onclick="${onAction}">${esc(actionLabel)}</button>` : ''}
    </div>`;
  }

  // "0 issues are hidden by the filters above" with no filters set was the
  // single most confusing line in the client. This one cannot say that: it is
  // only ever rendered when something really is filtered out, and it names
  // both the count and the filters doing the hiding.
  function noMatchState({ hidden, summary, onClear, noun = 'issues' }) {
    return `<div class="empty-state state-no-match">
      <div class="empty-state-title">No ${esc(noun)} match these filters</div>
      <div class="empty-state-body">${hidden} ${esc(noun)} ${hidden === 1 ? 'is' : 'are'} hidden${
        summary ? ` — ${esc(summary)}` : ''}.</div>
      <button class="btn btn-ghost" type="button" style="margin-top:14px" onclick="${onClear}">Clear filters</button>
    </div>`;
  }

  // A failure is never drawn as emptiness, and never quotes the error: the
  // user has no use for "GET /api/projects → 500". They need to know what
  // could not be reached and how to try again.
  function errorState({ title = 'Can’t reach the Graft server', body = '', onRetry = '' } = {}) {
    return `<div class="empty-state state-error" role="alert">
      <div class="empty-state-icon">⚠</div>
      <div class="empty-state-title">${esc(title)}</div>
      <div class="empty-state-body">${esc(body || 'The server may be down, or this device may be offline. Nothing has been lost.')}</div>
      ${onRetry ? `<button class="btn btn-ghost" type="button" style="margin-top:14px" onclick="${onRetry}">Try again</button>` : ''}
    </div>`;
  }

  // ── Stale banner ────────────────────────────────────────────────
  // A refresh that fails leaves the last good data on screen. That used to be
  // announced by a toast that had vanished before you looked up, so the board
  // in front of you was silently out of date. This says so, and stays.
  let _lastGood = null;
  let _staleRetry = null;

  function markFresh() {
    _lastGood = Date.now();
    document.getElementById('stale-banner')?.remove();
  }

  function markStale(onRetry) {
    _staleRetry = onRetry;
    let el = document.getElementById('stale-banner');
    if (!el) {
      el = document.createElement('div');
      el.id = 'stale-banner';
      el.className = 'stale-banner';
      el.setAttribute('role', 'status');
      const main = document.querySelector('.main');
      const topbar = main?.querySelector('.mobile-topbar');
      if (topbar) topbar.after(el);
      else main?.prepend(el);
    }
    const when = _lastGood ? relTime(new Date(_lastGood).toISOString()) : 'earlier';
    el.innerHTML = `<span class="stale-dot" aria-hidden="true"></span>
      <span class="stale-text">Showing data from ${esc(when)} — the last refresh didn’t reach the server.</span>
      <button class="btn btn-ghost btn-sm" type="button" data-act="retry">Retry</button>`;
    el.querySelector('[data-act="retry"]').onclick = () => {
      el.remove();
      if (_staleRetry) _staleRetry();
    };
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
      el.setAttribute('aria-live', 'polite');
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

  // ══════════════════════════════════════════════════════════════
  //  Focus management
  // ══════════════════════════════════════════════════════════════
  // Every overlay in the client used to leave focus behind it: you could tab
  // into the page underneath a modal, and closing one dropped focus back to
  // <body>. One trap, used by the modals, the slide-over and the palette.
  const FOCUSABLE = [
    'a[href]', 'button:not([disabled])', 'input:not([disabled])',
    'select:not([disabled])', 'textarea:not([disabled])',
    '[tabindex]:not([tabindex="-1"])', '[contenteditable="true"]',
  ].join(',');

  const _traps = new Map();

  function trapFocus(container, { autofocus = true } = {}) {
    if (!container || _traps.has(container)) return;
    const restore = document.activeElement;
    const onKey = e => {
      if (e.key !== 'Tab') return;
      const items = [...container.querySelectorAll(FOCUSABLE)]
        .filter(el => el.offsetWidth || el.offsetHeight || el === document.activeElement);
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      const inside = container.contains(document.activeElement);
      if (e.shiftKey && (document.activeElement === first || !inside)) {
        e.preventDefault(); last.focus();
      } else if (!e.shiftKey && (document.activeElement === last || !inside)) {
        e.preventDefault(); first.focus();
      }
    };
    container.addEventListener('keydown', onKey);
    _traps.set(container, { onKey, restore });
    if (autofocus) {
      const target = container.querySelector('[autofocus]') || container.querySelector(FOCUSABLE);
      setTimeout(() => { try { target?.focus(); } catch { /* nothing focusable */ } }, 30);
    }
  }

  function releaseFocus(container) {
    const t = container && _traps.get(container);
    if (!t) return;
    container.removeEventListener('keydown', t.onKey);
    _traps.delete(container);
    // Focus goes back where it came from, so closing a modal does not dump a
    // keyboard user at the top of the document.
    if (t.restore && document.contains(t.restore)) { try { t.restore.focus(); } catch { /* gone */ } }
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

      const dialog = overlay.querySelector('.modal');
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
        releaseFocus(dialog);
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
      trapFocus(dialog, { autofocus: false });
      setTimeout(() => (typed || okBtn).focus(), 30);
    });
  }

  // ── Form dialog ─────────────────────────────────────────────────
  // One small built-on-the-fly form, used where a whole markup modal would be
  // three fields of ceremony: renaming, assigning in bulk, areas and links.
  function formDialog({ title, fields, submitLabel = 'Save' }) {
    return new Promise(resolve => {
      const overlay = document.createElement('div');
      overlay.className = 'modal-overlay';
      overlay.style.display = 'flex';
      overlay.innerHTML = `
        <div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title)}" style="max-width:420px">
          <div class="modal-header"><h2 class="modal-title">${esc(title)}</h2>
            <button class="modal-close" type="button" data-act="cancel" aria-label="Close">${svg(NAV_ICONS.close, 18)}</button>
          </div>
          <div class="modal-body">
            ${fields.map((f, n) => `
              <div class="form-group">
                <label class="form-label" for="fd-${n}">${esc(f.label)}</label>
                ${f.type === 'select'
                  ? `<select class="form-input" id="fd-${n}">${(f.options || []).map(o =>
                       `<option value="${esc(o.value)}" ${String(o.value) === String(f.value ?? '') ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`
                  : `<input class="form-input" id="fd-${n}" type="${esc(f.type || 'text')}"
                       value="${esc(f.value ?? '')}" placeholder="${esc(f.placeholder || '')}" autocomplete="off">`}
                ${f.hint ? `<div class="form-hint">${esc(f.hint)}</div>` : ''}
              </div>`).join('')}
            <div class="modal-footer">
              <button type="button" class="btn btn-ghost" data-act="cancel">Cancel</button>
              <button type="button" class="btn btn-primary" data-act="ok">${esc(submitLabel)}</button>
            </div>
          </div>
        </div>`;
      document.body.appendChild(overlay);
      document.body.style.overflow = 'hidden';
      const dialog = overlay.querySelector('.modal');

      function close(result) {
        document.removeEventListener('keydown', onKey, true);
        releaseFocus(dialog);
        overlay.remove();
        document.body.style.overflow = '';
        resolve(result);
      }
      function read() {
        const out = {};
        fields.forEach((f, n) => { out[f.name] = overlay.querySelector(`#fd-${n}`).value.trim(); });
        return out;
      }
      function onKey(e) {
        if (e.key === 'Escape') { e.stopPropagation(); close(null); }
        if (e.key === 'Enter' && e.target.tagName !== 'TEXTAREA') { e.stopPropagation(); close(read()); }
      }
      document.addEventListener('keydown', onKey, true);
      overlay.addEventListener('click', e => { if (e.target === overlay) close(null); });
      overlay.querySelectorAll('[data-act="cancel"]').forEach(b => { b.onclick = () => close(null); });
      overlay.querySelector('[data-act="ok"]').onclick = () => close(read());
      trapFocus(dialog);
    });
  }

  function promptDialog(title, label, initial) {
    return formDialog({ title, fields: [{ name: 'value', label, value: initial }] })
      .then(r => (r === null ? null : r.value));
  }

  // ── Modal helpers ───────────────────────────────────────────────
  // Each page carries only the modals it uses, and shared code asks for ids
  // that may not be here — a missing one is nothing to do, not an error.
  function openModal(id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.style.display = 'flex';
    document.body.style.overflow = 'hidden';
    const dialog = el.querySelector('.modal') || el;
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    trapFocus(dialog);
  }

  function closeModal(id) {
    const el = document.getElementById(id);
    if (!el) return;
    releaseFocus(el.querySelector('.modal') || el);
    el.style.display = 'none';
    document.body.style.overflow = '';
  }

  function anyModalOpen() {
    return [...document.querySelectorAll('.modal-overlay')].some(m => m.style.display === 'flex')
      || document.getElementById('issue-slideover')?.style.display === 'flex'
      || !!document.getElementById('palette');
  }

  // Dismiss modals on overlay click — through closeModal so focus is restored
  // and the trap is torn down, rather than just hiding the element.
  document.addEventListener('click', (e) => {
    if (e.target.classList.contains('modal-overlay') && e.target.id) closeModal(e.target.id);
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

  // ══════════════════════════════════════════════════════════════
  //  Shared caches
  // ══════════════════════════════════════════════════════════════
  let _allProjects = [];
  let _allMilestones = [];
  let _allIssues = [];
  let _allAreas = [];
  let _allViews = [];
  let _allLinks = [];
  let _allProjectTags = [];
  // Every issue on the current surface, unfiltered. The filtered list cannot
  // answer "what labels exist" or "how many are hidden" — once a filter is on,
  // it only knows about what survived it.
  let _facetIssues = [];
  let _currentProjectId = null;
  let _currentProject = null;
  // Areas and views are new tables; a client talking to an older server gets a
  // 404 for them. That is a degraded rail, not a broken page, so it is tracked
  // separately and shown as its own small error rather than taking the page.
  let _areasFailed = false;
  let _viewsFailed = false;
  // The rail's project list is the same on every page, so it is fetched once
  // and invalidated by hand when a project is created, renamed or filed.
  let _railProjects = null;

  function areaName(id) {
    if (!id) return 'No area';
    return _allAreas.find(a => a.id === id)?.name || 'Unknown area';
  }

  function projectName(id) {
    return _allProjects.find(p => p.id === id)?.name || 'Unknown project';
  }

  // ══════════════════════════════════════════════════════════════
  //  Areas — the project grouping
  // ══════════════════════════════════════════════════════════════
  async function loadAreas() {
    try {
      _allAreas = await api('GET', '/api/areas');
      _areasFailed = false;
    } catch {
      _allAreas = [];
      _areasFailed = true;
    }
    return _allAreas;
  }

  // Sections remember whether they were folded away, per area, because a rail
  // of twelve areas is only usable if the ones you never open stay shut.
  const AREA_COLLAPSE_KEY = 'graft_areas_collapsed';

  function collapsedAreas() {
    try { return new Set(JSON.parse(localStorage.getItem(AREA_COLLAPSE_KEY) || '[]')); }
    catch { return new Set(); }
  }

  async function createArea() {
    const r = await formDialog({
      title: 'New area',
      submitLabel: 'Create area',
      fields: [{ name: 'name', label: 'Name', placeholder: 'e.g. Client work' }],
    });
    if (!r || !r.name) return;
    try {
      await api('POST', '/api/areas', { name: r.name, sort_order: _allAreas.length });
      await loadAreas();
      toast('Area created');
      renderProjects();
      renderRail();
    } catch { toast('Could not create the area'); }
  }

  async function renameArea(id) {
    const area = _allAreas.find(a => a.id === id);
    if (!area) return;
    const r = await formDialog({
      title: 'Rename area',
      fields: [{ name: 'name', label: 'Name', value: area.name }],
    });
    if (!r || !r.name) return;
    const previous = area.name;
    area.name = r.name;
    renderProjects();
    renderRail();
    try {
      await api('PUT', `/api/areas/${id}`, { name: r.name });
    } catch {
      area.name = previous;
      renderProjects();
      renderRail();
      toast('Could not rename the area');
    }
  }

  // Deleting an area never deletes its projects — the server un-files them —
  // and the dialog has to say so, or nobody will ever press the button.
  async function deleteArea(id) {
    const area = _allAreas.find(a => a.id === id);
    if (!area) return;
    const inside = _allProjects.filter(p => p.area_id === id).length;
    const ok = await confirmDialog({
      title: 'Delete this area?',
      body: `<div class="confirm-text">“<span class="confirm-strong">${esc(area.name)}</span>” will be removed.</div>
             <div class="confirm-detail">${inside
               ? `Its ${inside} project${inside !== 1 ? 's' : ''} ${inside !== 1 ? 'are' : 'is'} kept — ${inside !== 1 ? 'they move' : 'it moves'} to “No area”.`
               : 'It has no projects in it.'}</div>`,
      confirmLabel: 'Delete area',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/areas/${id}`);
      _allProjects.forEach(p => { if (p.area_id === id) p.area_id = ''; });
      await loadAreas();
      toast('Area deleted — its projects were kept');
      renderProjects();
      renderRail();
    } catch { toast('Could not delete the area'); }
  }

  function _areaMenu(event, id) {
    event.stopPropagation();
    openMenu(event.currentTarget, [
      { label: 'New project in this area', onClick: () => openNewProject(id) },
      { label: 'Rename area', onClick: () => renameArea(id) },
      { label: 'Delete area', danger: true, onClick: () => deleteArea(id) },
    ]);
  }

  // ══════════════════════════════════════════════════════════════
  //  Links — a project's related URLs
  // ══════════════════════════════════════════════════════════════
  // These replace the half-built projects.repo_url, which had no UI at all.
  // repo_url is still in the schema for older clients; nothing here reads it.

  function linkHost(url) {
    try { return new URL(url).hostname.replace(/^www\./, ''); }
    catch { return String(url || '').replace(/^[a-z]+:\/\//i, '').split('/')[0]; }
  }

  // The kind is inferred from the hostname rather than asked for: a "type"
  // dropdown on a form whose only real field is a URL is a question the app
  // can answer itself.
  function linkKind(url) {
    const host = linkHost(url).toLowerCase();
    if (/(^|\.)(github\.com|gitlab\.com|bitbucket\.org|codeberg\.org|sr\.ht)$/.test(host)) return 'github';
    if (/(^|\.)(figma\.com|sketch\.com|dribbble\.com|excalidraw\.com|penpot\.app|framer\.com)$/.test(host)) return 'design';
    if (/(^|\.)(notion\.so|notion\.site|readthedocs\.io|gitbook\.io|gitbook\.com|readme\.io)$/.test(host)
        || /^docs?\./.test(host) || host.startsWith('docs.google.com')) return 'docs';
    if (/(^|\.)(vercel\.app|netlify\.app|fly\.dev|herokuapp\.com|onrender\.com|pages\.dev|railway\.app)$/.test(host)
        || /^(deploy|staging|status|ci)\./.test(host)) return 'deploy';
    return 'link';
  }

  // A url the user typed without a scheme is still a url they meant. Only the
  // three schemes that make sense for a link survive as-is: anything else —
  // javascript://x%0aalert(1) included — is treated as a hostname and ends up
  // behind https://, where it can only fail to resolve.
  function normaliseUrl(url) {
    const v = String(url || '').trim();
    if (!v) return '';
    if (/^(https?:\/\/|mailto:)/i.test(v)) return v;
    return `https://${v.replace(/^[a-z][a-z0-9+.-]*:\/*/i, '')}`;
  }

  async function loadLinks(projectId) {
    _allLinks = await api('GET', `/api/links?project_id=${encodeURIComponent(projectId)}`);
    return _allLinks;
  }

  function linkRow(l) {
    const kind = LINK_ICON[l.kind] ? l.kind : linkKind(l.url);
    const href = esc(normaliseUrl(l.url));
    return `<a class="link-row link-${esc(kind)}" href="${href}" target="_blank" rel="noopener noreferrer">
      <span class="link-row-icon" aria-hidden="true">${svg(LINK_ICON[kind], 15)}</span>
      <span class="link-row-label">${esc(l.label || linkHost(l.url))}</span>
      <span class="link-row-url">${esc(linkHost(l.url))}</span>
      <span class="link-row-actions">
        <span class="link-row-external" aria-hidden="true">${svg(EXTERNAL_ICON, 13)}</span>
        <button class="icon-btn" type="button" aria-haspopup="menu" title="Link actions"
                aria-label="Actions for ${esc(l.label || linkHost(l.url))}"
                onclick="event.preventDefault();event.stopPropagation();GRAFT._linkMenu(event,'${jsStr(l.id)}')">${svg(DOTS_ICON, 14)}</button>
      </span>
      <span class="sr-only">opens in a new tab</span>
    </a>`;
  }

  function renderLinks(containerId, projectId) {
    const el = document.getElementById(containerId);
    if (!el) return;
    el.innerHTML = `
      <div class="section-head">
        <h2 class="section-title">Links</h2>
        <span class="section-count">${_allLinks.length}</span>
        <div class="section-rule"></div>
      </div>
      <div class="link-list">
        ${_allLinks.map(l => linkRow(l)).join('')}
        <button class="link-add" type="button" onclick="GRAFT._addLink('${jsStr(projectId)}')">
          ${svg(NAV_ICONS.plus, 14)} Add link
        </button>
      </div>`;
  }

  async function _addLink(projectId) {
    const r = await formDialog({
      title: 'Add link',
      submitLabel: 'Add link',
      fields: [
        { name: 'url', label: 'URL', placeholder: 'github.com/you/thing' },
        { name: 'label', label: 'Label', placeholder: 'Repo', hint: 'Optional — the hostname is used if you leave it blank.' },
      ],
    });
    if (!r || !r.url) return;
    const url = normaliseUrl(r.url);
    const body = {
      project_id: projectId,
      url,
      label: r.label || linkHost(url),
      kind: linkKind(url),
      sort_order: _allLinks.length,
    };
    try {
      await api('POST', '/api/links', body);
      await loadLinks(projectId);
      refreshLinkSurfaces(projectId);
      toast('Link added');
    } catch { toast('Could not add the link'); }
  }

  function _linkMenu(event, id) {
    openMenu(event.currentTarget, [
      { label: 'Edit link', onClick: () => _editLink(id) },
      { label: 'Remove link', danger: true, onClick: () => _removeLink(id) },
    ]);
  }

  async function _editLink(id) {
    const link = _allLinks.find(l => l.id === id);
    if (!link) return;
    const r = await formDialog({
      title: 'Edit link',
      submitLabel: 'Save link',
      fields: [
        { name: 'url', label: 'URL', value: link.url },
        { name: 'label', label: 'Label', value: link.label },
      ],
    });
    if (!r || !r.url) return;
    const url = normaliseUrl(r.url);
    try {
      await api('PUT', `/api/links/${id}`, { url, label: r.label || linkHost(url), kind: linkKind(url) });
      await loadLinks(link.project_id);
      refreshLinkSurfaces(link.project_id);
      toast('Link saved');
    } catch { toast('Could not save the link'); }
  }

  // Removing is undoable rather than confirmed: the id is ours to supply, so
  // putting the link back is the same POST that created it.
  async function _removeLink(id) {
    const link = _allLinks.find(l => l.id === id);
    if (!link) return;
    const pid = link.project_id;
    try {
      await api('DELETE', `/api/links/${id}`);
      await loadLinks(pid);
      refreshLinkSurfaces(pid);
      undoToast(`Removed ${link.label || linkHost(link.url)}`, async () => {
        await api('POST', '/api/links', {
          id: link.id, project_id: pid, label: link.label, url: link.url,
          kind: link.kind, sort_order: link.sort_order,
        });
        await loadLinks(pid);
        refreshLinkSurfaces(pid);
      });
    } catch { toast('Could not remove the link'); }
  }

  // The same list can be on screen twice — the project page and the slide-over
  // behind it — so both are refreshed from the one cache.
  function refreshLinkSurfaces(projectId) {
    if (document.getElementById('project-links')) renderLinks('project-links', projectId);
    if (document.getElementById('so-links')) renderLinks('so-links', projectId);
  }

  // ══════════════════════════════════════════════════════════════
  //  Saved views
  // ══════════════════════════════════════════════════════════════
  async function loadViews() {
    try {
      _allViews = await api('GET', '/api/views');
      _viewsFailed = false;
    } catch {
      _allViews = [];
      _viewsFailed = true;
    }
    return _allViews;
  }

  // views.query is an opaque JSON blob both clients agree on. A server that
  // hands it back already parsed is just as valid as one that hands back the
  // string it stored, so both are accepted.
  function viewBlob(v) {
    if (!v) return orgDefaults();
    const raw = v.query;
    if (raw && typeof raw === 'object') return orgNormalise(raw);
    try { return orgNormalise(JSON.parse(raw || '{}')); }
    catch { return orgDefaults(); }
  }

  async function saveCurrentView() {
    const r = await formDialog({
      title: 'Save this view',
      submitLabel: 'Save view',
      fields: [{ name: 'name', label: 'Name', placeholder: 'e.g. My urgent work', value: suggestViewName() }],
    });
    if (!r || !r.name) return;
    try {
      await api('POST', '/api/views', {
        name: r.name,
        query: JSON.stringify(_org),
        sort_order: _allViews.length,
      });
      await loadViews();
      renderRail();
      toast('View saved');
    } catch { toast('Could not save the view'); }
  }

  // A name made from what is actually filtered beats an empty field.
  function suggestViewName() {
    const parts = [];
    if (_org.q) parts.push(`“${_org.q}”`);
    ORG_KEYS.forEach(k => {
      if (_org.filters[k]?.length) parts.push(filterValueLabel(k, _org.filters[k]));
    });
    return parts.slice(0, 2).join(' · ');
  }

  function applySavedView(id) {
    const view = _allViews.find(v => v.id === id);
    if (!view) return;
    const blob = viewBlob(view);
    // A saved view is a whole query, not a page. It lands on All issues, which
    // is the only surface that can honour every filter in the blob.
    const target = window._pageMode === 'issues' ? null : 'issues.html';
    if (target) {
      window.location.href = target + orgToURLString(blob);
      return;
    }
    _org = blob;
    orgPersist();
    orgWriteURL();
    renderOrgBar();
    orgApply();
  }

  async function deleteSavedView(id) {
    const view = _allViews.find(v => v.id === id);
    const ok = await confirmDialog({
      title: 'Delete this view?',
      body: `<div class="confirm-text">“<span class="confirm-strong">${esc(view?.name || 'This view')}</span>” will be removed.</div>
             <div class="confirm-detail">It is only a saved set of filters — no issues or projects are affected.</div>`,
      confirmLabel: 'Delete view',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/views/${id}`);
      await loadViews();
      renderRail();
      toast('View deleted');
    } catch { toast('Could not delete the view'); }
  }

  // ══════════════════════════════════════════════════════════════
  //  The rail — areas as a tree, then every project, then saved views
  // ══════════════════════════════════════════════════════════════
  async function renderRail() {
    const el = document.getElementById('sidebar-projects');
    if (!el) return;
    try {
      // Paused and done projects were invisible here — you could not navigate
      // to a project you had paused. Archived ones stay out.
      const projects = _railProjects || (_railProjects = await api('GET', '/api/projects'));
      const rank = { active: 0, paused: 1, done: 2 };
      const active = projects
        .filter(p => !p.archived)
        .sort((a, b) => (rank[a.status] ?? 3) - (rank[b.status] ?? 3));
      const current = new URLSearchParams(window.location.search).get('id');
      const collapsed = collapsedAreas();

      // Areas first, as a tree, so the rail mirrors how the projects page is
      // now grouped. A project with no area appears only in the flat list.
      const areaTree = _allAreas.map(a => {
        const inside = active.filter(p => p.area_id === a.id);
        const shut = collapsed.has(a.id);
        return `
          <div class="area-section${shut ? ' collapsed' : ''}">
            <button class="area-header" type="button" aria-expanded="${!shut}"
                    onclick="GRAFT._toggleRailArea('${jsStr(a.id)}')">
              <span class="area-dot" aria-hidden="true" ${a.colour ? `style="background:${esc(a.colour)}"` : ''}></span>
              <span class="area-header-name">${esc(a.name)}</span>
              <span class="area-header-count">${inside.length}</span>
            </button>
            ${shut ? '' : `<div class="area-section-body">${
              inside.length
                ? inside.map(p => railProjectItem(p, current)).join('')
                : `<div class="rail-empty">No projects</div>`
            }</div>`}
          </div>`;
      }).join('');

      el.innerHTML = `
        ${_allAreas.length ? `<div class="nav-section-label">Areas</div>${areaTree}` : ''}
        ${_areasFailed ? `<div class="nav-section-label">Areas</div>
          <div class="rail-error">Couldn’t load areas.
            <button class="chip-clear" type="button" onclick="GRAFT._retryRail()">Retry</button></div>` : ''}
        ${active.length ? `<div class="nav-section-label">Projects</div>
          ${active.map(p => railProjectItem(p, current)).join('')}`
          : `<div class="nav-section-label">Projects</div>
             <div class="rail-empty">No projects yet.
               <a href="index.html">Create one</a></div>`}
        ${renderRailViews()}
      `;
      syncDrawer();
    } catch {
      // A failed load used to be indistinguishable from having no projects:
      // catch { el.innerHTML = '' }. Say what happened and offer the way back.
      el.innerHTML = `
        <div class="nav-section-label">Projects</div>
        <div class="rail-error">Couldn’t load your projects.
          <button class="chip-clear" type="button" onclick="GRAFT._retryRail()">Retry</button>
        </div>`;
      syncDrawer();
    }
  }

  function railProjectItem(p, current) {
    const c = p.issue_counts || {};
    const open = (c.backlog || 0) + (c.todo || 0) + (c.in_progress || 0) + (c.review || 0);
    return `
      <a href="project.html?id=${esc(p.id)}" class="nav-item${p.id === current ? ' active' : ''}"
         ${p.status !== 'active' ? `title="${esc(p.name)} — ${esc(p.status)}" style="opacity:.7"` : ''}>
        ${p.icon ? `<span class="nav-project-icon">${esc(p.icon)}</span>`
                 : `<span class="nav-project-dot" style="background:${esc(p.colour)}"></span>`}
        ${esc(p.name)}
        ${open ? `<span style="margin-left:auto;font-size:11.5px;color:var(--dim)">${open}</span>` : ''}
      </a>`;
  }

  function renderRailViews() {
    if (_viewsFailed) {
      return `<div class="nav-section-label">Views</div>
        <div class="rail-error">Couldn’t load saved views.
          <button class="chip-clear" type="button" onclick="GRAFT._retryRail()">Retry</button></div>`;
    }
    if (!_allViews.length) return '';
    return `<div class="nav-section-label">Views</div>
      ${_allViews.map(v => `
        <div class="view-item">
          <button class="view-item-name" type="button" onclick="GRAFT._applyView('${jsStr(v.id)}')">
            ${svg(STAR_ICON, 14)} ${esc(v.name)}
          </button>
          <span class="view-item-actions">
            <button class="icon-btn" type="button" title="Delete view"
                    aria-label="Delete view ${esc(v.name)}"
                    onclick="GRAFT._deleteView('${jsStr(v.id)}')">${svg(NAV_ICONS.close, 13)}</button>
          </span>
        </div>`).join('')}`;
  }

  function _toggleRailArea(id) {
    const set = collapsedAreas();
    if (set.has(id)) set.delete(id); else set.add(id);
    try { localStorage.setItem(AREA_COLLAPSE_KEY, JSON.stringify([...set])); } catch { /* private mode */ }
    renderRail();
    if (window._pageMode === 'projects') renderProjects();
  }

  async function _retryRail() {
    _railProjects = null;
    await Promise.all([loadAreas(), loadViews()]);
    renderRail();
  }

  // ══════════════════════════════════════════════════════════════
  //  Menus — one popover for every dropdown in the client
  // ══════════════════════════════════════════════════════════════
  function closeMenus() {
    document.querySelectorAll('.popover').forEach(p => p.remove());
  }

  function openMenu(anchorEl, items, { label = '', above = false } = {}) {
    closeMenus();
    const pop = document.createElement('div');
    pop.className = 'popover';
    pop.setAttribute('role', 'menu');
    pop.innerHTML = (label ? `<div class="popover-label">${esc(label)}</div>` : '') +
      items.map((it, n) => it.separator
        ? `<div class="popover-sep"></div>`
        : `<button class="popover-item${it.danger ? ' popover-item-danger' : ''}" type="button" data-n="${n}"
             ${it.checked !== undefined ? `role="menuitemcheckbox" aria-checked="${!!it.checked}"` : 'role="menuitem"'}>
            ${it.icon || ''}<span>${esc(it.label)}</span>
            ${it.checked !== undefined ? `<span class="popover-check">${svg('<path d="m5 12 5 5 9-10"/>', 14)}</span>` : ''}
          </button>`).join('');
    document.body.appendChild(pop);
    positionPopover(pop, anchorEl, above);
    pop.querySelectorAll('[data-n]').forEach(b => {
      const it = items[+b.dataset.n];
      b.onclick = ev => {
        ev.stopPropagation();
        if (!it.keepOpen) pop.remove();
        it.onClick?.(b);
      };
    });
    dismissOnOutsideClick(pop);
    return pop;
  }

  function positionPopover(pop, anchorEl, above = false) {
    const r = anchorEl.getBoundingClientRect();
    const top = above
      ? r.top + window.scrollY - pop.offsetHeight - 8
      : Math.min(r.bottom + 6, window.innerHeight - pop.offsetHeight - 12) + window.scrollY;
    pop.style.top = `${Math.max(8, top)}px`;
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

  // ══════════════════════════════════════════════════════════════
  //  The organisation bar
  // ══════════════════════════════════════════════════════════════
  // [search ⌘K] [chips…] [+ Filter] ⟨spacer⟩ [Group ▾] [Sort ▾] [view] [☆]
  //
  // There used to be three filtering paradigms — a pill bar on projects, a
  // chip-and-popover system on all-issues, a milestone pill bar on a project —
  // and "archived" was rendered three different ways between them. This is the
  // only one now, identical on all three surfaces, and it is the first place
  // labels have ever been filterable despite being drawn on every row.

  const ORG_KEYS = ['status', 'priority', 'assignee', 'label', 'project_id', 'milestone_id', 'area_id', 'tag'];

  const FILTER_LABELS = {
    status: 'Status', priority: 'Priority', assignee: 'Assignee', label: 'Label',
    project_id: 'Project', milestone_id: 'Milestone', area_id: 'Area', tag: 'Tag',
  };

  const SORT_LABELS = {
    manual: 'Manual', updated: 'Updated', created: 'Created', priority: 'Priority',
    title: 'Title', status: 'Status', milestone_due: 'Milestone due', area: 'Area',
  };

  const GROUP_LABELS = {
    none: 'None', status: 'Status', priority: 'Priority', assignee: 'Assignee',
    milestone: 'Milestone', project: 'Project', area: 'Area',
  };

  const ALL_SORTS = ['manual', 'updated', 'created', 'priority', 'title', 'status', 'milestone_due', 'area'];
  const ALL_GROUPS = ['none', 'status', 'priority', 'assignee', 'milestone', 'project', 'area'];

  function orgDefaults() {
    return {
      q: '',
      filters: { status: [], priority: [], assignee: [], label: [], project_id: [], milestone_id: [], area_id: [], tag: [] },
      archived: false,
      sort: 'manual',
      dir: 'asc',
      group: 'none',
    };
  }

  function orgNormalise(blob) {
    const out = orgDefaults();
    if (!blob || typeof blob !== 'object') return out;
    out.q = typeof blob.q === 'string' ? blob.q : '';
    ORG_KEYS.forEach(k => {
      const v = blob.filters?.[k];
      out.filters[k] = Array.isArray(v) ? v.map(String).filter(Boolean) : [];
    });
    out.archived = !!blob.archived;
    out.sort = ALL_SORTS.includes(blob.sort) ? blob.sort : 'manual';
    out.dir = blob.dir === 'desc' ? 'desc' : 'asc';
    out.group = ALL_GROUPS.includes(blob.group) ? blob.group : 'none';
    return out;
  }

  let _org = orgDefaults();
  let _orgName = null;      // which surface's config is mounted
  let _orgSearchTimer = null;

  // Each surface declares which filters make sense on it and what a "view" is
  // there. Everything else about the bar is identical.
  const ORG_SURFACES = {
    projects: {
      noun: 'projects',
      placeholder: 'Search projects…',
      keys: ['status', 'area_id', 'tag'],
      // Priority and milestone-due are issue properties; offering them as a
      // project sort would be a menu item that does nothing.
      sorts: ['manual', 'updated', 'created', 'title', 'status', 'area'],
      groups: ['none', 'status', 'area'],
      views: [['grid', 'Grid'], ['list', 'List']],
      // Archived projects are a different set of rows, not a different way of
      // drawing the ones already here, so this refetches.
      apply: () => loadProjects(),
    },
    issues: {
      noun: 'issues',
      placeholder: 'Search issues…',
      keys: ORG_KEYS,
      sorts: ALL_SORTS,
      groups: ALL_GROUPS,
      views: [['list', 'List'], ['board', 'Board']],
      apply: () => loadIssuesPage(),
    },
    project: {
      noun: 'issues',
      placeholder: 'Search this project…',
      // project_id and area_id are fixed by the page you are on.
      keys: ['status', 'priority', 'assignee', 'label', 'milestone_id'],
      sorts: ALL_SORTS,
      groups: ['none', 'status', 'priority', 'assignee', 'milestone'],
      views: [['board', 'Board'], ['list', 'List']],
      apply: () => loadProjectIssues(),
    },
  };

  function orgSurface() { return ORG_SURFACES[_orgName] || ORG_SURFACES.issues; }

  // ── State in the URL, and surviving the trip to the next page ──
  // The URL is the shareable copy. localStorage is why the state no longer
  // resets the moment you click through to a project and back.
  function orgStorageKey() { return `graft_org_${_orgName}`; }

  function orgFromURL() {
    const q = new URLSearchParams(window.location.search);
    const hasAny = ['q', 'archived', 'sort', 'dir', 'group', ...ORG_KEYS].some(k => q.has(k));
    if (!hasAny) return null;
    const blob = orgDefaults();
    blob.q = q.get('q') || '';
    ORG_KEYS.forEach(k => {
      const v = q.get(k);
      blob.filters[k] = v ? v.split(',').filter(Boolean) : [];
    });
    blob.archived = q.get('archived') === '1';
    blob.sort = q.get('sort') || 'manual';
    blob.dir = q.get('dir') || 'asc';
    blob.group = q.get('group') || 'none';
    return orgNormalise(blob);
  }

  function orgToURLString(blob) {
    const q = new URLSearchParams();
    if (blob.q) q.set('q', blob.q);
    ORG_KEYS.forEach(k => { if (blob.filters[k]?.length) q.set(k, blob.filters[k].join(',')); });
    if (blob.archived) q.set('archived', '1');
    if (blob.sort !== 'manual') q.set('sort', blob.sort);
    if (blob.dir !== 'asc') q.set('dir', blob.dir);
    if (blob.group !== 'none') q.set('group', blob.group);
    const s = q.toString();
    return s ? `?${s}` : '';
  }

  function orgWriteURL() {
    // Start from what is already there so the project id and any ?issue=
    // deep link survive a filter change.
    const q = new URLSearchParams(window.location.search);
    ['q', 'archived', 'sort', 'dir', 'group', ...ORG_KEYS].forEach(k => q.delete(k));
    if (_org.q) q.set('q', _org.q);
    ORG_KEYS.forEach(k => { if (_org.filters[k].length) q.set(k, _org.filters[k].join(',')); });
    if (_org.archived) q.set('archived', '1');
    if (_org.sort !== 'manual') q.set('sort', _org.sort);
    if (_org.dir !== 'asc') q.set('dir', _org.dir);
    if (_org.group !== 'none') q.set('group', _org.group);
    const s = q.toString();
    history.replaceState(null, '', s ? `?${s}` : window.location.pathname);
  }

  function orgPersist() {
    try { localStorage.setItem(orgStorageKey(), JSON.stringify(_org)); } catch { /* private mode */ }
  }

  function orgInit(name) {
    _orgName = name;
    const fromURL = orgFromURL();
    if (fromURL) {
      _org = fromURL;
    } else {
      try { _org = orgNormalise(JSON.parse(localStorage.getItem(orgStorageKey()) || 'null')); }
      catch { _org = orgDefaults(); }
      // Areas are what the projects page is for, so that is where it starts.
      if (name === 'projects' && !localStorage.getItem(orgStorageKey())) _org.group = 'area';
    }
    orgPersist();
    orgWriteURL();
  }

  // ── Talking to the server ──────────────────────────────────────
  // Every filter here is a real query parameter; nothing is filtered twice.
  function orgQuery(extra = {}) {
    const q = new URLSearchParams();
    if (_org.q) q.set('q', _org.q);
    ORG_KEYS.forEach(k => { if (_org.filters[k].length) q.set(k, _org.filters[k].join(',')); });
    if (_org.archived) q.set('archived', '1');
    q.set('sort', _org.sort);
    q.set('dir', _org.dir);
    Object.entries(extra).forEach(([k, v]) => { if (v !== undefined && v !== null && v !== '') q.set(k, v); });
    const s = q.toString();
    return s ? `?${s}` : '';
  }

  function orgActiveCount() {
    return orgSurface().keys.reduce((n, k) => n + (_org.filters[k].length ? 1 : 0), 0)
      + (_org.archived ? 1 : 0);
  }

  function orgIsFiltering() { return orgActiveCount() > 0 || !!_org.q; }

  // ── Option sets ────────────────────────────────────────────────
  function filterOptions(key) {
    if (key === 'status') {
      return _orgName === 'projects'
        ? PROJECT_STATUSES.map(v => ({ v, label: PROJECT_STATUS_LABELS[v] }))
        : STATUSES.map(v => ({ v, label: STATUS_LABELS[v], icon: statusIcon(v, 15) }));
    }
    if (key === 'priority') return PRIORITIES.map(v => ({ v, label: PRIORITY_LABELS[v] }));
    // These two are drawn from the unfiltered set: filtering by one label must
    // not remove every other label from the menu you are standing in.
    const vocabulary = _facetIssues.length ? _facetIssues : _allIssues;
    if (key === 'assignee') {
      // No "Unassigned" option: the server's multi-value reader drops empty
      // fragments, so ?assignee= would silently mean "no filter at all".
      return [...new Set(vocabulary.map(i => i.assignee).filter(Boolean))].sort()
        .map(v => ({ v, label: v }));
    }
    if (key === 'label') {
      const seen = new Set();
      vocabulary.forEach(i => (i.labels || []).forEach(l => seen.add(l)));
      return [...seen].sort().map(v => ({ v, label: v }));
    }
    if (key === 'project_id') return _allProjects.map(p => ({ v: p.id, label: p.name }));
    if (key === 'milestone_id') {
      const ms = _orgName === 'project'
        ? _allMilestones.filter(m => m.project_id === _currentProjectId)
        : _allMilestones;
      return [{ v: 'none', label: 'No milestone' }, ...ms.map(m => ({ v: m.id, label: m.name }))];
    }
    if (key === 'area_id') {
      return [{ v: 'none', label: 'No area' }, ..._allAreas.map(a => ({ v: a.id, label: a.name }))];
    }
    return [];
  }

  function filterValueLabel(key, values) {
    const opts = filterOptions(key);
    return values.map(v => opts.find(o => String(o.v) === String(v))?.label || v).join(', ');
  }

  // Reads back as a sentence, for the zero-results state and the view name.
  function orgFilterSummary() {
    const parts = orgSurface().keys
      .filter(k => _org.filters[k].length)
      .map(k => `${FILTER_LABELS[k]} is ${filterValueLabel(k, _org.filters[k])}`);
    if (_org.archived) parts.push('archived included');
    if (_org.q) parts.unshift(`search “${_org.q}”`);
    return parts.join(', ');
  }

  // ── Rendering ──────────────────────────────────────────────────
  function renderOrgBar() {
    const bar = document.getElementById('org-bar');
    if (!bar) return;
    const s = orgSurface();
    const chips = s.keys.filter(k => _org.filters[k].length).map(k => `
      <span class="chip">
        <span class="chip-key">${esc(FILTER_LABELS[k])}</span> is
        <span class="chip-val">${esc(filterValueLabel(k, _org.filters[k]))}</span>
        <button class="chip-x" type="button" aria-label="Remove ${esc(FILTER_LABELS[k])} filter"
                onclick="GRAFT._clearFilter('${k}')">${svg(NAV_ICONS.close, 11, 'stroke-width="2.5"')}</button>
      </span>`).join('');

    const archivedChip = _org.archived ? `
      <span class="chip">
        <span class="chip-key">Archived</span> <span class="chip-val">included</span>
        <button class="chip-x" type="button" aria-label="Stop including archived"
                onclick="GRAFT._toggleArchived()">${svg(NAV_ICONS.close, 11, 'stroke-width="2.5"')}</button>
      </span>` : '';

    bar.innerHTML = `
      <div class="org-search">
        <span class="org-search-icon" aria-hidden="true">${svg(NAV_ICONS.search, 14)}</span>
        <input type="search" class="search-input org-search-input" id="org-q"
               value="${esc(_org.q)}" placeholder="${esc(s.placeholder)}"
               aria-label="${esc(s.placeholder)}" autocomplete="off" spellcheck="false">
        <span class="kbd" aria-hidden="true">⌘K</span>
      </div>
      <div class="org-chips">
        ${chips}${archivedChip}
        <button class="chip-add" type="button" id="org-add-filter" aria-haspopup="menu">
          ${svg(NAV_ICONS.plus, 13, 'stroke-width="2.5"')} Filter
        </button>
        ${orgIsFiltering() ? `<button class="chip-clear" type="button" onclick="GRAFT._clearAllFilters()">Clear all</button>` : ''}
      </div>
      <span class="org-spacer" style="flex:1"></span>
      <span class="org-sep" aria-hidden="true"></span>
      <button class="org-control" type="button" id="org-group" aria-haspopup="menu">
        <span class="org-control-label">Group</span>${esc(GROUP_LABELS[_org.group])}${svg(CHEVRON_DOWN, 12)}
      </button>
      <button class="org-control" type="button" id="org-sort" aria-haspopup="menu">
        <span class="org-control-label">Sort</span>${esc(SORT_LABELS[_org.sort])}${svg(CHEVRON_DOWN, 12)}
      </button>
      <button class="org-dir" type="button" id="org-dir"
              title="${_org.dir === 'asc' ? 'Ascending' : 'Descending'}"
              aria-label="Sort direction: ${_org.dir === 'asc' ? 'ascending' : 'descending'}">${
        _org.dir === 'asc'
          ? svg('<path d="M12 19V5"/><path d="m5 12 7-7 7 7"/>', 14)
          : svg('<path d="M12 5v14"/><path d="m5 12 7 7 7-7"/>', 14)
      }</button>
      ${s.views.length > 1 ? `<div class="view-toggle" role="tablist" aria-label="View">
        ${s.views.map(([v, label]) => `
          <button class="view-btn${_viewMode === v ? ' active' : ''}" type="button" role="tab"
                  aria-selected="${_viewMode === v}" onclick="GRAFT.setView('${v}')">${esc(label)}</button>`).join('')}
      </div>` : ''}
      <button class="org-control" type="button" id="org-save" title="Save this view as a named view"
              aria-label="Save this view">${svg(STAR_ICON, 14)}<span class="org-save-label">Save view</span></button>
      <div class="org-count result-count" id="org-count" aria-live="polite"></div>`;

    const input = bar.querySelector('#org-q');
    input.addEventListener('input', e => _onSearchInput(e.target.value));
    bar.querySelector('#org-add-filter').onclick = e => _openFilterMenu(e.currentTarget);
    bar.querySelector('#org-group').onclick = e => _openGroupMenu(e.currentTarget);
    bar.querySelector('#org-sort').onclick = e => _openSortMenu(e.currentTarget);
    bar.querySelector('#org-dir').onclick = () => _toggleSortDir();
    bar.querySelector('#org-save').onclick = () => saveCurrentView();
  }

  function _toggleSortDir() {
    _org.dir = _org.dir === 'asc' ? 'desc' : 'asc';
    orgPersist(); orgWriteURL(); renderOrgBar(); orgApply();
  }

  // Typing must not rebuild the bar — that would take the caret with it — so
  // the search box updates the state and the results, and nothing else.
  function _onSearchInput(value) {
    _org.q = value;
    clearTimeout(_orgSearchTimer);
    _orgSearchTimer = setTimeout(() => {
      orgPersist();
      orgWriteURL();
      const clear = document.querySelector('#org-bar .chip-clear');
      if (orgIsFiltering() && !clear) renderOrgBar();
      else if (!orgIsFiltering() && clear) renderOrgBar();
      orgApply();
    }, 220);
  }

  function orgApply() { orgSurface().apply(); }

  function _openFilterMenu(anchor) {
    const s = orgSurface();
    const items = s.keys.map(k => ({
      label: FILTER_LABELS[k],
      onClick: () => _openFilterValues(anchor, k),
    }));
    items.push({ separator: true });
    items.push({
      label: 'Include archived',
      checked: _org.archived,
      keepOpen: false,
      onClick: () => _toggleArchived(),
    });
    openMenu(anchor, items, { label: 'Filter by' });
  }

  function _openFilterValues(anchor, key) {
    const opts = filterOptions(key);
    if (!opts.length) {
      openMenu(anchor, [{ label: `Nothing to filter by yet`, onClick: () => {} }], { label: FILTER_LABELS[key] });
      return;
    }
    // Multi-value everywhere: every one of these hits an IN (...) on the
    // server, so "status is todo or review" is one request, not two.
    const items = opts.map(o => ({
      label: o.label,
      icon: o.icon || '',
      checked: _org.filters[key].includes(String(o.v)),
      keepOpen: true,
      onClick: (btn) => {
        const list = _org.filters[key];
        const at = list.indexOf(String(o.v));
        if (at >= 0) list.splice(at, 1); else list.push(String(o.v));
        btn.setAttribute('aria-checked', String(list.includes(String(o.v))));
        orgPersist();
        orgWriteURL();
        renderOrgBarChipsOnly();
        orgApply();
      },
    }));
    openMenu(anchor, items, { label: FILTER_LABELS[key] });
  }

  // The chips change while a value menu stays open, so only they are redrawn.
  function renderOrgBarChipsOnly() {
    const bar = document.getElementById('org-bar');
    if (!bar) return;
    const focused = document.activeElement === bar.querySelector('#org-q');
    const caret = focused ? bar.querySelector('#org-q').selectionStart : null;
    renderOrgBar();
    if (focused) {
      const input = bar.querySelector('#org-q');
      input.focus();
      if (caret !== null) input.setSelectionRange(caret, caret);
    }
  }

  function _openGroupMenu(anchor) {
    const s = orgSurface();
    openMenu(anchor, s.groups.map(g => ({
      label: GROUP_LABELS[g],
      checked: _org.group === g,
      onClick: () => { _org.group = g; orgPersist(); orgWriteURL(); renderOrgBar(); orgApply(); },
    })), { label: 'Group by' });
  }

  function _openSortMenu(anchor) {
    const s = orgSurface();
    const items = s.sorts.map(v => ({
      label: SORT_LABELS[v],
      checked: _org.sort === v,
      onClick: () => { _org.sort = v; orgPersist(); orgWriteURL(); renderOrgBar(); orgApply(); },
    }));
    items.push({ separator: true });
    items.push({
      label: _org.dir === 'asc' ? 'Ascending' : 'Descending',
      onClick: () => _toggleSortDir(),
    });
    openMenu(anchor, items, { label: 'Sort by' });
  }

  function _clearFilter(key) {
    _org.filters[key] = [];
    orgPersist(); orgWriteURL(); renderOrgBar(); orgApply();
  }

  function _clearAllFilters() {
    const keep = { sort: _org.sort, dir: _org.dir, group: _org.group };
    _org = Object.assign(orgDefaults(), keep);
    orgPersist(); orgWriteURL(); renderOrgBar(); orgApply();
  }

  function _toggleArchived() {
    _org.archived = !_org.archived;
    orgPersist(); orgWriteURL(); renderOrgBar(); orgApply();
  }

  function orgCount(shown, total) {
    const el = document.getElementById('org-count');
    if (!el) return;
    const noun = orgSurface().noun;
    el.innerHTML = shown === total
      ? `<strong>${total}</strong> ${esc(noun)}`
      : `Showing <strong>${shown}</strong> of ${total} ${esc(noun)} · ${orgActiveCount() + (_org.q ? 1 : 0)} filter${
          orgActiveCount() + (_org.q ? 1 : 0) !== 1 ? 's' : ''} active`;
  }

  // ── The view switcher ──────────────────────────────────────────
  let _viewMode = 'board';

  function viewStorageKey() { return _orgName === 'project' ? 'graft_view' : `graft_view_${_orgName}`; }

  function initViewMode(name) {
    const allowed = (ORG_SURFACES[name] || ORG_SURFACES.issues).views.map(v => v[0]);
    let saved = null;
    try { saved = localStorage.getItem(viewStorageKey()); } catch { saved = null; }
    _viewMode = allowed.includes(saved) ? saved : allowed[0];
  }

  function setView(view) {
    _viewMode = view;
    try { localStorage.setItem(viewStorageKey(), view); } catch { /* private mode */ }
    renderOrgBar();
    rerenderCurrentView();
  }

  // ── Grouping, client-side ──────────────────────────────────────
  // The API returns one flat ordered list; the sections are drawn here so a
  // regroup costs nothing and never loses the server's ordering inside a group.
  const GROUP_ORDER = {
    status: STATUSES,
    priority: PRIORITIES,
  };

  function groupKeyOf(item, group) {
    if (group === 'status') return item.status || 'backlog';
    if (group === 'priority') return item.priority || 'normal';
    if (group === 'assignee') return item.assignee || '';
    if (group === 'milestone') return item.milestone_id || '';
    if (group === 'project') return item.project_id || '';
    if (group === 'area') {
      if (item.area_id !== undefined) return item.area_id || '';
      return _allProjects.find(p => p.id === item.project_id)?.area_id || '';
    }
    return '';
  }

  function groupLabelOf(key, group) {
    if (group === 'status') return STATUS_LABELS[key] || key;
    if (group === 'priority') return PRIORITY_LABELS[key] || key;
    if (group === 'assignee') return key || 'Unassigned';
    if (group === 'milestone') return key ? (_allMilestones.find(m => m.id === key)?.name || 'Unknown milestone') : 'No milestone';
    if (group === 'project') return key ? projectName(key) : 'No project';
    if (group === 'area') return areaName(key);
    return '';
  }

  function groupItems(items, group) {
    if (!group || group === 'none') return [{ key: '', label: '', rows: items }];
    const map = new Map();
    items.forEach(i => {
      const k = groupKeyOf(i, group);
      if (!map.has(k)) map.set(k, []);
      map.get(k).push(i);
    });
    let keys = [...map.keys()];
    const order = GROUP_ORDER[group];
    if (order) {
      keys.sort((a, b) => order.indexOf(a) - order.indexOf(b));
    } else {
      // Empty buckets — unassigned, no milestone, no area — read as a tail,
      // not as a section called "".
      keys.sort((a, b) => {
        if (!a) return 1;
        if (!b) return -1;
        return groupLabelOf(a, group).localeCompare(groupLabelOf(b, group));
      });
    }
    return keys.map(k => ({ key: k, label: groupLabelOf(k, group), rows: map.get(k) }));
  }

  function groupHead(label, count) {
    return `<div class="section-head" style="margin:16px 0 8px">
      <span class="section-title" style="font-size:12.5px">${esc(label)}</span>
      <span class="section-count">${count}</span>
      <div class="section-rule"></div>
    </div>`;
  }

  // ══════════════════════════════════════════════════════════════
  //  Issue card / row rendering
  // ══════════════════════════════════════════════════════════════
  function renderKanbanCard(issue, opts = {}) {
    const labels = (issue.labels || []).slice(0, 2).map(l => `<span class="label-chip">${esc(l)}</span>`).join('');
    const showProject = opts.showProject && issue.project_name
      ? `<span class="assignee-chip">${esc(issue.project_name)}</span>` : '';
    const urgent = issue.priority === 'urgent' || issue.priority === 'high';
    const id = jsStr(issue.id);
    return `
      <div class="kanban-card"
           data-priority="${esc(issue.priority)}"
           data-id="${esc(issue.id)}"
           draggable="true"
           tabindex="0"
           role="button"
           aria-label="${esc(issue.title)}"
           onclick="GRAFT.openIssueSlideover('${id}')"
           onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();GRAFT.openIssueSlideover('${id}')}"
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
    const id = jsStr(issue.id);
    const showProject = opts.showProject && issue.project_name
      ? `<span class="issue-row-project">${esc(issue.project_name)}</span>` : '';
    const labels = (issue.labels || []).slice(0, 2).map(l => `<span class="label-chip">${esc(l)}</span>`).join('');
    const extra = (issue.labels || []).length > 2
      ? `<span class="label-chip label-chip-more">+${(issue.labels || []).length - 2}</span>` : '';
    const archivedClass = issue.archived ? ' issue-row-archived' : '';
    const selected = _selection.has(issue.id) ? ' selected' : '';
    const check = opts.selectable === false ? '' : `
      <input type="checkbox" class="row-check" ${_selection.has(issue.id) ? 'checked' : ''}
             aria-label="Select ${esc(issue.title)}"
             onclick="event.stopPropagation();GRAFT._toggleSelect('${id}',this.checked)">`;
    return `
      <div class="issue-row${archivedClass}${selected}" data-priority="${esc(issue.priority)}" data-id="${esc(issue.id)}"
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
          ${labels}${extra}
          ${priorityBadge(issue.priority)}
          ${showProject}
          ${avatar(issue.assignee)}
        </div>
      </div>`;
  }

  // Draws a set of issues into a container as list or board, honouring the
  // organisation bar's grouping. Every list surface goes through here, so the
  // states below are the same states everywhere.
  function renderIssueSurface(el, issues, { showProject = false, board = false } = {}) {
    if (!el) return;
    if (board) {
      renderBoardInto(el, issues, { showProject });
    } else {
      const groups = groupItems(issues, _org.group);
      el.innerHTML = groups.map(g =>
        (g.label ? groupHead(g.label, g.rows.length) : '') +
        g.rows.map(i => renderIssueRow(i, { showProject })).join('')).join('');
    }
    pruneSelection(issues.map(i => i.id));
  }

  // ── Inline status menu ──────────────────────────────────────────
  function _openStatusMenu(event, id) {
    const issue = _issue(id);
    if (!issue) return;
    openMenu(event.currentTarget, STATUSES.map(st => ({
      label: STATUS_LABELS[st],
      icon: statusIcon(st, 15),
      checked: issue.status === st,
      onClick: () => setIssueStatus(id, st),
    })), { label: 'Move to' });
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

  // A bulk action used to fire on rows a filter had since hidden: select five,
  // change the filters, and the bar still acted on the ones off screen. The
  // selection is now pruned to what is actually drawn, every render.
  function pruneSelection(visibleIds) {
    if (!_selection.size) return;
    const keep = new Set(visibleIds);
    let changed = false;
    [..._selection].forEach(id => {
      if (!keep.has(id)) { _selection.delete(id); changed = true; }
    });
    if (changed) renderBulkBar();
  }

  function renderBulkBar() {
    let bar = document.getElementById('bulk-bar');
    if (!_selection.size) { bar?.remove(); return; }
    if (!bar) {
      bar = document.createElement('div');
      bar.id = 'bulk-bar';
      bar.className = 'bulk-bar';
      bar.setAttribute('role', 'toolbar');
      bar.setAttribute('aria-label', 'Bulk actions');
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
    openMenu(event.currentTarget, STATUSES.map(st => ({
      label: STATUS_LABELS[st],
      icon: statusIcon(st, 15),
      onClick: () => _bulkSetStatus(st),
    })), { label: `Move ${_selection.size} to`, above: true });
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

  function rerenderCurrentView() {
    if (window._pageMode === 'project') renderProjectIssues();
    else if (window._pageMode === 'issues') renderIssuesPage();
    else if (window._pageMode === 'today') renderToday();
    else if (window._pageMode === 'projects') renderProjects();
  }

  // ══════════════════════════════════════════════════════════════
  //  Issue modal
  // ══════════════════════════════════════════════════════════════
  async function loadMilestonesForProject() {
    const pid = document.getElementById('issue-project')?.value || _currentProjectId;
    const sel = document.getElementById('issue-milestone');
    if (!sel) return;
    sel.innerHTML = '<option value="">No milestone</option>';
    if (!pid) return;
    _allMilestones.filter(m => m.project_id === pid).forEach(m => {
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
    if (!issue) return;
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
    const msSel = document.getElementById('issue-milestone');
    if (msSel && issue.milestone_id) msSel.value = issue.milestone_id;
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
    } catch {
      toast('Could not save the issue — nothing was lost, try again');
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

  // ══════════════════════════════════════════════════════════════
  //  Issue slide-over
  // ══════════════════════════════════════════════════════════════
  let _slideoverIssueId = null;

  async function openIssueSlideover(id) {
    const issue = _allIssues.find(i => i.id === id);
    if (!issue) return;
    _slideoverIssueId = id;
    document.getElementById('detail-id').textContent = id.replace('iss_', '#');

    const msOptions = _allMilestones
      .filter(m => m.project_id === issue.project_id)
      .map(m => `<option value="${esc(m.id)}" ${issue.milestone_id === m.id ? 'selected' : ''}>${esc(m.name)}</option>`)
      .join('');

    document.getElementById('slideover-body').innerHTML = `
      <div class="so-field">
        <div class="so-title"
             contenteditable="true"
             role="textbox"
             aria-label="Issue title"
             data-field="title"
             onblur="GRAFT._soSave()"
             onkeydown="if(event.key==='Enter'){event.preventDefault();this.blur();}"
        >${esc(issue.title)}</div>
      </div>

      <div class="so-field">
        <div class="so-desc"
             contenteditable="true"
             role="textbox"
             aria-label="Description"
             data-field="description"
             onblur="GRAFT._soSave()"
             placeholder="Add a description…"
        >${esc(issue.description || '')}</div>
      </div>

      <div class="so-meta">
        <div class="so-meta-row">
          <span class="so-label">Status</span>
          <select class="so-select" aria-label="Status" data-field="status" onchange="GRAFT._soSave()">
            ${STATUSES.map(st => `<option value="${st}" ${issue.status === st ? 'selected' : ''}>${STATUS_LABELS[st]}</option>`).join('')}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Priority</span>
          <select class="so-select" aria-label="Priority" data-field="priority" onchange="GRAFT._soSave()">
            ${PRIORITIES.map(p => `<option value="${p}" ${issue.priority === p ? 'selected' : ''}>${PRIORITY_LABELS[p]}</option>`).join('')}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Assignee</span>
          <input class="so-input" data-field="assignee" aria-label="Assignee"
                 value="${esc(issue.assignee || '')}"
                 placeholder="Unassigned"
                 onblur="GRAFT._soSave()">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Milestone</span>
          <select class="so-select" aria-label="Milestone" data-field="milestone_id" onchange="GRAFT._soSave()">
            <option value="">None</option>
            ${msOptions}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Labels</span>
          <input class="so-input" data-field="labels" aria-label="Labels"
                 value="${esc((issue.labels || []).join(', '))}"
                 placeholder="bug, frontend…"
                 onblur="GRAFT._soSave()">
        </div>
      </div>

      <div class="so-footer">
        <button class="btn btn-ghost btn-sm" type="button" onclick="GRAFT._archiveIssueFromSlideover('${jsStr(id)}')"
                title="${issue.archived ? 'Unarchive' : 'Archive'}">
          ${issue.archived ? '↩ Unarchive' : '⊘ Archive'}
        </button>
        <button class="btn btn-ghost btn-danger btn-sm" type="button" onclick="GRAFT._deleteIssueFromSlideover('${jsStr(id)}')">Delete issue</button>
      </div>

      <div class="so-project-section">
        <div class="so-project-header" role="button" tabindex="0"
             onclick="GRAFT._toggleProjectSection()"
             onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();GRAFT._toggleProjectSection()}"
             id="so-project-toggle" aria-expanded="false">
          <span class="so-project-label">Project — ${esc(_allProjects.find(p => p.id === issue.project_id)?.name || '')}</span>
          <svg class="so-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>
        </div>
        <div class="so-project-body" id="so-project-body" style="display:none">
          ${_renderProjectSection(issue.project_id)}
        </div>
      </div>
    `;
    const panel = document.getElementById('issue-slideover');
    document.getElementById('slideover-overlay').style.display = 'block';
    panel.style.display = 'flex';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-modal', 'true');
    panel.setAttribute('aria-label', `Issue ${issue.title}`);
    document.body.style.overflow = 'hidden';
    // Opening it never used to move focus into it, so a keyboard user was left
    // tabbing through the list behind the panel.
    trapFocus(panel);

    // The links list is a separate request, so the panel opens straight away
    // and the section fills in — it is never a reason to wait.
    const linksBox = document.getElementById('so-links');
    if (linksBox) {
      linksBox.innerHTML = skeleton('link', 2);
      try {
        await loadLinks(issue.project_id);
        renderLinks('so-links', issue.project_id);
      } catch {
        linksBox.innerHTML = errorState({
          title: 'Couldn’t load links',
          body: 'The server didn’t answer.',
          onRetry: `GRAFT._retrySlideoverLinks('${jsStr(issue.project_id)}')`,
        });
      }
    }
  }

  async function _retrySlideoverLinks(pid) {
    const box = document.getElementById('so-links');
    if (!box) return;
    box.innerHTML = skeleton('link', 2);
    try {
      await loadLinks(pid);
      renderLinks('so-links', pid);
    } catch {
      box.innerHTML = errorState({
        title: 'Couldn’t load links',
        body: 'The server didn’t answer.',
        onRetry: `GRAFT._retrySlideoverLinks('${jsStr(pid)}')`,
      });
    }
  }

  async function _soSave() {
    const id = _slideoverIssueId;
    if (!id) return;
    const body = document.getElementById('slideover-body');
    if (!body) return;
    const issue = _allIssues.find(i => i.id === id);

    // The title is checked before anything else is read, because the check
    // used to sit after every field had been gathered and before the write:
    // clearing the title silently threw away every other edit in that save.
    const titleEl = body.querySelector('[data-field="title"]');
    const title = titleEl?.innerText?.trim();
    if (!title) {
      if (titleEl && issue) titleEl.innerText = issue.title;
      toast('An issue needs a title — the rest of your changes are still here');
      return;
    }

    const description = body.querySelector('[data-field="description"]')?.innerText?.trim();
    const status = body.querySelector('[data-field="status"]')?.value;
    const priority = body.querySelector('[data-field="priority"]')?.value;
    const assignee = body.querySelector('[data-field="assignee"]')?.value?.trim();
    const milestone_id = body.querySelector('[data-field="milestone_id"]')?.value || null;
    const labelsRaw = body.querySelector('[data-field="labels"]')?.value || '';
    const labels = labelsRaw.split(',').map(l => l.trim()).filter(Boolean);

    const previous = issue ? { ...issue } : null;
    if (issue) {
      Object.assign(issue, { title, description, status, priority, assignee, milestone_id, labels });
      issue.milestone_name = _allMilestones.find(m => m.id === milestone_id)?.name || null;
    }

    // Refresh the board/list behind the slide-over quietly
    rerenderCurrentView();

    try {
      await api('PUT', `/api/issues/${id}`, { title, description, status, priority, assignee, milestone_id, labels });
    } catch {
      // The edit was shown before it was saved, so a failure has to take it
      // back — otherwise the value sits there until you navigate away.
      if (issue && previous) Object.assign(issue, previous);
      rerenderCurrentView();
      if (_slideoverIssueId === id) openIssueSlideover(id);
      toast('That didn’t save — the server didn’t answer');
    }
  }

  function closeSlideover() {
    const panel = document.getElementById('issue-slideover');
    if (!panel) return;
    releaseFocus(panel);
    _slideoverIssueId = null;
    document.getElementById('slideover-overlay').style.display = 'none';
    panel.style.display = 'none';
    document.body.style.overflow = '';
  }

  async function _deleteIssueFromSlideover(id) { await deleteIssueById(id); }

  async function _archiveIssueFromSlideover(id) { await archiveIssue(id); }

  function _issue(id) { return _allIssues.find(i => i.id === id); }

  function _renderProjectSection(pid) {
    const p = _allProjects.find(proj => proj.id === pid);
    if (!p) return '<div class="so-empty">No project</div>';
    const areaOptions = [{ id: '', name: 'No area' }, ..._allAreas]
      .map(a => `<option value="${esc(a.id)}" ${String(p.area_id || '') === String(a.id) ? 'selected' : ''}>${esc(a.name)}</option>`)
      .join('');
    return `
      <div class="so-meta" style="margin-top:10px">
        <div class="so-meta-row">
          <span class="so-label">Name</span>
          <input class="so-input" aria-label="Project name" data-pfield="name" value="${esc(p.name)}" onblur="GRAFT._soProjectSave('${jsStr(pid)}')">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Status</span>
          <select class="so-select" aria-label="Project status" data-pfield="status" onchange="GRAFT._soProjectSave('${jsStr(pid)}')">
            ${PROJECT_STATUSES.map(s => `<option value="${s}" ${p.status === s ? 'selected' : ''}>${PROJECT_STATUS_LABELS[s]}</option>`).join('')}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Area</span>
          <select class="so-select" aria-label="Area" data-pfield="area_id" onchange="GRAFT._soProjectSave('${jsStr(pid)}')">
            ${areaOptions}
          </select>
        </div>
        <div class="so-meta-row">
          <span class="so-label">Icon</span>
          <input class="so-input" aria-label="Project icon" data-pfield="icon" value="${esc(p.icon || '')}" placeholder="Paste emoji…" onblur="GRAFT._soProjectSave('${jsStr(pid)}')">
        </div>
        <div class="so-meta-row">
          <span class="so-label">Description</span>
          <input class="so-input" aria-label="Project description" data-pfield="description" value="${esc(p.description || '')}" placeholder="Add description…" onblur="GRAFT._soProjectSave('${jsStr(pid)}')">
        </div>
      </div>
      <div class="so-links" id="so-links"></div>`;
  }

  function _toggleProjectSection() {
    const body = document.getElementById('so-project-body');
    const head = document.getElementById('so-project-toggle');
    const chevron = document.querySelector('.so-chevron');
    const open = body.style.display !== 'none';
    body.style.display = open ? 'none' : 'block';
    head?.setAttribute('aria-expanded', String(!open));
    if (chevron) chevron.style.transform = open ? '' : 'rotate(180deg)';
  }

  async function _soProjectSave(pid) {
    const body = document.getElementById('so-project-body');
    if (!body) return;
    const proj = _allProjects.find(p => p.id === pid);

    // Same shape of bug as the issue title: the guard belongs before any of
    // this is written anywhere, not between reading the fields and sending.
    const nameEl = body.querySelector('[data-pfield="name"]');
    const name = nameEl?.value?.trim();
    if (!name) {
      if (nameEl && proj) nameEl.value = proj.name;
      toast('A project needs a name — the rest of your changes are still here');
      return;
    }

    const status = body.querySelector('[data-pfield="status"]')?.value;
    const icon = body.querySelector('[data-pfield="icon"]')?.value?.trim();
    const description = body.querySelector('[data-pfield="description"]')?.value?.trim();
    const area_id = body.querySelector('[data-pfield="area_id"]')?.value ?? '';

    const previous = proj
      ? { name: proj.name, status: proj.status, icon: proj.icon, description: proj.description, area_id: proj.area_id }
      : null;
    if (proj) Object.assign(proj, { name, status, icon, description, area_id });
    const label = document.querySelector('.so-project-label');
    if (label) label.textContent = `Project — ${name}`;
    try {
      await api('PUT', `/api/projects/${pid}`, { name, status, icon, description, area_id });
      _railProjects = null;
      renderRail();
    } catch {
      // The fields were written before the request, so put the old values
      // back rather than leave an edit that was never saved on screen.
      if (proj && previous) Object.assign(proj, previous);
      const section = document.getElementById('so-project-body');
      if (section) section.innerHTML = _renderProjectSection(pid);
      if (label) label.textContent = `Project — ${previous?.name || ''}`;
      toast('That didn’t save — the server didn’t answer');
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: index.html  (Projects)
  // ══════════════════════════════════════════════════════════════
  let _projectsLoaded = false;

  async function init() {
    window._pageMode = 'projects';
    initTheme();
    initChrome('projects', { title: 'Projects', fab: { label: 'New project', action: () => openNewProject() } });
    initColourPicker('colour-picker', 'project-colour');
    initIconPicker('icon-picker', 'project-icon');
    orgInit('projects');
    initViewMode('projects');
    setTopbarMenu([
      { label: 'New project', onClick: () => openNewProject() },
      { label: 'New area', onClick: () => createArea() },
    ]);
    document.getElementById('projects-grid').innerHTML = skeleton('project', 6);
    await Promise.all([loadAreas(), loadViews(), loadProjectTags()]);
    renderOrgBar();
    renderRail();
    await loadProjects();
  }

  async function loadProjects() {
    const grid = document.getElementById('projects-grid');
    if (grid && !_projectsLoaded) grid.innerHTML = skeleton('project', 6);
    try {
      // area_id and archived are real query parameters; project status and the
      // search term are cheap enough to apply here over a list we already hold.
      const params = new URLSearchParams();
      if (_org.archived) params.set('archived', '1');
      if (_org.filters.area_id.length) params.set('area_id', _org.filters.area_id.join(','));
      const suffix = params.toString() ? `?${params}` : '';
      const [projects, milestones] = await Promise.all([
        api('GET', `/api/projects${suffix}`),
        api('GET', '/api/milestones'),
      ]);
      _allProjects = projects;
      _allMilestones = milestones;
      _projectsLoaded = true;
      markFresh();
      renderProjects();
    } catch {
      if (_projectsLoaded) {
        // The list on screen is still the last good one — say it is old rather
        // than blanking it, and leave a way to try again.
        markStale(() => loadProjects());
        renderProjects();
      } else if (grid) {
        grid.innerHTML = errorState({
          title: 'Can’t reach the Graft server',
          body: 'Your projects are safe on the server — this device just couldn’t reach it.',
          onRetry: 'GRAFT._retryProjects()',
        });
      }
    }
  }

  async function _retryProjects() { await loadProjects(); }

  async function loadProjectTags() {
    try { _allProjectTags = await api('GET', '/api/projects/tags'); } catch { /* non-fatal */ }
  }

  function visibleProjects() {
    const q = (_org.q || '').toLowerCase();
    let list = _allProjects;
    if (!_org.archived) list = list.filter(p => !p.archived);
    if (_org.filters.status.length) list = list.filter(p => _org.filters.status.includes(p.status));
    if (_org.filters.area_id.length) {
      list = list.filter(p => _org.filters.area_id.includes(p.area_id ? p.area_id : 'none'));
    }
    if (_org.filters.tag && _org.filters.tag.length) {
      list = list.filter(p => {
        const pt = Array.isArray(p.tags) ? p.tags : [];
        return _org.filters.tag.every(t => pt.includes(t));
      });
    }
    if (q) {
      list = list.filter(p =>
        p.name.toLowerCase().includes(q) || (p.description || '').toLowerCase().includes(q));
    }
    return sortProjects(list);
  }

  function sortProjects(list) {
    const dir = _org.dir === 'desc' ? -1 : 1;
    const rank = { active: 0, paused: 1, done: 2 };
    const areaName = id => {
      const a = _allAreas.find(a => a.id === id);
      return a ? a.name.toLowerCase() : '\uffff';
    };
    const cmp = {
      manual: (a, b) => String(a.created_at || '').localeCompare(String(b.created_at || '')),
      created: (a, b) => String(a.created_at || '').localeCompare(String(b.created_at || '')),
      updated: (a, b) => String(a.updated_at || '').localeCompare(String(b.updated_at || '')),
      title: (a, b) => String(a.name || '').localeCompare(String(b.name || '')),
      status: (a, b) => (rank[a.status] ?? 3) - (rank[b.status] ?? 3),
      area: (a, b) => areaName(a.area_id).localeCompare(areaName(b.area_id)) || String(a.name || '').localeCompare(String(b.name || '')),
    }[_org.sort] || ((a, b) => 0);
    return [...list].sort((a, b) => cmp(a, b) * dir);
  }

  function renderProjects() {
    const grid = document.getElementById('projects-grid');
    if (!grid) return;
    const visible = visibleProjects();
    const total = _allProjects.length;

    const sub = document.getElementById('projects-subtitle');
    if (sub) {
      const active = _allProjects.filter(p => p.status === 'active' && !p.archived).length;
      sub.textContent = `${total} project${total !== 1 ? 's' : ''} · ${active} active`;
    }
    orgCount(visible.length, total);

    // Truly empty and filtered-to-nothing are different things and must read
    // differently: "No projects yet — create one" used to be shown for a
    // Paused filter over a workspace with nine projects in it.
    if (!total) {
      grid.innerHTML = emptyState({
        icon: '🌱',
        title: 'No projects yet',
        body: 'A project holds issues, milestones and links. Start with the thing you are actually working on.',
        actionLabel: 'Create your first project',
        onAction: 'GRAFT.openNewProject()',
      });
      return;
    }
    if (!visible.length) {
      grid.innerHTML = noMatchState({
        hidden: total,
        summary: orgFilterSummary(),
        onClear: 'GRAFT._clearAllFilters()',
        noun: 'projects',
      });
      return;
    }

    if (_org.group === 'status') {
      grid.innerHTML = groupItems(visible, 'status').map(g => `
        ${groupHead(PROJECT_STATUS_LABELS[g.key] || g.key, g.rows.length)}
        <div class="projects-grid${_viewMode === 'list' ? ' projects-grid-list' : ''}">${
          g.rows.map(projectCard).join('')}</div>`).join('');
      return;
    }
    if (_org.group !== 'area') {
      grid.innerHTML = `<div class="projects-grid${_viewMode === 'list' ? ' projects-grid-list' : ''}">${
        visible.map(projectCard).join('')}</div>`;
      return;
    }
    grid.innerHTML = renderAreaSections(visible);
  }

  // Areas are sections with a header, a count, a rule and their own menu. The
  // unfiled projects land in "No area" at the bottom — always last, and only
  // drawn when there is something in it.
  // ── Drag-and-drop: project cards → area sections ─────────────────
  // Only active when grouped by area. Uses HTML5 drag API.
  // dragover fires continuously; we throttle the highlight update.
  let _dndDragId = null;

  function _onCardDragStart(e, projectId) {
    _dndDragId = projectId;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', projectId);
    e.currentTarget.classList.add('dragging');
  }

  function _onCardDragEnd(e) {
    _dndDragId = null;
    e.currentTarget.classList.remove('dragging');
    document.querySelectorAll('.area-section.drag-over').forEach(el => el.classList.remove('drag-over'));
  }

  function _onAreaDragOver(e, areaId) {
    if (!_dndDragId) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    document.querySelectorAll('.area-section.drag-over').forEach(el => el.classList.remove('drag-over'));
    const section = e.currentTarget.closest('.area-section');
    if (section) section.classList.add('drag-over');
  }

  function _onAreaDragLeave(e) {
    const related = e.relatedTarget;
    const section = e.currentTarget.closest('.area-section');
    if (section && (!related || !section.contains(related))) {
      section.classList.remove('drag-over');
    }
  }

  async function _onAreaDrop(e, areaId) {
    e.preventDefault();
    document.querySelectorAll('.area-section.drag-over').forEach(el => el.classList.remove('drag-over'));
    const pid = e.dataTransfer.getData('text/plain') || _dndDragId;
    _dndDragId = null;
    if (!pid) return;
    const project = _allProjects.find(p => p.id === pid);
    if (!project) return;
    const targetArea = areaId === '' ? '' : areaId;
    if (project.area_id === targetArea) return;

    // Optimistic update
    const previous = project.area_id;
    project.area_id = targetArea;
    renderProjects();

    try {
      await api('PUT', `/api/projects/${pid}`, { area_id: targetArea });
    } catch {
      project.area_id = previous;
      renderProjects();
      toast("Couldn\u2019t move the project \u2014 try again");
    }
  }

  function renderAreaSections(visible) {
    // With no areas at all, every project would land in a section called "No
    // area" — a grouping that groups nothing. Draw the plain grid instead.
    if (!_allAreas.length) {
      return `<div class="projects-grid${_viewMode === 'list' ? ' projects-grid-list' : ''}">${
        visible.map(projectCard).join('')}</div>`;
    }
    const collapsed = collapsedAreas();
    const sections = _allAreas.map(a => ({
      id: a.id,
      name: a.name,
      colour: a.colour || '',
      rows: visible.filter(p => p.area_id === a.id),
      menu: true,
    }));
    const unfiled = visible.filter(p => !p.area_id || !_allAreas.some(a => a.id === p.area_id));
    if (unfiled.length) sections.push({ id: '', name: 'No area', colour: '', rows: unfiled, menu: false });

    return sections.filter(s =>
      // An empty area is worth showing so you can see the one you just made —
      // but not while a filter is on, when every area would be empty scaffolding.
      s.rows.length || !orgIsFiltering()
    ).map(s => {
      const shut = collapsed.has(s.id || '__none__');
      return `
        <section class="area-section${shut ? ' collapsed' : ''}"
          ondragover="GRAFT._onAreaDragOver(event,'${jsStr(s.id)}')"
          ondragleave="GRAFT._onAreaDragLeave(event)"
          ondrop="GRAFT._onAreaDrop(event,'${jsStr(s.id)}')">
          <div class="area-header">
            <button class="area-header-name" type="button" aria-expanded="${!shut}"
                    onclick="GRAFT._toggleArea('${jsStr(s.id || '__none__')}')">
              <span class="area-dot" aria-hidden="true" ${s.colour ? `style="background:${esc(s.colour)}"` : ''}></span>
              ${esc(s.name)}
            </button>
            <span class="area-header-count">${s.rows.length}</span>
            <div class="area-header-rule"></div>
            <div class="area-header-actions">
              ${s.menu ? `<button class="icon-btn" type="button" aria-haspopup="menu"
                     aria-label="Actions for ${esc(s.name)}"
                     onclick="GRAFT._areaMenu(event,'${jsStr(s.id)}')">${svg(DOTS_ICON, 16)}</button>` : ''}
            </div>
          </div>
          ${shut ? '' : `<div class="projects-grid${_viewMode === 'list' ? ' projects-grid-list' : ''}">${
            s.rows.length
              ? s.rows.map(projectCard).join('')
              : `<div class="empty-state"><div class="empty-state-title">Nothing filed here yet</div>
                   <div class="empty-state-body">Give a project this area from its edit form.</div></div>`
          }</div>`}
        </section>`;
    }).join('');
  }

  function _toggleArea(id) {
    const set = collapsedAreas();
    if (set.has(id)) set.delete(id); else set.add(id);
    try { localStorage.setItem(AREA_COLLAPSE_KEY, JSON.stringify([...set])); } catch { /* private mode */ }
    renderProjects();
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
           draggable="true"
           ondragstart="GRAFT._onCardDragStart(event,'${jsStr(p.id)}')"
           ondragend="GRAFT._onCardDragEnd(event)"
           onclick="window.location.href='project.html?id=${esc(p.id)}'"
           onkeydown="if(event.key==='Enter'){window.location.href='project.html?id=${esc(p.id)}'}">
        <div class="project-card-stripe" style="background:${esc(p.colour)}"></div>
        <div class="project-card-body">
          <div class="project-card-header">
            ${p.icon ? `<span class="project-icon">${esc(p.icon)}</span>` : ''}
            <span class="project-card-name">${esc(p.name)}</span>
            ${p.archived
              ? `<span class="project-card-status" style="background:var(--surface-2);color:var(--ink-2)">archived</span>`
              : `<span class="project-card-status status-${esc(p.status)}">${esc(p.status)}</span>`}
          </div>
          ${p.description ? `<div class="project-card-desc">${esc(p.description)}</div>` : ''}
          ${Array.isArray(p.tags) && p.tags.length ? `<div class="project-card-tags">${p.tags.map(t => `<span class="tag-pill">${esc(t)}</span>`).join('')}</div>` : ''}
          <div class="progress-row">
            <div class="progress" role="img" aria-label="${done} of ${total} done">
              <span class="progress-done" style="width:${donePct}%"></span>
              <span class="progress-doing" style="width:${doingPct}%"></span>
            </div>
            <span class="progress-label">${open} open · ${done} done</span>
          </div>
          ${next
            ? `<div style="font-size:12px;color:var(--ink-2)">Next: <span style="color:var(--accent-text)">${esc(next.name)}</span> ${esc(dueLabel(next.due_date))}</div>`
            : ''}
        </div>
      </div>`;
  }


  // ── The project form ────────────────────────────────────────────

  // Tag chip input — renders inside a container element by id.
  // Tags are stored as a JSON array on the project; the input is
  // a chip row + text field with autocomplete from _allProjectTags.
  function initTagInput(containerId, currentTags) {
    const container = document.getElementById(containerId);
    if (!container) return;
    let tags = [...(currentTags || [])];

    function render() {
      container.innerHTML = `
        <div class="tag-input-chips" id="${containerId}-chips">
          ${tags.map((t, i) => `<span class="tag-chip">${esc(t)}<button type="button" class="tag-chip-remove" aria-label="Remove ${esc(t)}" data-i="${i}">×</button></span>`).join('')}
          <input class="tag-chip-input" id="${containerId}-input" type="text" placeholder="${tags.length ? '' : 'Add tags…'}" autocomplete="off" list="${containerId}-datalist">
        </div>
        <datalist id="${containerId}-datalist">${_allProjectTags.filter(t => !tags.includes(t)).map(t => `<option value="${esc(t)}">`).join('')}</datalist>`;

      container.querySelectorAll('.tag-chip-remove').forEach(btn => {
        btn.onclick = () => { tags.splice(+btn.dataset.i, 1); render(); };
      });

      const inp = document.getElementById(`${containerId}-input`);
      if (inp) {
        inp.onkeydown = e => {
          if ((e.key === 'Enter' || e.key === ',') && inp.value.trim()) {
            e.preventDefault();
            const val = inp.value.trim().replace(/,+$/, '');
            if (val && !tags.includes(val)) { tags.push(val); render(); }
            else inp.value = '';
          } else if (e.key === 'Backspace' && !inp.value && tags.length) {
            tags.pop(); render();
          }
        };
        inp.onblur = () => {
          const val = inp.value.trim().replace(/,+$/, '');
          if (val && !tags.includes(val)) { tags.push(val); render(); }
        };
      }
    }

    render();

    // Expose getter on container element for submitProject to read.
    container._getTags = () => tags;
  }

  function getTagInputValue(containerId) {
    const container = document.getElementById(containerId);
    return container?._getTags ? container._getTags() : [];
  }

  function fillAreaSelect(selected) {
    const sel = document.getElementById('project-area');
    if (!sel) return;
    sel.innerHTML = `<option value="">No area</option>` +
      _allAreas.map(a => `<option value="${esc(a.id)}">${esc(a.name)}</option>`).join('') +
      `<option value="__new__">＋ New area…</option>`;
    sel.value = selected || '';
    sel.onchange = async () => {
      if (sel.value !== '__new__') return;
      sel.value = '';
      const r = await formDialog({
        title: 'New area', submitLabel: 'Create area',
        fields: [{ name: 'name', label: 'Name', placeholder: 'e.g. Client work' }],
      });
      if (!r || !r.name) return;
      try {
        const created = await api('POST', '/api/areas', { name: r.name, sort_order: _allAreas.length });
        await loadAreas();
        fillAreaSelect(created?.id || '');
        renderRail();
      } catch { toast('Could not create the area'); }
    };
  }

  function openNewProject(areaId) {
    document.getElementById('project-edit-id').value = '';
    document.getElementById('project-name').value = '';
    document.getElementById('project-description').value = '';
    document.getElementById('project-status').value = 'active';
    document.getElementById('project-icon').value = '';
    setColour('colour-picker', 'project-colour', '#7C7FC4');
    initIconPicker('icon-picker', 'project-icon');
    fillAreaSelect(areaId || '');
    initTagInput('project-tags', []);
    document.getElementById('modal-project-title').textContent = 'New project';
    openModal('modal-new-project');
  }

  // The same project form is markup-id 'modal-new-project' on index.html and
  // 'modal-edit-project' on project.html; only one of the two is ever here.
  function closeProjectModal() {
    closeModal(document.getElementById('modal-edit-project') ? 'modal-edit-project' : 'modal-new-project');
  }

  async function submitProject(e) {
    e.preventDefault();
    const editId = document.getElementById('project-edit-id').value;
    const areaSel = document.getElementById('project-area');
    const body = {
      name: document.getElementById('project-name').value.trim(),
      description: document.getElementById('project-description').value.trim(),
      status: document.getElementById('project-status').value,
      colour: document.getElementById('project-colour').value,
      icon: document.getElementById('project-icon').value,
      area_id: areaSel && areaSel.value !== '__new__' ? areaSel.value : '',
      tags: getTagInputValue('project-tags'),
    };
    try {
      if (editId) {
        await api('PUT', `/api/projects/${editId}`, body);
        toast('Project saved');
      } else {
        const p = await api('POST', '/api/projects', body);
        toast('Project created');
        closeProjectModal();
        await loadProjectTags();
        window.location.href = `project.html?id=${p.id}`;
        return;
      }
      closeProjectModal();
      await loadProjectTags();
      _railProjects = null;
      if (typeof reloadPage === 'function') reloadPage();
      else loadProjects();
    } catch { toast('Could not save the project — nothing was lost, try again'); }
  }

  async function deleteProject() {
    const editId = document.getElementById('project-edit-id')?.value || _currentProject?.id;
    if (!editId) return;
    await deleteProjectById(editId);
  }

  async function deleteProjectById(id) {
    const project = _allProjects.find(p => p.id === id) || _currentProject;
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
      await api('DELETE', `/api/projects/${id}`);
      toast('Project deleted');
      closeModal('modal-edit-project');
      window.location.href = 'index.html';
    } catch { toast('Could not delete project'); }
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: today.html  (What needs you)
  // ══════════════════════════════════════════════════════════════
  // Today has no organisation bar: it is a fixed, opinionated answer to one
  // question, not a list you filter.
  const TODAY_PAGE = 8;
  const _todayExpanded = {};

  async function initToday() {
    window._pageMode = 'today';
    initTheme();
    initChrome('today', { title: 'Today', fab: { label: 'New issue', action: () => openNewIssue() } });
    document.getElementById('today-content').innerHTML = skeleton('issue', 5);
    await Promise.all([loadAreas(), loadViews()]);
    renderRail();
    await loadToday();
  }

  async function loadToday() {
    try {
      const [projects, issues, milestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', '/api/issues'),
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
      _todayLoaded = true;
      markFresh();
      renderToday();
    } catch {
      if (_todayLoaded) { markStale(() => loadToday()); renderToday(); return; }
      document.getElementById('today-content').innerHTML = errorState({
        title: 'Can’t reach the Graft server',
        body: 'Nothing has been lost — this device just couldn’t reach the server.',
        onRetry: 'GRAFT._retryToday()',
      });
    }
  }

  let _todayLoaded = false;
  async function _retryToday() {
    document.getElementById('today-content').innerHTML = skeleton('issue', 5);
    await loadToday();
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
      ${todaySection('needs', 'Needs you', needsYou, 'Nothing urgent or near a deadline. Enjoy it.')}
      ${todaySection('doing', 'In progress', inProgress, 'Nothing started yet.')}
      <section class="section">
        <div class="section-head">
          <h2 class="section-title">Projects</h2>
          <div class="section-rule"></div>
          <a href="index.html" style="font-size:12.5px;color:var(--accent-text)">View all</a>
        </div>
        <div class="projects-grid">
          ${_allProjects.filter(p => !p.archived).slice(0, 8).map(projectCard).join('') ||
            emptyState({ title: 'No projects yet', body: 'Create one to start tracking issues.',
                         actionLabel: 'New project', onAction: `window.location.href='index.html'` })}
        </div>
      </section>`;
  }

  // The badge used to print the full count over a list truncated to eight,
  // with no way to reach the other fifteen. It now counts what is drawn and
  // says how many more there are — and can show them.
  function todaySection(key, title, issues, emptyText) {
    const expanded = !!_todayExpanded[key];
    const shown = expanded ? issues : issues.slice(0, TODAY_PAGE);
    const rest = issues.length - shown.length;
    return `
      <section class="section">
        <div class="section-head">
          <h2 class="section-title">${esc(title)}</h2>
          <span class="section-count">${rest > 0 ? `${shown.length} of ${issues.length}` : issues.length}</span>
          <div class="section-rule"></div>
        </div>
        ${issues.length
          ? `<div class="issue-list">${shown.map(todayRow).join('')}</div>
             ${rest > 0
               ? `<button class="chip-clear" type="button" style="margin-top:8px"
                    onclick="GRAFT._expandToday('${jsStr(key)}')">Show all ${issues.length}</button>`
               : (expanded && issues.length > TODAY_PAGE
                 ? `<button class="chip-clear" type="button" style="margin-top:8px"
                      onclick="GRAFT._collapseToday('${jsStr(key)}')">Show fewer</button>` : '')}`
          : `<div style="font-size:13px;color:var(--ink-2);padding:4px 2px">${esc(emptyText)}</div>`}
      </section>`;
  }

  function _expandToday(key) { _todayExpanded[key] = true; renderToday(); }
  function _collapseToday(key) { _todayExpanded[key] = false; renderToday(); }

  function todayRow(issue) {
    const id = jsStr(issue.id);
    const due = milestoneDue(issue);
    const d = daysUntil(due);
    const flag = d !== null && d <= 2
      ? `<span class="${d < 0 ? 'due-flag' : 'age-flag'}">${esc(dueLabel(due))}</span>`
      : `<span class="age-flag">${esc(relTime(issue.updated_at))}</span>`;
    return `
      <div class="today-row" data-priority="${esc(issue.priority)}" data-id="${esc(issue.id)}"
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

  // ══════════════════════════════════════════════════════════════
  //  PAGE: issues.html  (All issues)
  // ══════════════════════════════════════════════════════════════
  let _issuesLoaded = false;

  async function initIssues() {
    window._pageMode = 'issues';
    initTheme();
    initChrome('issues', { title: 'All issues', fab: { label: 'New issue', action: () => openNewIssue() } });
    orgInit('issues');
    initViewMode('issues');
    document.getElementById('issue-list').innerHTML = skeleton('issue', 6);
    renderRail();
    await loadIssuesMeta();
  }

  async function loadIssuesMeta() {
    try {
      const [projects, milestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', '/api/milestones'),
      ]);
      _allProjects = projects;
      _allMilestones = milestones;
    } catch {
      document.getElementById('issue-list').innerHTML = errorState({
        title: 'Can’t reach the Graft server',
        body: 'Your issues are safe on the server — this device just couldn’t reach it.',
        onRetry: 'GRAFT._retryIssues()',
      });
      return;
    }
    await Promise.all([loadAreas(), loadViews(), loadFacets()]);
    renderOrgBar();
    renderRail();
    await loadIssuesPage();
  }

  // Retrying re-fetches; it must never rebuild the page chrome, or the
  // top bar, the tab bar and the shortcut handler all arrive a second time.
  async function _retryIssues() {
    document.getElementById('issue-list').innerHTML = skeleton('issue', 6);
    await loadIssuesMeta();
  }

  // Everything in the bar is a query parameter, so a filter change is one
  // request and the server does the matching — including, at last, labels.
  async function loadIssuesPage() {
    const el = document.getElementById('issue-list');
    try {
      const issues = await api('GET', `/api/issues${orgQuery()}`);
      const byId = Object.fromEntries(_allProjects.map(p => [p.id, p]));
      _allIssues = issues.map(i => ({
        ...i,
        project_name: byId[i.project_id]?.name,
        project_icon: byId[i.project_id]?.icon,
      }));
      _issuesLoaded = true;
      markFresh();
      renderIssuesPage();
    } catch {
      if (_issuesLoaded) { markStale(() => loadIssuesPage()); return; }
      if (el) {
        el.innerHTML = errorState({
          title: 'Can’t reach the Graft server',
          body: 'Your issues are safe on the server — this device just couldn’t reach it.',
          onRetry: 'GRAFT._retryIssues()',
        });
      }
    }
  }

  // One unfiltered request per page load and per write, so the empty states
  // can quote a real number. "0 issues are hidden by the filters above", over
  // an empty database with no filters set, was the worst line in the client.
  async function loadFacets() {
    const scope = window._pageMode === 'project' && _currentProjectId
      ? `?project_id=${encodeURIComponent(_currentProjectId)}&archived=1`
      : '?archived=1';
    try { _facetIssues = await api('GET', `/api/issues${scope}`); }
    catch { /* keep the vocabulary we already have rather than emptying it */ }
  }

  function facetTotal() {
    if (!_facetIssues.length) return _allIssues.length;
    return _org.archived ? _facetIssues.length : _facetIssues.filter(i => !i.archived).length;
  }

  function renderIssuesPage() {
    const el = document.getElementById('issue-list');
    if (!el) return;
    const total = Math.max(facetTotal(), _allIssues.length);
    orgCount(_allIssues.length, total);

    if (!_allIssues.length) {
      if (!total) {
        el.innerHTML = emptyState({
          icon: '🌱',
          title: 'No issues anywhere yet',
          body: 'Issues are the unit of work in Graft. Add the first one and it will show up here.',
          actionLabel: 'New issue',
          onAction: 'GRAFT.openNewIssue()',
        });
      } else {
        el.innerHTML = noMatchState({
          hidden: total,
          summary: orgFilterSummary(),
          onClear: 'GRAFT._clearAllFilters()',
          noun: 'issues',
        });
      }
      pruneSelection([]);
      return;
    }
    renderIssueSurface(el, _allIssues, { showProject: true, board: _viewMode === 'board' });
  }

  // ══════════════════════════════════════════════════════════════
  //  PAGE: project.html  (Single project)
  // ══════════════════════════════════════════════════════════════
  let _projectLoaded = false;
  let _projectMissing = false;

  window.reloadPage = async function () {
    if (window._pageMode === 'project') await loadProjectPage();
    else if (window._pageMode === 'issues') { await loadFacets(); await loadIssuesPage(); }
    else if (window._pageMode === 'today') await loadToday();
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
    initColourPicker('colour-picker', 'project-colour');
    orgInit('project');
    initViewMode('project');
    document.getElementById('project-issues').innerHTML =
      _viewMode === 'board' ? boardSkeleton() : skeleton('issue', 6);
    await Promise.all([loadAreas(), loadViews()]);
    renderOrgBar();
    renderRail();
    await loadProjectPage();
    // Deep link from Today, search or a shared URL
    const focus = params.get('issue');
    if (focus && _issue(focus)) openIssueSlideover(focus);
  }

  async function loadProjectPage() {
    try {
      const [projects, project, milestones] = await Promise.all([
        api('GET', '/api/projects'),
        api('GET', `/api/projects/${_currentProjectId}`),
        api('GET', `/api/milestones?project_id=${_currentProjectId}`),
      ]);
      _allProjects = projects;
      _currentProject = project;
      _allMilestones = milestones;
      _projectMissing = false;
      _projectLoaded = true;
      renderProjectHeader();
      renderOrgBar();
      await Promise.all([loadFacets(), loadProjectIssues(), loadProjectLinks()]);
      renderOrgBar();  // the assignee and label vocabularies just arrived
    } catch (err) {
      if (err.status === 404) {
        // Nothing is left to show, and the caches above still hold the last
        // project's issues — clear them or the old board reads as this one's.
        _projectMissing = true;
        _currentProject = null;
        _allIssues = [];
        _allMilestones = [];
        renderProjectHeader();
        renderProjectIssues();
        return;
      }
      if (_projectLoaded) { markStale(() => loadProjectPage()); return; }
      document.getElementById('project-issues').innerHTML = errorState({
        title: 'Can’t reach the Graft server',
        body: 'This project is safe on the server — this device just couldn’t reach it.',
        onRetry: 'GRAFT._retryProject()',
      });
    }
  }

  async function _retryProject() {
    document.getElementById('project-issues').innerHTML =
      _viewMode === 'board' ? boardSkeleton() : skeleton('issue', 6);
    await loadProjectPage();
  }

  function renderProjectHeader() {
    const title = document.getElementById('project-name-title');
    const desc = document.getElementById('project-description-text');
    const crumb = document.getElementById('project-name-breadcrumb');
    if (_projectMissing) {
      if (title) title.textContent = 'Project not found';
      if (desc) desc.textContent = '';
      if (crumb) crumb.textContent = 'Not found';
      setTopbarTitle('Not found');
      const prog = document.getElementById('project-progress');
      if (prog) prog.innerHTML = '';
      return;
    }
    if (!_currentProject) return;
    document.title = `${_currentProject.name} — Graft`;
    if (crumb) crumb.textContent = _currentProject.name;
    if (title) title.textContent = (_currentProject.icon ? _currentProject.icon + ' ' : '') + _currentProject.name;
    if (desc) desc.textContent = _currentProject.description || '';
    // The phone header used to read "Project" on every project in the
    // workspace, because #topbar-title was hard-coded and never updated.
    setTopbarTitle(_currentProject.name);
    setTopbarMenu([
      { label: 'Milestones', onClick: () => openMilestones() },
      { label: 'Edit project', onClick: () => editCurrentProject() },
      { label: _currentProject.archived ? 'Unarchive project' : 'Archive project', onClick: () => archiveCurrentProject() },
      { separator: true },
      { label: 'Delete project', danger: true, onClick: () => deleteProjectById(_currentProject.id) },
    ]);
    const hdr = document.getElementById('project-header');
    if (hdr) hdr.dataset.archived = _currentProject.archived ? '1' : '0';
    renderProjectProgress();
  }

  // "Are we going to make it" belongs in the header, not in two raw counts.
  function renderProjectProgress() {
    const el = document.getElementById('project-progress');
    if (!el || !_currentProject) return;
    const c = _currentProject.issue_counts || {};
    const done = c.done || 0;
    const doing = c.in_progress || 0;
    const total = c.total || 0;
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
        next ? ` · <span style="color:var(--accent-text)">${esc(next.name)}</span> ${esc(dueLabel(next.due_date))}` : ''}</span>`;
  }

  async function loadProjectLinks() {
    const box = document.getElementById('project-links');
    if (!box) return;
    box.innerHTML = skeleton('link', 2);
    try {
      await loadLinks(_currentProjectId);
      renderLinks('project-links', _currentProjectId);
    } catch {
      box.innerHTML = errorState({
        title: 'Couldn’t load links',
        body: 'The server didn’t answer for this project’s links.',
        onRetry: 'GRAFT._retryProjectLinks()',
      });
    }
  }

  async function _retryProjectLinks() { await loadProjectLinks(); }

  async function loadProjectIssues() {
    if (_projectMissing) { renderProjectIssues(); return; }
    try {
      _allIssues = await api('GET', `/api/issues${orgQuery({ project_id: _currentProjectId })}`);
      markFresh();
      renderProjectIssues();
    } catch {
      if (_projectLoaded && _allIssues.length) { markStale(() => loadProjectIssues()); return; }
      document.getElementById('project-issues').innerHTML = errorState({
        title: 'Can’t reach the Graft server',
        body: 'This project’s issues are safe on the server — this device just couldn’t reach it.',
        onRetry: 'GRAFT._retryProject()',
      });
    }
  }

  // The board had no empty state and no error state at all: a fresh project,
  // a filter that matched nothing and a 404 all rendered as five columns
  // saying "Nothing here yet".
  function renderProjectIssues() {
    const el = document.getElementById('project-issues');
    if (!el) return;

    if (_projectMissing) {
      el.innerHTML = errorState({
        title: 'This project no longer exists',
        body: 'It may have been deleted from another device. Your other projects are unaffected.',
        onRetry: `window.location.href='index.html'`,
      });
      orgCount(0, 0);
      return;
    }

    const total = Math.max(facetTotal(), (_currentProject?.issue_counts || {}).total || 0, _allIssues.length);
    orgCount(_allIssues.length, total);

    if (!_allIssues.length) {
      if (!total) {
        el.innerHTML = emptyState({
          icon: '🌱',
          title: 'No issues in this project yet',
          body: 'Press C, or use New issue, to add the first one.',
          actionLabel: 'New issue',
          onAction: 'GRAFT.openNewIssue()',
        });
      } else {
        el.innerHTML = noMatchState({
          hidden: total,
          summary: orgFilterSummary(),
          onClear: 'GRAFT._clearAllFilters()',
          noun: 'issues',
        });
      }
      pruneSelection([]);
      return;
    }
    renderIssueSurface(el, sortedProjectIssues(), { board: _viewMode === 'board' });
  }

  // The server already sorted these. Manual order is re-applied here because
  // a card dropped into a new place has to stay there on the optimistic
  // re-render instead of snapping back to where it was.
  function sortedProjectIssues() {
    if (_org.sort !== 'manual') return _allIssues;
    return [..._allIssues].sort((a, b) =>
      (a.sort_order ?? 0) - (b.sort_order ?? 0) ||
      String(a.created_at || '').localeCompare(String(b.created_at || '')));
  }

  // Soft limit — the column colours itself when work in progress piles up.
  const WIP_LIMIT = 3;

  function renderBoardInto(el, issues, { showProject = false } = {}) {
    el.innerHTML = `<div class="kanban-board">${STATUSES.map(status => {
      const col = issues.filter(i => i.status === status);
      return `
        <div class="kanban-col"
             data-status="${status}"
             ondragover="GRAFT._dragOver(event)"
             ondragenter="GRAFT._dragEnter(event)"
             ondragleave="GRAFT._dragLeave(event)"
             ondrop="GRAFT._drop(event)">
          <div class="kanban-col-header">
            ${statusIcon(status, 14)}
            <span class="col-name">${STATUS_LABELS[status]}</span>
            <span class="col-count"${status === 'in-progress' && col.length > WIP_LIMIT
              ? ' style="color:var(--amber);border-color:var(--amber)" title="More work in progress than the limit of ' + WIP_LIMIT + '"'
              : ''}>${col.length}${status === 'in-progress' ? ' / ' + WIP_LIMIT : ''}</span>
          </div>
          ${col.length
            ? col.map(i => renderKanbanCard(i, { showProject })).join('')
            : `<div class="kanban-col-empty" style="font-size:12.5px;color:var(--ink-3);padding:10px 4px 6px">Nothing in ${STATUS_LABELS[status].toLowerCase()}</div>`}
          <button class="kanban-add-btn" type="button" onclick="GRAFT._addIssueInStatus('${status}')">
            ${svg(NAV_ICONS.plus, 12, 'stroke-width="2.5"')}
            Add issue
          </button>
        </div>`;
    }).join('')}</div>`;
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
    fillAreaSelect(_currentProject.area_id || '');
    initTagInput('project-tags', _currentProject.tags || []);
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
    const col = e.currentTarget;
    const afterCard = _getDragAfterCard(col, e.clientY);
    col.querySelector('.drag-placeholder')?.remove();
    const ph = document.createElement('div');
    ph.className = 'drag-placeholder';
    if (afterCard) col.insertBefore(ph, afterCard);
    else col.insertBefore(ph, col.querySelector('.kanban-add-btn'));
  }

  function _dragEnter(e) {
    e.preventDefault();
    e.currentTarget.classList.add('drop-target');
  }

  function _dragLeave(e) {
    // Only remove if leaving the column itself, not a child
    if (!e.currentTarget.contains(e.relatedTarget)) {
      e.currentTarget.classList.remove('drop-target');
      e.currentTarget.querySelector('.drag-placeholder')?.remove();
    }
  }

  async function _drop(e) {
    e.preventDefault();
    const col = e.currentTarget;
    col.classList.remove('drop-target');
    col.querySelector('.drag-placeholder')?.remove();

    const newStatus = col.dataset.status;
    if (!_dragId) return;

    const issue = _allIssues.find(i => i.id === _dragId);
    if (!issue) return;
    const statusChanged = issue.status !== newStatus;

    // Where the card landed, among the ids already drawn in this column
    const afterCard = _getDragAfterCard(col, e.clientY);
    const ids = [...col.querySelectorAll('.kanban-card[data-id]')]
      .map(c => c.dataset.id)
      .filter(cid => cid !== _dragId);
    const at = afterCard ? ids.indexOf(afterCard.dataset.id) : -1;
    ids.splice(at < 0 ? ids.length : at, 0, _dragId);

    // Every card in the column is renumbered, not just the dragged one:
    // issues created on the web all arrive with sort_order 0, so a single
    // card's number means nothing until its neighbours have one too.
    const order = ids.map((cid, n) => ({ id: cid, sort_order: n }));

    issue.status = newStatus;
    order.forEach(({ id, sort_order }) => {
      const card = _allIssues.find(i => i.id === id);
      if (card) card.sort_order = sort_order;
    });

    rerenderCurrentView();

    try {
      if (statusChanged) await api('PUT', `/api/issues/${_dragId}`, { status: newStatus });
      await api('PATCH', '/api/issues/reorder', { issues: order });
    } catch {
      toast('That move didn’t save — reloading the board');
      if (typeof reloadPage === 'function') reloadPage();
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
      el.innerHTML = `<div class="empty-state" style="padding:18px 0">
        <div class="empty-state-title">No milestones yet</div>
        <div class="empty-state-body">A milestone gives this project's issues a due date to sort by. Add one below.</div>
      </div>`;
      return;
    }
    el.innerHTML = _allMilestones.map(m => `
      <div class="milestone-row" id="ms-row-${esc(m.id)}">
        <span class="milestone-row-name">${esc(m.name)}</span>
        ${m.due_date ? `<span class="milestone-row-due">${esc(m.due_date)}</span>` : ''}
        <div class="milestone-row-actions">
          <button class="icon-btn" type="button" onclick="GRAFT._editMilestone('${jsStr(m.id)}')" title="Edit" aria-label="Edit ${esc(m.name)}">
            ${svg(NAV_ICONS.edit, 14)}
          </button>
          <button class="icon-btn" type="button" onclick="GRAFT._deleteMilestone('${jsStr(m.id)}')" title="Delete" aria-label="Delete ${esc(m.name)}">
            ${svg('<polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/>', 14)}
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
      renderOrgBar();  // the milestone filter's options just changed
      clearMilestoneForm();
      toast(editId ? 'Milestone updated' : 'Milestone added');
    } catch { toast('Could not save the milestone'); }
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
      const at = _org.filters.milestone_id.indexOf(id);
      if (at >= 0) _org.filters.milestone_id.splice(at, 1);
      renderMilestonesList();
      renderOrgBar();
      loadProjectIssues();
      toast('Milestone deleted');
    } catch { toast('Could not delete the milestone'); }
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
        ? `${svg('<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>', 14)} Dark mode`
        : `${svg('<circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>', 14)} Light mode`;
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
                data-icon="${icon}" aria-label="Use ${icon} as the project icon"
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
  let _topbarMenu = [];

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

    // The phone header. `.page-header-mobile` existed in the stylesheet and
    // was applied by nothing, so below 768px the project name, the progress
    // bar, Milestones, Edit project and the search field all disappeared and
    // there was no way to manage milestones on a phone at all.
    document.querySelectorAll('.page-header').forEach(h => h.classList.add('page-header-mobile'));

    if (main) {
      const bar = document.createElement('div');
      bar.className = 'mobile-topbar';
      bar.innerHTML = `
        <button class="topbar-btn" type="button" aria-label="Open navigation" data-act="menu">${svg(NAV_ICONS.menu, 20)}</button>
        <span class="topbar-title" id="topbar-title">${esc(opts.title || 'Graft')}</span>
        <button class="topbar-btn" type="button" aria-label="Search" data-act="search">${svg(NAV_ICONS.search, 20)}</button>
        <button class="header-more" type="button" aria-label="More actions" aria-haspopup="menu"
                data-act="more" style="display:none">${svg(DOTS_ICON, 20)}</button>`;
      main.prepend(bar);
      bar.querySelector('[data-act="menu"]').onclick = openDrawer;
      bar.querySelector('[data-act="search"]').onclick = openPalette;
      bar.querySelector('[data-act="more"]').onclick = e => openMenu(e.currentTarget, _topbarMenu);
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

  function setTopbarTitle(text) {
    const el = document.getElementById('topbar-title');
    if (el) el.textContent = text;
    const drawerEl = document.getElementById('drawer-topbar-title');
    if (drawerEl) drawerEl.textContent = text;
  }

  // The overflow menu is where everything the desktop header shows in full
  // lives on a phone: milestones, edit, archive, delete.
  function setTopbarMenu(items) {
    _topbarMenu = items || [];
    const btn = document.querySelector('.mobile-topbar [data-act="more"]');
    if (btn) btn.style.display = _topbarMenu.length ? '' : 'none';
  }

  // Mirrors the sidebar into the drawer, so the project list added later
  // by renderRail() shows up in both.
  function syncDrawer() {
    const drawer = document.getElementById('drawer');
    const sidebar = document.querySelector('.sidebar');
    if (!drawer || !sidebar) return;
    drawer.innerHTML = sidebar.innerHTML;
    // A straight copy would repeat every id the sidebar has. Prefix them so
    // the document stays valid and getElementById still finds the original —
    // the drawer is refreshed from the sidebar, never populated directly.
    drawer.querySelectorAll('[id]').forEach(el => { el.id = `drawer-${el.id}`; });
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
    setDrawerInert(!drawer.classList.contains('open'));
  }

  // Closed, the drawer is a complete invisible copy of the navigation sitting
  // in the tab order. inert takes it out of it.
  function setDrawerInert(off) {
    const drawer = document.getElementById('drawer');
    if (!drawer) return;
    if (off) drawer.setAttribute('inert', '');
    else drawer.removeAttribute('inert');
  }

  function openDrawer() {
    document.getElementById('drawer')?.classList.add('open');
    document.getElementById('drawer-scrim')?.classList.add('open');
    setDrawerInert(false);
    document.body.style.overflow = 'hidden';
  }

  function closeDrawer() {
    document.getElementById('drawer')?.classList.remove('open');
    document.getElementById('drawer-scrim')?.classList.remove('open');
    setDrawerInert(true);
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
    overlay.onclick = closePalette;
    document.body.appendChild(overlay);

    const el = document.createElement('div');
    el.className = 'palette';
    el.id = 'palette';
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-label', 'Search');
    el.innerHTML = `
      <input class="palette-input" id="palette-input" placeholder="Search issues and projects…"
             autocomplete="off" spellcheck="false" aria-label="Search issues and projects">
      <div class="palette-results" id="palette-results">${skeleton('issue', 3)}</div>`;
    document.body.appendChild(el);
    document.body.style.overflow = 'hidden';
    trapFocus(el);
    document.getElementById('palette-input').focus();
    document.getElementById('palette-input').addEventListener('input', e => renderPalette(e.target.value));

    if (!_paletteData) await fetchPaletteData();
    else renderPalette('');
  }

  // A failed fetch used to be cached as {projects: [], issues: []} for the
  // rest of the session, so a dead server looked exactly like an empty
  // workspace — and kept looking like one until you reloaded the page.
  // Nothing is cached unless it actually arrived.
  async function fetchPaletteData() {
    const box = document.getElementById('palette-results');
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
      renderPalette(document.getElementById('palette-input')?.value || '');
    } catch {
      _paletteData = null;
      if (box) {
        box.innerHTML = errorState({
          title: 'Search is unavailable',
          body: 'Graft couldn’t reach the server, so this isn’t an empty workspace — it’s an unreachable one.',
          onRetry: 'GRAFT._retryPalette()',
        });
      }
    }
  }

  async function _retryPalette() {
    const box = document.getElementById('palette-results');
    if (box) box.innerHTML = skeleton('issue', 3);
    await fetchPaletteData();
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
      box.innerHTML = `<div class="palette-empty">${q
        ? 'Nothing matches “' + esc(query) + '”'
        : 'Nothing here yet — create a project to search across it'}</div>`;
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
    const el = document.getElementById('palette');
    if (el) releaseFocus(el);
    el?.remove();
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
        e.preventDefault();
        // The bar's search field is the search on a list surface, and the
        // palette is the one that crosses the whole workspace.
        const field = document.getElementById('org-q');
        if (field) { field.focus(); field.select(); }
        else openPalette();
        return;
      }
      if (e.key === 'Escape') {
        // A popover is the shallowest thing on screen, so it closes first.
        if (document.querySelector('.popover')) { closeMenus(); return; }
        if (document.getElementById('drawer')?.classList.contains('open')) { closeDrawer(); return; }
        if (document.getElementById('issue-slideover')?.style.display === 'flex') { closeSlideover(); return; }
        const open = [...document.querySelectorAll('.modal-overlay')].find(m => m.style.display === 'flex');
        if (open?.id) { closeModal(open.id); return; }
        if (_selection.size) { clearSelection(); return; }
        return;
      }
      // The old guard only asked whether the focused element was a field, so
      // clicking any non-field part of an open Edit issue modal and pressing
      // "c" blanked every field in the form you were filling in.
      if (isTyping(e) || anyModalOpen() || e.metaKey || e.ctrlKey || e.altKey) return;

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
    openNewProject, openNewIssue, openEditIssue,
    submitProject, deleteProject, submitIssue, deleteIssue,
    archiveCurrentProject,
    setView,
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
    openDrawer, closeDrawer, openPalette, closePalette, _retryPalette,
    // the organisation bar
    _clearFilter, _clearAllFilters, _toggleArchived, _onSearchInput,
    // areas, links, views
    createArea, _areaMenu, _toggleArea, _toggleRailArea,
    _addLink, _editLink, _linkMenu, _removeLink,
    _applyView: applySavedView, _deleteView: deleteSavedView,
    // drag and drop
    _onCardDragStart, _onCardDragEnd, _onAreaDragOver, _onAreaDragLeave, _onAreaDrop,
    // retries
    _retryRail, _retryProjects, _retryIssues, _retryProject, _retryToday,
    _retryProjectLinks, _retrySlideoverLinks,
    // today
    _expandToday, _collapseToday,
    // rows, status, selection
    _openStatusMenu, setIssueStatus, _toggleSelect, clearSelection,
    archiveIssue, deleteIssueById, _goToIssue,
  };
})();
