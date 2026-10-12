// Rich text in NotallyX form: plain text plus spans with UTF-16 offsets (same as Java strings).
// The editor keeps one mark set per character; the DOM is only a view of that model.

export const B = 1, I = 2, M = 4, S = 8, L = 16;

export function marksFromSpans(text, spans) {
  const n = text.length;
  const marks = new Array(n).fill(0);
  const links = new Array(n).fill(undefined);
  for (const s of spans || []) {
    const a = Math.max(0, Math.min(n, s.start | 0)), b = Math.max(0, Math.min(n, s.end | 0));
    const m = (s.bold ? B : 0) | (s.italic ? I : 0) | (s.monospace ? M : 0) | (s.strikethrough ? S : 0) | (s.link ? L : 0);
    for (let i = a; i < b; i++) {
      marks[i] |= m;
      if (s.link) links[i] = s.linkData ?? null;
    }
  }
  return { marks, links };
}

export function spansFrom(text, marks, links) {
  const out = [];
  for (let i = 0; i < text.length;) {
    const m = marks[i], l = m & L ? links[i] ?? null : undefined;
    let j = i + 1;
    while (j < text.length && marks[j] === m && (!(m & L) || (links[j] ?? null) === l)) j++;
    if (m) {
      const s = { start: i, end: j, bold: !!(m & B), italic: !!(m & I), monospace: !!(m & M),
        strikethrough: !!(m & S), link: !!(m & L) };
      if (m & L && l != null) s.linkData = l;
      out.push(s);
    }
    i = j;
  }
  return out;
}

const classes = (m) => [m & B && 'sb', m & I && 'si', m & M && 'sm', m & S && 'ss', m & L && 'sl'].filter(Boolean).join(' ');

// Appends text with formatting to `parent`. Text goes in as text nodes, never as markup.
export function renderRuns(parent, text, marks, links) {
  for (let i = 0; i < text.length;) {
    const m = marks[i], l = m & L ? links[i] ?? null : undefined;
    let j = i + 1;
    while (j < text.length && marks[j] === m && (!(m & L) || (links[j] ?? null) === l)) j++;
    const part = text.slice(i, j);
    if (!m) parent.appendChild(document.createTextNode(part));
    else {
      const span = document.createElement('span');
      span.className = classes(m);
      if (m & L) span.dataset.link = l ?? part;
      span.textContent = part;
      parent.appendChild(span);
    }
    i = j;
  }
}

export function renderSpans(parent, text, spans) {
  const { marks, links } = marksFromSpans(text, spans);
  renderRuns(parent, text, marks, links);
}

// Text offset of a DOM position inside root. <br> counts as "\n" (the end sentinel as nothing).
function textOffset(root, node, offset) {
  let count = 0;
  let found = null;
  const walk = (n) => {
    if (n.nodeType === Node.TEXT_NODE) {
      if (n === node) found = count + Math.min(offset, n.data.length);
      else count += n.data.length;
      return;
    }
    if (n.nodeName === 'BR') {
      if (n === node) found = count;
      else if (!n.dataset.end) count += 1;
      return;
    }
    const kids = n.childNodes;
    for (let i = 0; i < kids.length && found === null; i++) {
      if (n === node && i === offset) { found = count; return; }
      walk(kids[i]);
    }
    if (n === node && found === null) found = count;
  };
  walk(root);
  return found ?? count;
}

function pointAt(root, offset) {
  let left = offset;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (n.nodeType === Node.TEXT_NODE) {
      if (left <= n.data.length) return [n, left];
      left -= n.data.length;
    } else if (n.nodeName === 'BR' && !n.dataset.end) {
      const index = Array.prototype.indexOf.call(n.parentNode.childNodes, n);
      if (left === 0) return [n.parentNode, index];
      left -= 1;
    }
  }
  const end = root.querySelector('br[data-end]');
  return end ? [root, Array.prototype.indexOf.call(root.childNodes, end)] : [root, root.childNodes.length];
}

export class RichText {
  constructor({ text, spans, editable, placeholder, onChange, onOpenLink }) {
    this.text = text || '';
    const { marks, links } = marksFromSpans(this.text, spans);
    this.marks = marks;
    this.links = links;
    this.originalSpans = spans || [];
    this.edited = false;
    this.onChange = onChange;
    this.onOpenLink = onOpenLink;
    this.history = [];
    this.future = [];
    this.lastPush = 0;
    this.composing = false;
    this.lastSel = null;

    const el = (this.el = document.createElement('div'));
    el.className = 'rich';
    el.dataset.placeholder = placeholder || '';
    el.spellcheck = true;
    this.setEditable(editable);
    el.addEventListener('beforeinput', (e) => this.beforeInput(e));
    el.addEventListener('input', () => this.onInput());
    el.addEventListener('keydown', (e) => this.keydown(e));
    el.addEventListener('paste', (e) => this.paste(e));
    el.addEventListener('drop', (e) => e.preventDefault());
    el.addEventListener('compositionstart', () => { this.composing = true; });
    el.addEventListener('compositionend', () => { this.composing = false; this.onInput(); });
    el.addEventListener('click', (e) => this.click(e));
    this.onSelection = () => {
      const s = this.getSel();
      if (s) this.lastSel = s;
    };
    document.addEventListener('selectionchange', this.onSelection);
    this.render();
  }

  destroy() { document.removeEventListener('selectionchange', this.onSelection); }

  setEditable(editable) {
    this.editable = editable;
    try {
      this.el.contentEditable = editable ? 'plaintext-only' : 'false';
    } catch {
      this.el.contentEditable = editable ? 'true' : 'false';
    }
    this.el.classList.toggle('readonly', !editable);
  }

  spans() { return this.edited ? spansFrom(this.text, this.marks, this.links) : this.originalSpans; }

  render(sel) {
    const el = this.el;
    el.textContent = '';
    renderRuns(el, this.text, this.marks, this.links);
    // Without it, the caret cannot reach an empty last line.
    if (this.text.endsWith('\n')) {
      const br = document.createElement('br');
      br.dataset.end = '1';
      el.appendChild(br);
    }
    if (sel) this.setSel(sel);
  }

  readText() {
    const out = [];
    const read = (node) => {
      for (const c of node.childNodes) {
        if (c.nodeType === Node.TEXT_NODE) out.push(c.data);
        else if (c.nodeName === 'BR') { if (!c.dataset.end) out.push('\n'); }
        else if (c.nodeType === Node.ELEMENT_NODE) {
          if ((c.nodeName === 'DIV' || c.nodeName === 'P') && out.length && !out[out.length - 1].endsWith('\n')) out.push('\n');
          read(c);
        }
      }
    };
    read(this.el);
    return out.join('').replace(/\r\n?/g, '\n');
  }

  getSel() {
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount) return null;
    const r = sel.getRangeAt(0);
    if (!this.el.contains(r.startContainer) || !this.el.contains(r.endContainer)) return null;
    return { start: textOffset(this.el, r.startContainer, r.startOffset), end: textOffset(this.el, r.endContainer, r.endOffset) };
  }

  setSel({ start, end }) {
    const sel = window.getSelection();
    const r = document.createRange();
    const [sn, so] = pointAt(this.el, Math.min(start, this.text.length));
    const [en, eo] = pointAt(this.el, Math.min(end, this.text.length));
    r.setStart(sn, so);
    r.setEnd(en, eo);
    sel.removeAllRanges();
    sel.addRange(r);
  }

  snapshot(sel) { return { text: this.text, marks: this.marks.slice(), links: this.links.slice(), sel }; }

  // Typing within 0.8 s is one undo step; any other change is a step of its own.
  push(typing) {
    const t = Date.now();
    const merge = typing && this.lastTyping && t - this.lastPush < 800 && this.history.length;
    this.lastPush = t;
    this.lastTyping = typing;
    if (merge) return;
    this.history.push(this.snapshot(this.lastSel));
    if (this.history.length > 200) this.history.shift();
    this.future = [];
  }

  restore(from, to) {
    const s = from.pop();
    if (!s) return;
    to.push(this.snapshot(this.getSel()));
    this.text = s.text;
    this.marks = s.marks;
    this.links = s.links;
    this.edited = true;
    this.render(s.sel || { start: this.text.length, end: this.text.length });
    this.changed();
  }

  // Replaces text[start, end) with str. New characters take the marks of the character before
  // (or after, at a line start); a link continues only inside a link.
  splice(start, end, str) {
    const O = this.text;
    let m = 0, l;
    if (start > 0 && O[start - 1] !== '\n') { m = this.marks[start - 1]; l = this.links[start - 1]; }
    else if (end < O.length) { m = this.marks[end]; l = this.links[end]; }
    if (m & L) {
      const inside = start > 0 && end < O.length && this.marks[start - 1] & L && this.marks[end] & L && this.links[start - 1] === this.links[end];
      if (!inside) { m &= ~L; l = undefined; }
    }
    this.text = O.slice(0, start) + str + O.slice(end);
    this.marks.splice(start, end - start, ...new Array(str.length).fill(m));
    this.links.splice(start, end - start, ...new Array(str.length).fill(m & L ? l : undefined));
    this.edited = true;
  }

  replaceSelection(str) {
    const sel = this.getSel() || { start: this.text.length, end: this.text.length };
    this.push(false);
    this.splice(sel.start, sel.end, str);
    const caret = sel.start + str.length;
    this.render({ start: caret, end: caret });
    this.changed();
  }

  onInput() {
    if (this.composing) return;
    const N = this.readText();
    const O = this.text;
    if (N === O) return;
    const sel = this.getSel();
    let p = 0;
    const max = Math.min(O.length, N.length);
    while (p < max && O[p] === N[p]) p++;
    let s = 0;
    while (s < max - p && O[O.length - 1 - s] === N[N.length - 1 - s]) s++;
    this.push(true);
    this.splice(p, O.length - s, N.slice(p, N.length - s));
    this.render(sel);
    this.changed();
  }

  beforeInput(e) {
    if (!this.editable) return;
    const t = e.inputType;
    if (t === 'insertParagraph' || t === 'insertLineBreak') {
      e.preventDefault();
      this.replaceSelection('\n');
    } else if (t.startsWith('format') || t === 'insertFromDrop') {
      e.preventDefault();
    } else if (t === 'historyUndo') {
      e.preventDefault();
      this.undo();
    } else if (t === 'historyRedo') {
      e.preventDefault();
      this.redo();
    }
  }

  keydown(e) {
    const mod = e.ctrlKey || e.metaKey;
    if (!mod || !this.editable) return;
    const k = e.key.toLowerCase();
    const act = {
      b: () => this.toggle(B), i: () => this.toggle(I), z: () => (e.shiftKey ? this.redo() : this.undo()), y: () => this.redo(),
    }[k];
    if (act) {
      e.preventDefault();
      act();
    }
  }

  paste(e) {
    e.preventDefault();
    if (!this.editable) return;
    const text = (e.clipboardData?.getData('text/plain') || '').replace(/\r\n?/g, '\n');
    if (text) this.replaceSelection(text);
  }

  click(e) {
    const span = e.target.closest?.('.sl');
    if (!span || !this.el.contains(span)) return;
    if (!this.editable || e.ctrlKey || e.metaKey) {
      e.preventDefault();
      this.onOpenLink?.(span.dataset.link);
    }
  }

  undo() { this.restore(this.history, this.future); }
  redo() { this.restore(this.future, this.history); }

  range() {
    const sel = this.getSel() || this.lastSel;
    return sel && sel.start !== sel.end ? { start: Math.min(sel.start, sel.end), end: Math.max(sel.start, sel.end) } : null;
  }

  isActive(bit) {
    const r = this.range();
    if (!r) return false;
    for (let i = r.start; i < r.end; i++) if (!(this.marks[i] & bit)) return false;
    return true;
  }

  apply(fn) {
    const r = this.range();
    if (!r) return;
    this.push(false);
    for (let i = r.start; i < r.end; i++) fn(i);
    this.edited = true;
    this.render(r);
    this.changed();
  }

  toggle(bit) {
    const on = !this.isActive(bit);
    this.apply((i) => {
      this.marks[i] = on ? this.marks[i] | bit : this.marks[i] & ~bit;
      if (bit === L && !on) this.links[i] = undefined;
    });
  }

  setLink(url) {
    this.apply((i) => {
      if (url) { this.marks[i] |= L; this.links[i] = url; }
      else { this.marks[i] &= ~L; this.links[i] = undefined; }
    });
  }

  clearFormat() {
    this.apply((i) => { this.marks[i] = 0; this.links[i] = undefined; });
  }

  selectedLink() {
    const r = this.range() || this.lastSel;
    if (!r) return '';
    const i = Math.min(r.start, this.text.length - 1);
    return i >= 0 && this.marks[i] & L ? this.links[i] ?? '' : '';
  }

  changed() { this.onChange?.(this.text, this.spans()); }

  // External update (remote change) while nothing is pending locally.
  replace(text, spans) {
    this.text = text || '';
    const { marks, links } = marksFromSpans(this.text, spans);
    this.marks = marks;
    this.links = links;
    this.originalSpans = spans || [];
    this.edited = false;
    this.history = [];
    this.future = [];
    this.render();
  }
}
