// Note editor, like NotallyX EditActivity: note color as background, title, dates, content,
// attachments and labels. Changes are saved after a short pause and when the editor closes.
import { iconEl } from './icons.js';
import { ListEditor } from './listeditor.js';
import { B, I, M, S, L, RichText } from './richtext.js';
import { PRESETS, ago, applyColor, confirm, dialog, fullDate, h, iconButton, menu, prompt, rgba, shortDate, toast, errText } from './ui.js';

const api = () => window.go.main.App;
const clone = (n) => { const c = JSON.parse(JSON.stringify(n)); delete c.nextReminder; return c; };

export function isEmptyNote(n) {
  return !n.title && !n.body && n.items.every((i) => !i.body) && !n.images.length && !n.files.length && !n.audios.length;
}

export function attURL(name, mime) {
  return '/att/' + encodeURIComponent(name) + (mime ? '?m=' + encodeURIComponent(mime) : '');
}

export function repetitionText(r) {
  if (!r) return '';
  if (r.unit === 'MONTHS' && r.occurrence && r.dayOfWeek) {
    const day = new Date(2023, 0, r.dayOfWeek).toLocaleDateString(undefined, { weekday: 'long' }); // 2023-01-01 is a Sunday
    const which = r.occurrence === -1 ? 'last' : ['1st', '2nd', '3rd', '4th'][r.occurrence - 1];
    return `${r.value === 1 ? 'Monthly' : `Every ${r.value} months`} on the ${which} ${day}`;
  }
  const names = { DAYS: 'Daily', WEEKS: 'Weekly', MONTHS: 'Monthly', YEARS: 'Yearly' };
  if (r.value === 1 && names[r.unit]) return names[r.unit];
  return `Every ${r.value} ${r.unit.toLowerCase()}`;
}

export class NoteEditor {
  constructor(app, note, isDraft) {
    this.app = app;
    this.note = clone(note);
    this.isDraft = isDraft;
    this.dirty = false;
    this.timer = null;
    this.lastSaved = clone(note);
    api().EditorOpened(note.id);
    this.el = h('div', { class: 'editor', role: 'region', 'aria-label': 'Note editor' });
    this.onKey = (e) => {
      if (e.key === 'Escape' && !document.querySelector('.scrim, .menu, .lightbox')) { e.preventDefault(); this.close(); }
    };
    document.addEventListener('keydown', this.onKey);
    this.build();
  }

  get editable() { return this.note.viewMode !== 'READ_ONLY' && this.note.folder !== 'DELETED'; }

  build() {
    const n = this.note;
    this.rich?.destroy();
    this.rich = null;
    this.el.textContent = '';
    applyColor(this.el, n.color);
    this.el.appendChild(this.toolbar());
    const page = h('div', { class: 'editor-page' });
    const title = h('textarea', { class: 'title-input', rows: 1, placeholder: 'Title', readOnly: !this.editable, spellcheck: true });
    title.value = n.title;
    const size = () => { title.style.height = 'auto'; title.style.height = title.scrollHeight + 'px'; };
    title.addEventListener('input', () => { this.update((x) => { x.title = title.value.replace(/\n/g, ' '); }, true); size(); });
    title.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); (this.rich?.el || this.el.querySelector('.li textarea'))?.focus(); }
    });
    requestAnimationFrame(size);
    page.appendChild(title);
    this.dates = h('div', { class: 'dates' });
    this.updateDates();
    page.appendChild(this.dates);

    if (n.type === 'NOTE') {
      this.rich = new RichText({
        text: n.body, spans: n.spans, editable: this.editable, placeholder: 'Note',
        onChange: (body, spans) => this.update((x) => { x.body = body; x.spans = spans; }, true),
        onOpenLink: (link) => this.app.openLink(link),
      });
      page.appendChild(this.rich.el);
    } else {
      this.list = new ListEditor({
        items: n.items, editable: this.editable, autoSort: this.app.settings.autoSortChecked,
        onChange: (items) => this.update((x) => { x.items = items; }, true),
      });
      page.appendChild(this.list.el);
      if (!n.items.length && this.editable) this.list.add();
    }
    this.attachments = h('div', { class: 'attachments' });
    page.appendChild(this.attachments);
    this.renderAttachments();
    this.labelChips = h('div', { class: 'chips', title: 'Edit labels', onclick: () => this.editLabels() });
    page.appendChild(this.labelChips);
    this.renderLabels();
    this.el.appendChild(h('div', { class: 'editor-scroll' }, page));
    if (n.type === 'NOTE' && this.editable) this.el.appendChild(this.formatBar());
    if (this.isDraft) requestAnimationFrame(() => (n.type === 'NOTE' ? this.rich.el : title).focus());
  }

  updateDates() {
    const n = this.note;
    this.dates.textContent = `Created ${fullDate(n.timestamp)}  ·  Modified ${ago(n.modifiedTimestamp)}`;
  }

  toolbar() {
    const n = this.note;
    const bar = h('div', { class: 'editor-bar' }, iconButton('back', 'Back (Esc)', () => this.close()), h('div', { class: 'spacer' }));
    if (n.folder === 'DELETED') {
      bar.append(
        h('button', { class: 'btn', onclick: () => this.move('NOTES') }, 'Restore'),
        h('button', { class: 'btn danger', onclick: () => this.deleteForever() }, 'Delete forever'));
      return bar;
    }
    bar.append(
      iconButton('pin', n.pinned ? 'Unpin' : 'Pin', () => { this.update((x) => { x.pinned = !x.pinned; }); this.rebuildBar(); },
        { class: n.pinned ? 'on' : '' }),
      iconButton('bell', 'Reminders', () => this.editReminders(), { class: n.reminders.length ? 'on' : '' }),
      iconButton('palette', 'Color', () => this.editColor()),
      iconButton('tag', 'Labels', () => this.editLabels()),
      iconButton('image', 'Add images', () => this.addAttachments('image'), { attrs: { disabled: !this.editable } }),
      iconButton('attach', 'Add files', () => this.addAttachments('file'), { attrs: { disabled: !this.editable } }),
      iconButton(n.viewMode === 'READ_ONLY' ? 'lock' : 'edit', n.viewMode === 'READ_ONLY' ? 'Read only (click to edit)' : 'Editing (click for read only)', () => {
        this.update((x) => { x.viewMode = x.viewMode === 'READ_ONLY' ? 'EDIT' : 'READ_ONLY'; });
        this.build();
      }),
      iconButton('more', 'More', (e) => {
        const r = e.currentTarget.getBoundingClientRect();
        menu(r.left - 150, r.bottom + 4, [
          { label: 'Duplicate', icon: 'copy', action: () => this.duplicate() },
          { label: 'Copy text', icon: 'copy', action: () => window.runtime.ClipboardSetText(this.plainText()) },
          'sep',
          n.folder === 'ARCHIVED' ? { label: 'Unarchive', icon: 'archive', action: () => this.move('NOTES') }
            : { label: 'Archive', icon: 'archive', action: () => this.move('ARCHIVED') },
          { label: 'Delete', icon: 'trash', danger: true, action: () => this.move('DELETED') },
        ]);
      }),
    );
    return bar;
  }

  rebuildBar() { this.el.querySelector('.editor-bar').replaceWith(this.toolbar()); }

  formatBar() {
    const btn = (icon, title, fn) => {
      const b = iconButton(icon, title, fn);
      b.addEventListener('mousedown', (e) => e.preventDefault()); // keep the text selection
      return b;
    };
    return h('div', { class: 'format-bar' },
      btn('bold', 'Bold (Ctrl+B)', () => this.rich.toggle(B)),
      btn('italic', 'Italic (Ctrl+I)', () => this.rich.toggle(I)),
      btn('code', 'Monospace', () => this.rich.toggle(M)),
      btn('strike', 'Strikethrough', () => this.rich.toggle(S)),
      btn('link', 'Link', () => this.editLink()),
      btn('eraser', 'Clear formatting', () => this.rich.clearFormat()));
  }

  async editLink() {
    if (!this.rich.range()) { toast('Select text first.'); return; }
    const sel = this.rich.range();
    const current = this.rich.selectedLink();
    const url = await prompt('Link', current, 'https://…', 'Set');
    if (url === null) return;
    this.rich.el.focus();
    this.rich.lastSel = sel;
    this.rich.setSel(sel);
    this.rich.setLink(url.trim() || null);
  }

  plainText() {
    const n = this.note;
    const body = n.type === 'NOTE' ? n.body : n.items.map((i) => `${i.isChild ? '    ' : ''}${i.checked ? '[x]' : '[ ]'} ${i.body}`).join('\n');
    return [n.title, body].filter(Boolean).join('\n\n');
  }

  update(fn, content = false) {
    fn(this.note);
    if (content) this.note.modifiedTimestamp = Date.now();
    this.dirty = true;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.save(), 600);
  }

  async save() {
    clearTimeout(this.timer);
    this.timer = null;
    if (!this.dirty) return;
    if (this.isDraft && isEmptyNote(this.note)) return;
    this.dirty = false;
    const snapshot = clone(this.note);
    try {
      await api().SaveNote(snapshot);
      this.isDraft = false;
      this.lastSaved = snapshot;
    } catch (e) {
      this.dirty = true;
      toast('Could not save: ' + errText(e));
    }
  }

  // Takes a newer version from the store (labels renamed, sync) while nothing is pending here.
  external(note) {
    if (!note || this.dirty || this.timer || JSON.stringify(clone(note)) === JSON.stringify(this.lastSaved)) return;
    const focusInside = this.el.contains(document.activeElement);
    this.note = clone(note);
    this.lastSaved = clone(note);
    if (focusInside) {
      if (this.rich) this.rich.replace(note.body, note.spans);
      if (this.list) this.list.replace(note.items);
      applyColor(this.el, note.color);
      this.renderLabels();
      this.renderAttachments();
      this.rebuildBar();
    } else this.build();
  }

  async close() {
    document.removeEventListener('keydown', this.onKey);
    await this.save();
    this.rich?.destroy();
    this.el.remove();
    api().EditorClosed(this.note.id);
    this.app.editorClosed(this);
  }

  async move(folder) {
    this.update((x) => { x.folder = folder; x.modifiedTimestamp = Date.now(); });
    await this.close();
    if (folder === 'DELETED') toast('Note moved to the bin', { label: 'Undo', run: () => this.app.moveNote(this.note.id, 'NOTES') });
    if (folder === 'ARCHIVED') toast('Note archived', { label: 'Undo', run: () => this.app.moveNote(this.note.id, 'NOTES') });
  }

  async deleteForever() {
    if (!(await confirm('Delete forever?', 'The note is deleted on all your devices.', 'Delete'))) return;
    this.dirty = false;
    await api().DeleteForever(this.note.id);
    await this.close();
  }

  async duplicate() {
    await this.save();
    const copy = await api().Duplicate(this.note.id);
    await this.close();
    this.app.openNote(copy.id);
  }

  // Labels

  renderLabels() {
    this.labelChips.textContent = '';
    for (const l of this.note.labels) this.labelChips.appendChild(h('span', { class: 'chip' }, iconEl('tag'), l));
  }

  async editLabels() {
    const chosen = new Set(this.note.labels);
    const list = h('div');
    const draw = () => {
      list.textContent = '';
      const all = [...new Set([...this.app.labels.map((l) => l.value), ...chosen])];
      if (!all.length) list.appendChild(h('p', { class: 'muted', text: 'No labels yet.' }));
      for (const v of all) {
        const box = h('input', { type: 'checkbox', checked: chosen.has(v), onchange: () => (box.checked ? chosen.add(v) : chosen.delete(v)) });
        list.appendChild(h('label', { class: 'check-row' }, box, h('span', { text: v })));
      }
    };
    draw();
    const input = h('input', { class: 'input', placeholder: 'New label' });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && input.value.trim()) {
        e.preventDefault();
        e.stopPropagation();
        chosen.add(input.value.trim());
        input.value = '';
        draw();
      }
    });
    const ok = await dialog('Labels', h('div', {}, list, h('div', { class: 'field', style: 'margin-top:10px' }, input)),
      [{ label: 'Cancel', value: false }, { label: 'Done', value: true, primary: true }]);
    if (!ok) return;
    if (input.value.trim()) chosen.add(input.value.trim());
    const labels = [...chosen];
    if (labels.join('\n') === this.note.labels.join('\n')) return;
    this.update((x) => { x.labels = labels; });
    this.renderLabels();
  }

  // Color

  async editColor() {
    let value = this.note.color;
    const grid = h('div', { class: 'swatches' });
    const draw = () => {
      grid.textContent = '';
      for (const [name, hex] of PRESETS) {
        const sw = h('button', { class: 'swatch' + (hex === 'DEFAULT' ? ' default' : '') + (hex === value ? ' on' : ''), title: name,
          'aria-label': name, onclick: () => { value = hex; draw(); } });
        if (hex !== 'DEFAULT') sw.style.background = hex;
        grid.appendChild(sw);
      }
    };
    draw();
    const c = rgba(value);
    const custom = h('input', { type: 'color', value: c ? '#' + c.slice(0, 3).map((x) => x.toString(16).padStart(2, '0')).join('') : '#ffffff',
      oninput: () => { value = custom.value.toUpperCase(); draw(); } });
    const body = h('div', {}, grid, h('label', { class: 'check-row', style: 'margin-top:12px' }, custom, h('span', { text: 'Custom color' })));
    const ok = await dialog('Color', body, [{ label: 'Cancel', value: false }, { label: 'Done', value: true, primary: true }]);
    if (!ok || value === this.note.color) return;
    this.update((x) => { x.color = value; });
    applyColor(this.el, value);
  }

  // Reminders

  async editReminders() {
    const reminders = clone(this.note.reminders);
    const list = h('div');
    const draw = () => {
      list.textContent = '';
      if (!reminders.length) list.appendChild(h('p', { class: 'muted', text: 'No reminders.' }));
      reminders.forEach((r, i) => list.appendChild(h('div', { class: 'check-row' }, iconEl('bell'),
        h('span', { style: 'flex:1' }, fullDate(r.dateTime), r.repetition ? h('span', { class: 'muted', text: ' · ' + repetitionText(r.repetition) }) : null),
        iconButton('x', 'Remove reminder', () => { reminders.splice(i, 1); draw(); }))));
    };
    draw();
    const pad = (x) => String(x).padStart(2, '0');
    const d = new Date(Date.now() + 3600e3);
    const when = h('input', { class: 'input', type: 'datetime-local',
      value: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:00` });
    const repeat = h('select', { class: 'input' },
      [['', 'Does not repeat'], ['DAYS', 'Daily'], ['WEEKS', 'Weekly'], ['MONTHS', 'Monthly'], ['YEARS', 'Yearly'], ['custom', 'Custom…']]
        .map(([v, t]) => h('option', { value: v }, t)));
    const every = h('input', { class: 'input', type: 'number', min: 1, value: '1', style: 'width:90px' });
    const unit = h('select', { class: 'input' }, ['MINUTES', 'HOURS', 'DAYS', 'WEEKS', 'MONTHS', 'YEARS'].map((u) => h('option', { value: u }, u.toLowerCase())));
    unit.value = 'DAYS';
    const customRow = h('div', { class: 'check-row hidden' }, h('span', { text: 'Every' }), every, unit);
    repeat.addEventListener('change', () => customRow.classList.toggle('hidden', repeat.value !== 'custom'));
    const add = h('button', { class: 'btn', onclick: () => {
      const t = new Date(when.value).getTime();
      if (!t) return;
      const id = reminders.reduce((m, r) => Math.max(m, r.id), 0) + 1;
      const rep = repeat.value === 'custom' ? { value: Math.max(1, parseInt(every.value, 10) || 1), unit: unit.value }
        : repeat.value ? { value: 1, unit: repeat.value } : null;
      reminders.push(rep ? { id, dateTime: t, repetition: rep } : { id, dateTime: t });
      draw();
    } }, 'Add reminder');
    const body = h('div', {}, list, h('div', { class: 'field', style: 'margin-top:12px' }, h('label', { text: 'New reminder' }), when, repeat, customRow, add));
    const ok = await dialog('Reminders', body, [{ label: 'Cancel', value: false }, { label: 'Done', value: true, primary: true }]);
    if (!ok) return;
    this.update((x) => { x.reminders = reminders; });
    this.rebuildBar();
    if (!this.app.state.canNotify && reminders.length) toast('Reminders show while the app runs.');
  }

  // Attachments

  async addAttachments(kind) {
    try {
      const added = await api().AddAttachments(kind);
      if (!added?.length) return;
      this.update((x) => { if (kind === 'image') x.images.push(...added); else x.files.push(...added); });
      this.renderAttachments();
    } catch (e) {
      toast('Could not add: ' + errText(e));
    }
  }

  async removeAttachment(kind, name) {
    if (!(await confirm('Remove attachment?', null, 'Remove'))) return;
    this.update((x) => {
      if (kind === 'audios') x.audios = x.audios.filter((a) => a.name !== name);
      else x[kind] = x[kind].filter((f) => f.localName !== name);
    });
    this.renderAttachments();
  }

  renderAttachments() {
    const n = this.note, box = this.attachments;
    box.textContent = '';
    const edit = this.editable;
    if (n.images.length) {
      const grid = h('div', { class: 'images' });
      for (const img of n.images) {
        const el = h('img', { src: attURL(img.localName, img.mimeType), alt: img.originalName, loading: 'lazy',
          onclick: () => this.app.lightbox(attURL(img.localName, img.mimeType)) });
        el.addEventListener('error', () => el.replaceWith(h('div', { class: 'muted small', style: 'padding:12px', text: 'Not downloaded yet' })));
        const cell = h('div', { class: 'img', oncontextmenu: (e) => {
          e.preventDefault();
          menu(e.clientX, e.clientY, [
            { label: 'Open', icon: 'open', action: () => this.openFile(img) },
            { label: 'Save as…', icon: 'download', action: () => this.saveFile(img.localName, img.originalName) },
            edit && { label: 'Remove', icon: 'x', danger: true, action: () => this.removeAttachment('images', img.localName) },
          ]);
        } }, el, edit ? iconButton('x', 'Remove image', () => this.removeAttachment('images', img.localName)) : null);
        grid.appendChild(cell);
      }
      box.appendChild(grid);
    }
    for (const f of n.files) {
      box.appendChild(h('div', { class: 'file-row' }, iconEl('file'), h('span', { class: 'name', text: f.originalName, title: f.originalName }),
        iconButton('open', 'Open', () => this.openFile(f)),
        iconButton('download', 'Save as…', () => this.saveFile(f.localName, f.originalName)),
        edit ? iconButton('x', 'Remove file', () => this.removeAttachment('files', f.localName)) : null));
    }
    for (const a of n.audios) {
      const mime = { '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.ogg': 'audio/ogg', '.wav': 'audio/wav', '.3gp': 'audio/3gpp' }[a.name.slice(a.name.lastIndexOf('.')).toLowerCase()] || 'audio/mp4';
      const player = h('audio', { controls: true, preload: 'none', src: attURL(a.name, mime) });
      box.appendChild(h('div', { class: 'file-row' }, iconEl('wave'), player,
        h('span', { class: 'muted small', text: a.timestamp ? shortDate(a.timestamp) : '' }),
        iconButton('download', 'Save as…', () => this.saveFile(a.name, a.name)),
        edit ? iconButton('x', 'Remove recording', () => this.removeAttachment('audios', a.name)) : null));
    }
  }

  async openFile(f) {
    try { await api().OpenAttachment(f.localName, f.originalName); } catch (e) { toast(errText(e)); }
  }

  async saveFile(localName, name) {
    try { await api().SaveAttachment(localName, name); } catch (e) { toast(errText(e)); }
  }
}
