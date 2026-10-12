# NotallyXYZ for Linux and Windows

Desktop client for NotallyXYZ: the NotallyX notes app with end-to-end encrypted sync to your
own server. Go and [Wails](https://wails.io) (system web view), no telemetry, no web fonts,
no network calls except to your server.

The sync protocol is in [`PROTOCOL.md`](../server/PROTOCOL.md) of the server. The client code
follows the macOS app rule for rule; the crypto is the Go reference implementation of the
server (`server/seal`).

## Features

- Text notes with bold, italic, monospace, strikethrough and links (incl. links to other notes)
- Lists with subtasks (Tab, Shift+Tab), drag to reorder, checked items at the bottom, delete checked
- Colors (12 NotallyX presets and custom), labels, pin, archive, bin, duplicate, search, sort
- Images, files and audio playback; add images and files from disk
- Reminders with repetition, as system notifications while the app runs
- Live sync (long poll), conflict-free field merge with the Android and macOS apps
- Appearance settings: theme, text size, grid or list, note preview on or off, preview length,
  labels, images and dates on cards

## Install

From the GitHub release:

- **Windows 10 and 11 (x64):** `NotallyXYZ-windows-x64-<version>.exe`. It is a portable app: put it
  where you like and start it. It needs the Microsoft Edge WebView2 runtime (part of Windows 11
  and of current Windows 10; the app offers to install it if it is missing). The file has no
  code signature, so SmartScreen warns on the first start: More info → Run anyway.
- **Debian, Ubuntu (22.04 or later) and derivatives:** `sudo apt install ./notallyxyz_<version>_amd64.deb`
  (or `_arm64.deb`).
- **Other Linux distributions:** `NotallyXYZ-linux-<arch>-<version>.tar.gz` contains the binary,
  a `.desktop` file and the icon. It needs GTK 3 and WebKitGTK 4.1 (`webkit2gtk-4.1` on Fedora
  and Arch).

Check a download: `sha256sum -c SHA256SUMS --ignore-missing`, and that GitHub Actions built it:
`gh attestation verify <file> -R Turtlecute33/NotallyXYZ`.

On first start, enter your server address, then either paste the sync key from another device
or create an account with the server's invite token (`SIGNUP_TOKEN`). A new key is shown once:
store it in a password manager.

## Security and privacy

- The sync key is kept in the system key store (Secret Service such as GNOME Keyring or KWallet on
  Linux, Credential Manager on Windows). Without a key store, it goes into a file that only your
  user can read; Settings shows which one is used.
- Notes are encrypted with AES-256-GCM before they leave the computer; the server sees only random
  ids and padded ciphertext. The local cache keeps the records and attachments exactly as sealed on
  the server; notes are decrypted only in memory.
- A deletion counts only if its sealed tombstone opens. A deletion that the server or someone with
  the access token made up is ignored, and the note is written to the server again.
- Images and audio go to the web view from memory, with `Cache-Control: no-store`. Opening a file in
  another app writes a plaintext copy to a private temporary folder that is removed on quit.
  Files that could run code (`.exe`, `.sh`, `.desktop`, …) can only be saved, not opened.
- HTTPS only (plain HTTP is accepted for `localhost` for testing). No redirects, no cookies.
- Data: `~/.local/share/NotallyXYZ` and `~/.config/NotallyXYZ` on Linux,
  `%LOCALAPPDATA%\NotallyXYZ` and `%APPDATA%\NotallyXYZ` on Windows. `NOTALLYXYZ_HOME=<folder>`
  puts all data, and the key, into one folder (portable use).

## Build

Needs Go. On Linux also GTK 3 and WebKitGTK 4.1 headers (`libgtk-3-dev libwebkit2gtk-4.1-dev`).

```zsh
WAILS=github.com/wailsapp/wails/v2/cmd/wails@v2.16.0
go run $WAILS build -tags webkit2_41 -skipbindings -o notallyxyz   # Linux
go run $WAILS build -platform windows/amd64 -skipbindings           # Windows (also from Linux or macOS)
```

The binary is in `build/bin`. Releases are built by [GitHub Actions](../.github/workflows/desktop.yml)
when a `v*` tag is pushed.

## Tests

```zsh
go test -race ./core/
```

The tests check the keys against `testvectors.json`, the note payloads, the merge and the
reminder rules, and run sync end to end against the real server (built from `../server`):
notes, labels, blobs, conflicts, deletions, forged deletions, notes open in an editor,
first-pull linking.

## Known limitations

- No audio recording (playback only).
- Reminders notify only while the app runs.
- Unknown JSON fields are kept at the top level of a note only, not inside items or spans.

## License

GPL-3.0, like NotallyX, whose design and icon this app uses. See [`LICENSE.md`](../LICENSE.md).
