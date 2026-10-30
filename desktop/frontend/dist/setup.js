// First start: server address, then connect with a sync key or create an account.
import { dialog, h, segmented, toast, errText } from './ui.js';

const api = () => window.go.main.App;

export function showSetup(root, app, done) {
  let mode = 'connect';
  const server = h('input', { class: 'input', id: 'server', placeholder: 'https://notes.example.com', value: app.state.server || '',
    spellcheck: false, autofocus: true });
  const key = h('textarea', { class: 'input', id: 'key', placeholder: 'XXXX-XXXX-…', spellcheck: false, rows: 3 });
  const invite = h('input', { class: 'input', id: 'invite', type: 'password', placeholder: 'SIGNUP_TOKEN of the server' });
  const error = h('p', { class: 'error-text', role: 'alert' });
  const go = h('button', { class: 'btn primary', onclick: submit });
  const fields = h('div');
  const modes = h('div', { style: 'margin-bottom:16px' });

  function draw() {
    modes.textContent = '';
    modes.appendChild(segmented([['connect', 'Connect with sync key'], ['create', 'Create new account']], mode, (m) => { mode = m; draw(); }));
    fields.textContent = '';
    if (mode === 'connect') {
      fields.appendChild(h('div', { class: 'field' }, h('label', { for: 'key', text: 'Sync key' }), key,
        h('div', { class: 'muted small', text: 'From Settings → Sync on a device that is already connected.' })));
      go.textContent = 'Connect';
    } else {
      fields.appendChild(h('div', { class: 'field' }, h('label', { for: 'invite', text: 'Invite token' }), invite,
        h('div', { class: 'muted small', text: 'Creates a new, empty account. To use your existing notes, connect with your sync key instead.' })));
      go.textContent = 'Create account';
    }
    error.textContent = '';
  }

  async function submit() {
    if (go.disabled) return; // Enter can come again while a call runs.
    error.textContent = '';
    go.disabled = true;
    try {
      if (mode === 'connect') {
        await api().Connect(server.value, key.value);
      } else {
        const display = await api().CreateAccount(server.value, invite.value);
        await showNewKey(display);
      }
      await done();
    } catch (e) {
      error.textContent = errText(e);
    } finally {
      go.disabled = false;
    }
  }

  draw();
  root.appendChild(h('div', { class: 'setup' },
    h('div', { class: 'dialog' },
      h('div', { class: 'logo' }, h('img', { src: 'icon.png', alt: '' }), h('h2', { style: 'margin:0', text: 'NotallyXYZ' })),
      h('p', { class: 'muted', text: 'Notes with end-to-end encrypted sync to your own server. The server stores only ciphertext.' }),
      h('div', { class: 'field' }, h('label', { for: 'server', text: 'Server address' }), server),
      modes, fields, error,
      h('div', { class: 'buttons' }, go))));
  root.querySelector('.setup').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.tagName === 'INPUT') submit();
  });
  server.focus();
}

async function showNewKey(display) {
  await dialog('Save your sync key', h('div', {},
    h('p', { text: 'This key is the only way to read your notes and to connect other devices. Store it in your password manager now. It is shown only here and in Settings.' }),
    h('div', { class: 'key-box', text: display })),
  [{ label: 'Copy', keep: true, value: () => { window.runtime.ClipboardSetText(display); toast('Sync key copied'); } },
    { label: 'I saved it', value: true, primary: true }]);
}
