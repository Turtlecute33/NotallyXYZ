// Small DOM helpers. Note content is always set as text, never parsed as HTML.
import { iconEl } from './icons.js';

export function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'style') el.setAttribute('style', v);
    else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k in el && typeof v !== 'string') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return el;
}

export function iconButton(name, title, onClick, extra = {}) {
  const b = h('button', { class: 'icon-btn ' + (extra.class || ''), title, 'aria-label': title, onclick: onClick, ...extra.attrs });
  b.appendChild(iconEl(name));
  return b;
}

const overlays = () => document.getElementById('overlays');

// Modal dialog. buttons: [{label, value, primary, danger}]. Resolves with the value (null on Escape).
export function dialog(title, body, buttons, opts = {}) {
  return new Promise((resolve) => {
    const prevFocus = document.activeElement;
    let scrim;
    const close = (v) => {
      scrim.remove();
      document.removeEventListener('keydown', onKey, true);
      prevFocus?.focus?.();
      resolve(v);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') { e.stopPropagation(); e.preventDefault(); close(null); }
      if (e.key === 'Enter' && opts.enter !== undefined && e.target.tagName !== 'TEXTAREA') {
        e.preventDefault();
        close(typeof opts.enter === 'function' ? opts.enter() : opts.enter);
      }
    };
    const btns = buttons.map((b) =>
      h('button', { class: 'btn' + (b.primary ? ' primary' : '') + (b.danger ? ' danger' : ''),
        onclick: () => (b.keep ? b.value() : close(typeof b.value === 'function' ? b.value() : b.value)) }, b.label));
    const box = h('div', { class: 'dialog', role: 'dialog', 'aria-modal': 'true' },
      title ? h('h2', { text: title }) : null, body, btns.length ? h('div', { class: 'buttons' }, btns) : null);
    scrim = h('div', { class: 'scrim', onmousedown: (e) => { if (e.target === scrim) close(null); } }, box);
    overlays().appendChild(scrim);
    document.addEventListener('keydown', onKey, true);
    (box.querySelector('[autofocus]') || box.querySelector('input, textarea, select') || btns[buttons.at(-1)?.danger ? 0 : btns.length - 1])?.focus();
  });
}

export async function confirm(title, text, action) {
  return (await dialog(title, text ? h('p', { text }) : null,
    [{ label: 'Cancel', value: false }, { label: action, value: true, danger: true }])) === true;
}

export async function prompt(title, value = '', placeholder = '', action = 'OK') {
  const input = h('input', { class: 'input', value, placeholder, autofocus: true });
  const r = await dialog(title, input, [{ label: 'Cancel', value: null }, { label: action, value: () => input.value, primary: true }],
    { enter: () => input.value });
  return r;
}

let openMenu = null;

// Context menu at a point. items: [{label, icon, action, danger}] or 'sep'.
export function menu(x, y, items) {
  closeMenu();
  const el = h('div', { class: 'menu', role: 'menu' },
    items.filter(Boolean).map((it) => it === 'sep' ? h('hr') :
      h('button', { class: it.danger ? 'danger' : '', role: 'menuitem', onclick: () => { closeMenu(); it.action(); } },
        it.icon ? iconEl(it.icon) : null, it.label)));
  overlays().appendChild(el);
  const r = el.getBoundingClientRect();
  el.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  el.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  const away = (e) => { if (!el.contains(e.target)) closeMenu(); };
  const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); closeMenu(); } };
  setTimeout(() => {
    document.addEventListener('mousedown', away, true);
    document.addEventListener('keydown', key, true);
  });
  openMenu = { el, away, key };
  el.querySelector('button')?.focus();
}

export function closeMenu() {
  if (!openMenu) return;
  openMenu.el.remove();
  document.removeEventListener('mousedown', openMenu.away, true);
  document.removeEventListener('keydown', openMenu.key, true);
  openMenu = null;
}

let toastBox = null;

export function toast(text, action, ms = 5000) {
  if (!toastBox) {
    toastBox = h('div', { class: 'toasts', role: 'status' });
    document.body.appendChild(toastBox);
  }
  const t = h('div', { class: 'toast' }, h('span', { text }),
    action ? h('button', { onclick: () => { t.remove(); action.run(); } }, action.label) : null);
  toastBox.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

export function toggle(checked, onChange) {
  const input = h('input', { type: 'checkbox', checked, onchange: () => onChange(input.checked) });
  return h('label', { class: 'switch' }, input, h('span'));
}

export function segmented(options, value, onChange) {
  const el = h('div', { class: 'segmented', role: 'radiogroup' });
  for (const [v, label] of options) {
    el.appendChild(h('button', { class: v === value ? 'on' : '', role: 'radio', 'aria-checked': String(v === value),
      onclick: () => onChange(v) }, label));
  }
  return el;
}

// Formatting

const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

export function ago(ms) {
  const s = (ms - Date.now()) / 1000;
  const abs = Math.abs(s);
  const [v, unit] = abs < 60 ? [s, 'second'] : abs < 3600 ? [s / 60, 'minute'] : abs < 86400 ? [s / 3600, 'hour'] :
    abs < 86400 * 30 ? [s / 86400, 'day'] : abs < 86400 * 365 ? [s / 86400 / 30, 'month'] : [s / 86400 / 365, 'year'];
  return abs < 45 ? 'just now' : rtf.format(Math.round(v), unit);
}

export const fullDate = (ms) => new Date(ms).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
export const shortDate = (ms) => new Date(ms).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' });

// Note colors: the 12 NotallyX presets.
export const PRESETS = [
  ['Default', 'DEFAULT'], ['Coral', '#FAAFA9'], ['Orange', '#FFCC80'], ['Sand', '#FFF8B9'], ['Storm', '#AFCCDC'],
  ['Fog', '#D3E4EC'], ['Sage', '#B4DED4'], ['Mint', '#E2F6D3'], ['Dusk', '#D3BFDB'], ['Flower', '#F8BBD0'],
  ['Blossom', '#F5E2DC'], ['Clay', '#E9E3D3'],
];

export function rgba(value) {
  if (!value || value[0] !== '#') return null;
  const hex = value.slice(1);
  if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(hex)) return null;
  const n = parseInt(hex, 16);
  if (hex.length === 6) return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1];
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255, ((n >>> 24) & 255) / 255];
}

// Relative luminance > 0.5 means dark text, like isLightColor() on Android.
export function isLight(value) {
  const c = rgba(value);
  if (!c) return true;
  const lin = (x) => { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); };
  return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]) > 0.5;
}

export function applyColor(el, value) {
  const c = rgba(value);
  el.classList.toggle('colored', !!c);
  el.classList.toggle('light-color', !!c && isLight(value));
  el.classList.toggle('dark-color', !!c && !isLight(value));
  el.style.background = c ? `rgba(${c[0]},${c[1]},${c[2]},${c[3]})` : '';
}

// Error text of a rejected call into Go (a string in production, an Error in dev mode).
export const errText = (e) => (typeof e === 'string' ? e : e?.message ?? String(e)).replace(/^Error: /, '');
