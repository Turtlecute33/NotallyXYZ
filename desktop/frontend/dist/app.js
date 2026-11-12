// NotallyXYZ desktop UI. The Go side (app.go) holds the notes; this file only shows and edits them.
import { NoteEditor, attURL } from './editor.js';
import { iconEl } from './icons.js';
import { normalized } from './listops.js';
import { renderSpans } from './richtext.js';
import { showSettings } from './settings.js';
import { showSetup } from './setup.js';
import { PRESETS, ago, applyColor, confirm, h, iconButton, menu, prompt, shortDate, toast, errText } from './ui.js';

const api = window.go.main.App;
const rt = window.runtime;
// Shows the error of a call into Go. Resolves true on success.
const ok = (call) => call.then(() => true, (e) => { toast(errText(e)); return false; });

const app = {
  state: null,
  settings: null,
  notes: [],
  labels: [],
  view: { kind: 'notes' }, // notes | reminders | unlabeled | archived | deleted | label (name)
  search: '',
  editor: null,
  settingsOpen: false,
};

// Theme and text size

function applyAppearance() {
  const s = app.settings;
  const root = document.documentElement;
  if (s.theme === 'system') delete root.dataset.theme; else root.dataset.theme = s.theme;
  root.dataset.size = s.textSize;
  root.dataset.card = s.cardSize;
}

// Data

async function reload() {
  app.state = await api.GetState();
  app.settings = app.state.settings;
  applyAppearance();
  if (!app.state.connected) {
    app.notes = [];
    app.labels = [];
    return;
  }
  [app.notes, app.labels] = await Promise.all([api.Notes(), api.Labels()]);
}

let refreshQueued = false;
async function refresh() {
  if (refreshQueued) return;
  refreshQueued = true;
  await new Promise((r) => setTimeout(r, 30));
  refreshQueued = false;
  const wasConnected = app.state?.connected;
  const wasError = app.state?.startupError;
  await reload();
  // A startup error can come after the first GetState. Draw the setup screen again to show it.
  if (app.state.connected !== wasConnected || (!app.state.connected && app.state.startupError !== wasError)) return render();
  if (!app.state.connected) return;
  renderSidebar();
  // The editor covers the grid. editorClosed() calls refresh(), and that draws the grid.
  if (app.editor) app.editor.external(app.notes.find((n) => n.id === app.editor.note.id));
  else renderNotes();
}
app.refresh = refresh;

// Shell

let searchTimer = 0;

function render() {
  const root = document.getElementById('app');
  root.textContent = '';
  app.editor = null;
  if (!app.state.connected) {
    showSetup(root, app, async () => { await reload(); render(); });
    return;
  }
  root.append(
    h('aside', { class: 'sidebar' },
      h('div', { class: 'brand' }, h('img', { src: 'icon.png', alt: '' }), 'NotallyXYZ'),
      h('nav', { class: 'nav', id: 'nav', 'aria-label': 'Folders and labels' }),
      h('div', { class: 'sync-status', id: 'sync', 'aria-live': 'polite' })),
    h('main', { class: 'main', id: 'main' },
      h('div', { class: 'topbar' },
        h('h1', { id: 'title' }),
        h('label', { class: 'search' }, iconEl('search'),
          h('input', { id: 'search', type: 'search', placeholder: 'Search', value: app.search, spellcheck: false,
            oninput: (e) => { app.search = e.target.value; clearTimeout(searchTimer); searchTimer = setTimeout(renderNotes, 150); } })),
        h('div', { class: 'spacer' }),
        h('span', { id: 'view-actions', style: 'display:flex;gap:4px' })),
      h('div', { class: 'content', id: 'content', tabindex: '-1' }),
      h('div', { class: 'fab', id: 'fab' },
        h('button', { class: 'round', title: 'New list (Ctrl+Shift+N)', 'aria-label': 'New list', onclick: () => newNote('LIST') }, iconEl('list')),
        h('button', { class: 'primary', title: 'New note (Ctrl+N)', onclick: () => newNote('NOTE') }, iconEl('edit'), 'New note'))));
  renderSidebar();
  renderStatus(app.state.status);
  renderNotes();
}

function navItem(iconName, label, view, extra = {}) {
  const active = !app.settingsOpen && app.view.kind === view.kind && app.view.name === view.name;
  return h('button', { class: 'nav-item' + (active ? ' active' : ''), title: label, 'aria-current': active ? 'page' : null,
    onclick: () => go(view), oncontextmenu: extra.menu }, iconEl(iconName), h('span', { text: label }));
}

function go(view) {
  app.view = view;
  app.editor?.close();
  closeSettings();
  renderSidebar();
  document.getElementById('content')?.scrollTo(0, 0);
  renderNotes();
}

function renderSidebar() {
  const nav = document.getElementById('nav');
  if (!nav) return;
  nav.textContent = '';
  nav.append(navItem('note', 'Notes', { kind: 'notes' }), navItem('bell', 'Reminders', { kind: 'reminders' }));
  nav.appendChild(h('div', { class: 'nav-title', text: 'Labels' }));
  for (const l of app.labels) {
    nav.appendChild(navItem('tag', l.value, { kind: 'label', name: l.value }, {
      menu: (e) => {
        e.preventDefault();
        menu(e.clientX, e.clientY, [
          { label: 'Rename…', icon: 'edit', action: () => renameLabel(l.value) },
          { label: 'Delete…', icon: 'trash', danger: true, action: () => deleteLabel(l.value) },
        ]);
      },
    }));
  }
  nav.append(
    navItem('tagOff', 'Unlabeled', { kind: 'unlabeled' }),
    h('button', { class: 'nav-item add', onclick: newLabel }, iconEl('plus'), h('span', { text: 'New label' })),
    h('div', { class: 'nav-title' }),
    navItem('archive', 'Archived', { kind: 'archived' }),
    navItem('trash', 'Deleted', { kind: 'deleted' }),
    h('button', { class: 'nav-item' + (app.settingsOpen ? ' active' : ''), onclick: openSettings }, iconEl('settings'), h('span', { text: 'Settings' })));
}

async function newLabel() {
  const v = await prompt('New label', '', 'Name', 'Create');
  if (v?.trim()) await api.CreateLabel(v.trim());
}

async function renameLabel(old) {
  const v = await prompt('Rename label', old, 'Name', 'Rename');
  if (!v?.trim() || v.trim() === old) return;
  await api.RenameLabel(old, v.trim());
  if (app.view.kind === 'label' && app.view.name === old) app.view = { kind: 'label', name: v.trim() };
}

async function deleteLabel(value) {
  if (!(await confirm(`Delete label “${value}”?`, 'It is removed from all notes. The notes stay.', 'Delete label'))) return;
  await api.DeleteLabel(value);
  if (app.view.kind === 'label' && app.view.name === value) app.view = { kind: 'notes' };
}

function renderStatus(st) {
  const el = document.getElementById('sync');
  if (!el || !st) return;
  el.textContent = '';
  el.classList.toggle('error', !!st.error && !st.syncing);
  let text, ic = 'cloud';
  if (st.syncing) { text = 'Syncing…'; ic = 'sync'; }
  else if (st.error) { text = st.error; ic = 'alert'; }
  else if (st.lastSync) text = Date.now() - st.lastSync < 60e3 ? 'Synced just now' : 'Synced ' + ago(st.lastSync);
  else text = 'Not synced yet';
  const i = iconEl(ic);
  if (st.syncing) i.classList.add('spin');
  el.append(i, h('span', { class: 'text', text, title: text }), iconButton('sync', 'Sync now', () => api.SyncNow(), { class: 'small' }));
  el.lastElementChild.style.cssText = 'width:28px;height:28px';
}

// Notes overview

function viewTitle() {
  return { notes: 'Notes', reminders: 'Reminders', unlabeled: 'Unlabeled', archived: 'Archived', deleted: 'Deleted' }[app.view.kind] ?? app.view.name;
}

function filtered() {
  const v = app.view;
  let notes = app.notes.filter((n) => {
    switch (v.kind) {
      case 'notes': return n.folder === 'NOTES';
      case 'reminders': return n.folder === 'NOTES' && n.reminders.length > 0;
      case 'unlabeled': return n.folder === 'NOTES' && n.labels.length === 0;
      case 'archived': return n.folder === 'ARCHIVED';
      case 'deleted': return n.folder === 'DELETED';
      case 'label': return n.folder !== 'DELETED' && n.labels.includes(v.name);
    }
    return false;
  });
  const q = app.search.trim().toLocaleLowerCase();
  if (q) {
    const has = (s) => s.toLocaleLowerCase().includes(q);
    notes = notes.filter((n) => has(n.title) || has(n.body) || n.items.some((i) => has(i.body)) || n.labels.some(has));
  }
  if (v.kind === 'reminders') return notes.sort((a, b) => (a.nextReminder || Infinity) - (b.nextReminder || Infinity));
  const s = app.settings;
  const cmp = {
    modified: (a, b) => a.modifiedTimestamp - b.modifiedTimestamp,
    created: (a, b) => a.timestamp - b.timestamp,
    title: (a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: 'base' }),
    color: (a, b) => (a.color < b.color ? -1 : a.color > b.color ? 1 : a.timestamp - b.timestamp),
  }[s.sortBy];
  return notes.sort((a, b) => {
    const r = cmp(a, b) || (a.id < b.id ? -1 : 1);
    return s.sortAscending ? r : -r;
  });
}

function renderViewActions() {
  const box = document.getElementById('view-actions');
  box.textContent = '';
  if (app.view.kind === 'deleted') {
    box.appendChild(iconButton('trash', 'Empty bin', async () => {
      if (await confirm('Empty the bin?', 'All notes in the bin are deleted forever, on all your devices.', 'Empty bin')) ok(api.EmptyBin());
    }));
  }
  box.append(
    iconButton('sort', 'Sort', (e) => {
      const r = e.currentTarget.getBoundingClientRect();
      const s = app.settings;
      const mark = (on) => (on ? '✓ ' : '  ');
      menu(r.left - 140, r.bottom + 4, [
        ...[['modified', 'Modified date'], ['created', 'Creation date'], ['title', 'Title'], ['color', 'Color']]
          .map(([k, label]) => ({ label: mark(s.sortBy === k) + label, action: () => setSettings({ sortBy: k }) })),
        'sep',
        { label: mark(!s.sortAscending) + 'Descending', action: () => setSettings({ sortAscending: false }) },
        { label: mark(s.sortAscending) + 'Ascending', action: () => setSettings({ sortAscending: true }) },
      ]);
    }),
    iconButton(app.settings.layout === 'grid' ? 'rows' : 'grid', app.settings.layout === 'grid' ? 'Show as list' : 'Show as grid',
      () => setSettings({ layout: app.settings.layout === 'grid' ? 'list' : 'grid' })));
}

async function setSettings(patch) {
  app.settings = await api.SetSettings({ ...app.settings, ...patch });
  app.state.settings = app.settings;
  applyAppearance();
  renderNotes();
}
app.setSettings = setSettings;

function renderNotes() {
  const content = document.getElementById('content');
  if (!content) return;
  document.getElementById('title').textContent = viewTitle();
  document.getElementById('fab').classList.toggle('hidden', ['archived', 'deleted'].includes(app.view.kind));
  renderViewActions();
  const notes = filtered();
  const top = content.scrollTop;
  const focusId = app.focusAfter;
  app.focusAfter = null;
  // layoutMasonry reads the layout while the grid is empty, and the scroll goes to the top. It runs first, so put the scroll back here.
  // The focus goes back to the card of the closed note, if the focus went with the editor.
  const restore = () => requestAnimationFrame(() => {
    content.scrollTop = top;
    if (focusId && document.activeElement === document.body) {
      (content.querySelector(`.card[data-id="${CSS.escape(focusId)}"]`) || content).focus({ preventScroll: true });
    }
  });
  content.textContent = '';
  if (!notes.length) {
    const [ic, text] = app.search ? ['search', 'No results'] : {
      deleted: ['trash', 'The bin is empty'], archived: ['archive', 'No archived notes'], reminders: ['bell', 'No reminders'],
    }[app.view.kind] || ['note', 'No notes yet'];
    content.appendChild(h('div', { class: 'empty' }, iconEl(ic), h('div', { text })));
    restore();
    return;
  }
  const pinned = app.view.kind === 'deleted' ? [] : notes.filter((n) => n.pinned);
  const others = app.view.kind === 'deleted' ? notes : notes.filter((n) => !n.pinned);
  if (pinned.length) {
    content.appendChild(h('div', { class: 'section-title', text: 'Pinned' }));
    content.appendChild(cards(pinned));
    if (others.length) content.appendChild(h('div', { class: 'section-title', text: 'Others' }));
  }
  if (others.length) content.appendChild(cards(others));
  restore();
}

function cards(notes) {
  if (app.settings.layout === 'list') return h('div', { class: 'list-view' }, notes.map(card));
  const box = h('div', { class: 'masonry', 'data-count': String(notes.length) });
  box.notes = notes;
  requestAnimationFrame(() => layoutMasonry(box));
  return box;
}

// Cards go into the shortest column, in order, like a staggered grid.
function layoutMasonry(box) {
  const width = box.clientWidth || document.getElementById('content').clientWidth - 40;
  const gap = 12, min = 230;
  const n = Math.max(1, Math.floor((width + gap) / (min + gap)));
  if (box.cols === n && box.childElementCount) return;
  box.cols = n;
  box.textContent = '';
  const cols = Array.from({ length: n }, () => box.appendChild(h('div', { class: 'col' })));
  const heights = new Array(n).fill(0);
  for (const note of box.notes) {
    const i = heights.indexOf(Math.min(...heights));
    const c = card(note);
    cols[i].appendChild(c);
    heights[i] += c.offsetHeight + gap;
  }
}

new ResizeObserver(() => document.querySelectorAll('.masonry').forEach(layoutMasonry)).observe(document.body);

function card(note) {
  const s = app.settings;
  const el = h('div', { class: 'card', tabindex: '0', role: 'button', 'data-id': note.id, 'aria-label': note.title || 'Untitled note',
    onclick: (e) => { if (!e.target.closest('.more-btn, .sl')) openNote(note.id); },
    onkeydown: (e) => { if (e.key === 'Enter') openNote(note.id); },
    oncontextmenu: (e) => { e.preventDefault(); noteMenu(note, e.clientX, e.clientY); } });
  applyColor(el, note.color);
  if (s.showImages && note.images.length) {
    const img = note.images[0];
    const thumb = h('div', { class: 'thumb' }, h('img', { src: attURL(img.localName, img.mimeType), alt: '', loading: 'lazy', decoding: 'async' }));
    thumb.firstChild.addEventListener('error', () => thumb.firstChild.remove());
    if (note.images.length > 1) thumb.appendChild(h('span', { class: 'badge' }, iconEl('image'), String(note.images.length)));
    el.appendChild(thumb);
  }
  const inner = h('div', { class: 'inner' });
  if (note.pinned) inner.appendChild(h('span', { class: 'pin-mark', title: 'Pinned' }, iconEl('pin')));
  if (note.title) inner.appendChild(h('div', { class: 'title', text: note.title }));
  const meta = h('div', { class: 'meta' });
  if (s.showDate) meta.appendChild(h('span', { text: s.sortBy === 'created' ? 'Created ' + ago(note.timestamp) : 'Modified ' + ago(note.modifiedTimestamp) }));
  if (note.nextReminder) meta.appendChild(h('span', { class: 'chip' }, iconEl('bell'), shortDate(note.nextReminder)));
  if (note.audios.length) meta.appendChild(iconEl('wave'));
  if (meta.childElementCount) inner.appendChild(meta);
  if (note.files.length) {
    const f = note.files[0];
    inner.appendChild(h('div', {}, h('span', { class: 'chip' }, iconEl('file'), note.files.length > 1 ? `${f.originalName} +${note.files.length - 1}` : f.originalName)));
  }
  // Without a preview, a note without a title still shows its first line, like Android.
  const preview = s.showPreview || !note.title;
  const lines = s.showPreview ? s.previewLines : 1, maxItems = s.showPreview ? s.previewItems : 1;
  if (preview && note.type === 'NOTE' && note.body) {
    const body = h('div', { class: 'body' });
    body.style.webkitLineClamp = String(lines);
    // The card shows a few lines: render the start of a long body only, not inside a surrogate pair.
    const end = /[\uD800-\uDBFF]/.test(note.body[1499] || '') ? 1499 : 1500;
    renderSpans(body, note.body.slice(0, end), note.spans);
    body.addEventListener('click', (e) => {
      const link = e.target.closest('.sl');
      if (link) { e.stopPropagation(); app.openLink(link.dataset.link); }
    });
    inner.appendChild(body);
  } else if (preview && note.type === 'LIST' && note.items.length) {
    const items = normalized(note.items, false);
    const list = h('div', { class: 'items' });
    for (const it of items.slice(0, maxItems)) {
      list.appendChild(h('div', { class: 'item' + (it.isChild ? ' child' : '') + (it.checked ? ' checked' : '') },
        iconEl(it.checked ? 'boxChecked' : 'box'), h('span', { text: it.body })));
    }
    if (items.length > maxItems) list.appendChild(h('div', { class: 'muted small', text: `+${items.length - maxItems}` }));
    inner.appendChild(list);
  }
  if (s.showLabels && note.labels.length) {
    inner.appendChild(h('div', { class: 'chips' }, note.labels.slice(0, 4).map((l) => h('span', { class: 'chip', text: l })),
      note.labels.length > 4 ? h('span', { class: 'muted small', text: `+${note.labels.length - 4}` }) : null));
  }
  if (!inner.childElementCount) inner.appendChild(h('div', { class: 'muted', text: 'Empty note' }));
  el.appendChild(inner);
  el.appendChild(iconButton('more', 'More', (e) => {
    e.stopPropagation();
    const r = e.currentTarget.getBoundingClientRect();
    noteMenu(note, r.left, r.bottom);
  }, { class: 'more-btn' }));
  return el;
}

// The card can be older than the note (sync): PatchNote changes only the given fields of the current note.
function noteMenu(note, x, y) {
  if (note.folder === 'DELETED') {
    menu(x, y, [
      { label: 'Restore', icon: 'restore', action: () => moveNote(note.id, 'NOTES') },
      { label: 'Delete forever', icon: 'trash', danger: true, action: async () => {
        if (await confirm('Delete forever?', 'The note is deleted on all your devices.', 'Delete')) ok(api.DeleteForever(note.id));
      } },
    ]);
    return;
  }
  menu(x, y, [
    { label: note.pinned ? 'Unpin' : 'Pin', icon: 'pin', action: () => ok(api.PatchNote(note.id, { pinned: !note.pinned })) },
    { label: 'Color…', icon: 'palette', action: () => colorMenu(note, x, y) },
    { label: 'Duplicate', icon: 'copy', action: () => ok(api.Duplicate(note.id)) },
    'sep',
    note.folder === 'ARCHIVED' ? { label: 'Unarchive', icon: 'archive', action: () => moveNote(note.id, 'NOTES') }
      : { label: 'Archive', icon: 'archive', action: () => moveNote(note.id, 'ARCHIVED', 'Note archived') },
    { label: 'Delete', icon: 'trash', danger: true, action: () => moveNote(note.id, 'DELETED', 'Note moved to the bin') },
  ]);
}

function colorMenu(note, x, y) {
  menu(x, y, PRESETS.map(([name, hex]) => ({ label: (note.color === hex ? '✓ ' : '  ') + name,
    action: () => ok(api.PatchNote(note.id, { color: hex })) })));
}

async function moveNote(id, folder, message) {
  const note = app.notes.find((n) => n.id === id);
  if (!note) return;
  const before = note.folder;
  if (!(await ok(api.PatchNote(id, { folder })))) return;
  if (message) toast(message, { label: 'Undo', run: () => moveNote(id, before) });
}
app.moveNote = moveNote;

// Editor

async function newNote(type) {
  const note = await api.NewNote(type);
  if (app.view.kind === 'label') note.labels = [app.view.name];
  if (!['notes', 'unlabeled', 'label'].includes(app.view.kind)) go({ kind: 'notes' });
  openEditor(note, true);
}

function openNote(id) {
  const note = app.notes.find((n) => n.id === id);
  if (!note) { toast('This note is not on this device.'); return; }
  const want = { NOTES: null, ARCHIVED: 'archived', DELETED: 'deleted' }[note.folder];
  if (want && app.view.kind !== want) go({ kind: want });
  else if (!want && ['archived', 'deleted'].includes(app.view.kind)) go({ kind: 'notes' });
  openEditor(note, false);
}
app.openNote = openNote;

async function openEditor(note, isDraft) {
  closeSettings();
  if (app.editor && !(await app.editor.close())) return; // not saved: it stays open
  app.editor = new NoteEditor(app, note, isDraft);
  document.getElementById('main').appendChild(app.editor.el);
}

app.editorClosed = (editor) => {
  if (app.editor === editor) app.editor = null;
  app.focusAfter = editor.note.id;
  refresh();
};

app.openLink = (link) => {
  if (!link) return;
  const m = /^note:\/\/([0-9a-f]{32})\//.exec(link);
  if (m) { openNote(m[1]); return; }
  if (/^note:\/\//.test(link)) { toast('The linked note is not on this device.'); return; }
  api.OpenURL(link).catch((e) => toast(errText(e)));
};

app.lightbox = (src) => {
  const box = h('div', { class: 'lightbox', onclick: () => close() }, h('img', { src, alt: '' }));
  const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  const close = () => { box.remove(); document.removeEventListener('keydown', key, true); };
  document.addEventListener('keydown', key, true);
  document.body.appendChild(box);
};

// Settings

async function openSettings() {
  if (app.editor && !(await app.editor.close())) return;
  app.settingsOpen = true;
  renderSidebar();
  showSettings(document.getElementById('main'), app, () => { app.settingsOpen = false; renderSidebar(); });
}

function closeSettings() {
  document.querySelector('.settings')?.remove();
  if (app.settingsOpen) { app.settingsOpen = false; renderSidebar(); }
}

// Keyboard

document.addEventListener('keydown', (e) => {
  const mod = e.ctrlKey || e.metaKey;
  const k = e.key.toLowerCase();
  if (e.key === 'F5' || (mod && k === 'r')) { e.preventDefault(); api.SyncNow(); return; }
  if (!app.state?.connected || document.querySelector('.scrim')) return;
  if (mod && k === 'n') { e.preventDefault(); newNote(e.shiftKey ? 'LIST' : 'NOTE'); }
  else if (mod && k === 'f') { e.preventDefault(); app.editor?.close(); closeSettings(); document.getElementById('search')?.focus(); }
  else if (mod && e.key === ',') { e.preventDefault(); openSettings(); }
});

// Events from Go

rt.EventsOn('changed', () => refresh());
rt.EventsOn('status', (st) => { if (app.state) app.state.status = st; renderStatus(st); });
rt.EventsOn('open', (id) => openNote(id));
rt.EventsOn('reminder', (r) => toast('⏰ ' + r.title, { label: 'Open', run: () => openNote(r.id) }, 15000));
// Go holds the first close of the window. Save the pending change (and wait for a save that runs), then quit.
rt.EventsOn('quit', async () => {
  if (!app.editor || (await app.editor.save())) rt.Quit();
  else toast('The note is not saved. Close the window again to quit without saving it.', null, 15000);
});
window.addEventListener('focus', () => { if (app.state?.connected) api.SyncNow(); });
// Relative dates and next reminders stay current.
setInterval(() => { if (app.state?.connected && !app.editor) refresh(); }, 60e3);

document.addEventListener('contextmenu', (e) => {
  // Keep the default menu (copy, paste) only in text fields.
  if (!e.target.closest('input, textarea, [contenteditable]:not([contenteditable="false"])')) e.preventDefault();
});
// A dropped file must not open in the web view. List items take their own drags (reorder).
const noDrop = (e) => {
  if (Array.from(e.dataTransfer?.types || []).includes('Files') || !e.target.closest?.('.li')) e.preventDefault();
};
document.addEventListener('dragover', noDrop);
document.addEventListener('drop', noDrop);

await reload();
render();
