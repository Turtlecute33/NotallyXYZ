// List note editor: check, indent (Tab), reorder by drag, Enter for a new item.
import { iconEl } from './icons.js';
import * as ops from './listops.js';
import { h, iconButton, confirm } from './ui.js';

const autosize = (t) => { t.style.height = 'auto'; t.style.height = t.scrollHeight + 'px'; };

export class ListEditor {
  constructor({ items, editable, autoSort, onChange }) {
    // Display order: checked items at the bottom when sorted. Saved only after an edit.
    this.items = ops.normalized(items, autoSort).map((i) => ({ ...i, uid: ops.uid() }));
    this.editable = editable;
    this.autoSort = autoSort;
    this.onChange = onChange;
    this.el = h('div', { class: 'list-editor' });
    this.dragFrom = null;
    this.render();
  }

  // Items without the UI-only uid.
  value() { return this.items.map(({ uid, ...i }) => i); }

  replace(items) {
    this.items = ops.normalized(items, this.autoSort).map((i) => ({ ...i, uid: ops.uid() }));
    this.render();
  }

  changed(structure, focus) {
    if (structure) this.items = ops.normalized(this.items, this.autoSort).map((i, n) => ({ ...i, uid: i.uid || ops.uid() }));
    this.onChange(this.value());
    if (structure) this.render(focus);
  }

  render(focus) {
    const el = this.el;
    el.textContent = '';
    const firstChecked = this.autoSort ? this.items.findIndex((i) => !i.isChild && i.checked) : -1;
    this.items.forEach((item, index) => {
      if (index === firstChecked) {
        const n = this.items.length - firstChecked;
        el.appendChild(h('div', { class: 'checked-title', text: `${n} checked ${n === 1 ? 'item' : 'items'}` }));
      }
      el.appendChild(this.row(item, index));
    });
    if (this.editable) {
      const actions = h('div', { class: 'list-actions' },
        h('button', { class: 'text-btn', onclick: () => this.add() }, iconEl('plus'), 'List item'));
      if (this.items.some((i) => i.checked)) {
        actions.appendChild(h('button', { class: 'text-btn', onclick: () => this.deleteChecked() }, iconEl('trash'), 'Delete checked items'));
      }
      el.appendChild(actions);
    }
    if (focus) {
      const t = el.querySelector(`[data-uid="${focus.uid}"] textarea`);
      if (t) {
        t.focus();
        const pos = focus.pos === 'end' ? t.value.length : focus.pos ?? 0;
        t.setSelectionRange(pos, pos);
      }
    }
    requestAnimationFrame(() => el.querySelectorAll('textarea').forEach(autosize));
  }

  row(item, index) {
    const text = h('textarea', { rows: 1, value: item.body, readOnly: !this.editable, spellcheck: true, 'aria-label': 'List item' });
    text.value = item.body;
    text.addEventListener('input', () => {
      this.items[index] = { ...this.items[index], body: text.value.replace(/\n/g, ' ') };
      autosize(text);
      this.changed(false);
    });
    text.addEventListener('keydown', (e) => this.key(e, index, text));
    text.addEventListener('paste', (e) => this.paste(e, index, text));
    const check = h('button', { class: 'check', title: item.checked ? 'Uncheck' : 'Check', disabled: !this.editable,
      onclick: () => {
        ops.setChecked(this.items, index, !item.checked);
        this.changed(true);
      } }, iconEl(item.checked ? 'boxChecked' : 'box'));
    const row = h('div', { class: 'li' + (item.isChild ? ' child' : '') + (item.checked ? ' checked' : ''), 'data-uid': item.uid },
      this.editable ? h('span', { class: 'grip', title: 'Drag to move' }, iconEl('grip')) : null,
      check, text,
      this.editable ? iconButton('x', 'Delete item', () => { ops.remove(this.items, index); this.changed(true); }, { class: 'del' }) : null);
    if (this.editable) {
      const grip = row.querySelector('.grip');
      grip.draggable = true;
      grip.addEventListener('dragstart', (e) => {
        this.dragFrom = index;
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', '');
        e.dataTransfer.setDragImage(row, 10, 10);
      });
      row.addEventListener('dragover', (e) => {
        if (this.dragFrom == null) return;
        e.preventDefault();
        row.classList.add('drag-over');
      });
      row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
      row.addEventListener('drop', (e) => {
        e.preventDefault();
        row.classList.remove('drag-over');
        if (this.dragFrom == null || this.dragFrom === index) return;
        this.items = ops.move(this.items, this.dragFrom, index);
        this.dragFrom = null;
        this.changed(true);
      });
      grip.addEventListener('dragend', () => { this.dragFrom = null; });
    }
    return row;
  }

  key(e, index, text) {
    if (!this.editable) return;
    const item = this.items[index];
    const atStart = text.selectionStart === 0 && text.selectionEnd === 0;
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      // The text after the caret moves into the new item.
      const before = text.value.slice(0, text.selectionStart), after = text.value.slice(text.selectionEnd);
      this.items[index] = { ...item, body: before };
      const pos = ops.insert(this.items, index, after);
      this.changed(true, { uid: this.items[pos].uid, pos: 0 });
    } else if (e.key === 'Backspace' && atStart && item.body === '') {
      e.preventDefault();
      const prev = this.items[index - 1];
      ops.remove(this.items, index);
      this.changed(true, prev ? { uid: prev.uid, pos: 'end' } : null);
    } else if (e.key === 'Tab') {
      e.preventDefault();
      this.items = ops.setChild(this.items, index, !e.shiftKey);
      this.changed(true, { uid: item.uid, pos: text.selectionStart });
    } else if ((e.key === 'ArrowUp' && text.selectionStart === 0) || (e.key === 'ArrowDown' && text.selectionEnd === text.value.length)) {
      const next = this.items[index + (e.key === 'ArrowUp' ? -1 : 1)];
      if (next) {
        e.preventDefault();
        this.render({ uid: next.uid, pos: e.key === 'ArrowUp' ? 'end' : 0 });
      }
    }
  }

  // Pasting several lines makes several items.
  paste(e, index, text) {
    const data = (e.clipboardData?.getData('text/plain') || '').replace(/\r\n?/g, '\n');
    if (!data.includes('\n') || !this.editable) return;
    e.preventDefault();
    const lines = data.split('\n').map((l) => l.replace(/^\s*([-*•]|\[[ xX]\])\s+/, '')).filter((l) => l.trim() !== '');
    if (!lines.length) return;
    const before = text.value.slice(0, text.selectionStart), after = text.value.slice(text.selectionEnd);
    this.items[index] = { ...this.items[index], body: before + lines[0] };
    let at = index;
    for (const line of lines.slice(1)) at = ops.insert(this.items, at, line);
    this.items[at] = { ...this.items[at], body: this.items[at].body + after };
    this.changed(true, { uid: this.items[at].uid, pos: 'end' });
  }

  add() {
    // New items go above the checked ones when they are sorted to the bottom.
    let after = this.items.length - 1;
    if (this.autoSort) {
      const firstChecked = this.items.findIndex((i) => !i.isChild && i.checked);
      if (firstChecked >= 0) after = firstChecked - 1;
    }
    const item = ops.newItem('', false);
    this.items.splice(after + 1, 0, item);
    this.changed(true, { uid: item.uid, pos: 0 });
  }

  async deleteChecked() {
    if (!(await confirm('Delete checked items?', null, 'Delete'))) return;
    this.items = ops.deleteChecked(this.items);
    this.changed(true);
  }
}
