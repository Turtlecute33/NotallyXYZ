// Settings: sync, appearance (same set as the macOS app), lists, danger zone.
import { confirm, dialog, h, iconButton, segmented, toast, toggle, errText } from './ui.js';

const api = () => window.go.main.App;

export function showSettings(main, app, onClose) {
  main.querySelector('.settings')?.remove();
  const page = h('div', { class: 'settings-page' });
  const el = h('div', { class: 'settings', role: 'region', 'aria-label': 'Settings' },
    h('div', { class: 'editor-bar' }, iconButton('back', 'Back', close), h('h1', { style: 'font-size:20px;margin:0 8px', text: 'Settings' })),
    page);
  const onKey = (e) => { if (e.key === 'Escape' && !document.querySelector('.scrim, .menu')) close(); };
  document.addEventListener('keydown', onKey);
  function close() {
    document.removeEventListener('keydown', onKey);
    el.remove();
    onClose();
  }
  main.appendChild(el);

  const row = (label, hint, control, disabled = false) =>
    h('div', { class: 'row' + (disabled ? ' disabled' : '') },
      h('div', { class: 'label' }, h('div', { text: label }), hint ? h('div', { class: 'muted', text: hint }) : null), control);
  const set = async (patch) => { await app.setSettings(patch); draw(); };
  const number = (value, key, disabled) => {
    const sel = h('select', { class: 'input', disabled, onchange: () => set({ [key]: parseInt(sel.value, 10) }) },
      Array.from({ length: 10 }, (_, i) => h('option', { value: String(i + 1) }, String(i + 1))));
    sel.value = String(value);
    return sel;
  };

  function draw() {
    const s = app.settings, st = app.state;
    page.textContent = '';
    page.append(
      h('div', { class: 'group-title', text: 'Sync' }),
      h('div', { class: 'group' },
        row('Server', null, h('span', { class: 'muted', text: st.server })),
        row('Sync key', st.keyInFile ? 'Stored in a file that only you can read: no system key store was found.' : 'Stored in the system key store.',
          h('button', { class: 'btn', onclick: showKey }, 'Show…')),
        row('Sync now', null, h('button', { class: 'btn', onclick: () => api().SyncNow() }, 'Sync')),
        row('Clean up server', 'Remove attachments that no note uses from the server (older than 24 hours).',
          h('button', { class: 'btn', onclick: cleanUp }, 'Clean up'))),

      h('div', { class: 'group-title', text: 'Appearance' }),
      h('div', { class: 'group' },
        row('Theme', null, segmented([['system', 'System'], ['light', 'Light'], ['dark', 'Dark']], s.theme, (v) => set({ theme: v }))),
        row('Text size', null, (() => {
          const sel = h('select', { class: 'input', onchange: () => set({ textSize: sel.value }) },
            [['small', 'Small'], ['default', 'Default'], ['large', 'Large'], ['extraLarge', 'Extra large']].map(([v, t]) => h('option', { value: v }, t)));
          sel.value = s.textSize;
          return sel;
        })())),

      h('div', { class: 'group-title', text: 'Notes overview' }),
      h('div', { class: 'group' },
        row('Layout', null, segmented([['grid', 'Grid'], ['list', 'List']], s.layout, (v) => set({ layout: v }))),
        row('Show note preview', 'Without a preview, a card shows the title, labels and images. A note without a title shows its first line.',
          toggle(s.showPreview, (v) => set({ showPreview: v }))),
        row('Lines of text in preview', null, number(s.previewLines, 'previewLines', !s.showPreview), !s.showPreview),
        row('Items of lists in preview', null, number(s.previewItems, 'previewItems', !s.showPreview), !s.showPreview),
        row('Show labels on cards', null, toggle(s.showLabels, (v) => set({ showLabels: v }))),
        row('Show images on cards', null, toggle(s.showImages, (v) => set({ showImages: v }))),
        row('Show date on cards', null, toggle(s.showDate, (v) => set({ showDate: v })))),

      h('div', { class: 'group-title', text: 'Lists' }),
      h('div', { class: 'group' },
        row('Move checked items to the bottom', null, toggle(s.autoSortChecked, (v) => set({ autoSortChecked: v })))),

      h('div', { class: 'group-title', text: 'Danger zone' }),
      h('div', { class: 'group' },
        row('Disconnect this device', 'Removes the sync key and the local cache. Notes stay on the server.',
          h('button', { class: 'btn', onclick: disconnect }, 'Disconnect…')),
        row('Delete all data on the server', 'Removes all notes and attachments from the server, for every device.',
          h('button', { class: 'btn danger', onclick: deleteAll }, 'Delete…'))),
      h('p', { class: 'muted small', style: 'margin:18px 6px' },
        `NotallyXYZ ${st.version} · Data: ${st.dataFolder}. Notes are encrypted on this device before they go to the server.`),
    );
  }

  async function showKey() {
    const key = await api().SyncKey();
    await dialog('Sync key', h('div', {},
      h('div', { class: 'key-box', text: key }),
      h('p', { class: 'muted small', style: 'margin-top:10px', text: 'Anyone with this key can read your notes. Use it only to connect your own devices.' })),
    [{ label: 'Copy', keep: true, value: () => { window.runtime.ClipboardSetText(key); toast('Sync key copied'); } }, { label: 'Done', value: true, primary: true }]);
  }

  async function cleanUp() {
    try {
      const n = await api().CleanUpServer();
      toast(n ? `Removed ${n} unused ${n === 1 ? 'attachment' : 'attachments'}.` : 'Nothing to remove.');
    } catch (e) { toast(errText(e)); }
  }

  async function disconnect() {
    if (!(await confirm('Disconnect this device?', 'The sync key and the local cache are removed from this device. Your notes stay on the server and on your other devices. Keep your sync key to connect again.', 'Disconnect'))) return;
    await api().Disconnect();
    close();
    await app.refresh();
  }

  async function deleteAll() {
    if (!(await confirm('Delete all data on the server?', 'All notes and attachments are removed from the server. Other devices keep their local copy, but stop syncing. This cannot be undone.', 'Delete everything'))) return;
    try {
      await api().DeleteServerData();
      close();
      await app.refresh();
    } catch (e) { toast(errText(e)); }
  }

  draw();
}
