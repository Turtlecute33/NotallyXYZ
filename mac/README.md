# NotallyXYZ for macOS

Native macOS client for NotallyXYZ: the NotallyX notes app with end-to-end encrypted sync to
your own server. SwiftUI with Liquid Glass, no third-party dependencies, 1.4 MB app.

The sync protocol is in [`PROTOCOL.md`](../server/PROTOCOL.md) of the server.

## Features

- Text notes with bold, italic, monospace, strikethrough and links (incl. links to other notes)
- Lists with subtasks, drag to reorder, checked items at the bottom, delete checked
- Colors (12 NotallyX presets and custom), labels, pin, archive, bin, duplicate, search, sort
- Images, files and audio playback; add images and files from disk
- Reminders with repetition, as local notifications
- Live sync while the app is active (long poll), conflict-free field merge with the Android app

## Requirements

- macOS 26 or later
- Command Line Tools (Xcode is not needed)

## Build and run

```sh
./build-app.sh          # NotallyXYZ.app, release, ad-hoc signed, App Sandbox
open NotallyXYZ.app
```

`UNIVERSAL=1 ./build-app.sh` adds Intel. The script builds against the macOS 26.5 SDK of the
Command Line Tools: the macOS 27 SDK declares SwiftUI's `@State` as a macro whose plugin
ships only with Xcode.

On first start, enter your server address, then either paste the sync key from another device
or create an account with the server's invite token (`SIGNUP_TOKEN`). A new key is shown once:
store it in a password manager.

## Tests

```sh
(cd ../server && go build -o /tmp/nxyz-mac-test-server .)
./test.sh
```

The tests check the crypto against `testvectors.json` from the server repo, and run
end-to-end sync against a real server on `127.0.0.1:8788`: account, notes, labels, blobs,
conflicts, field merge, deletes, echo suppression, notes open in an editor, first-pull
linking.

## Security and privacy

- The sync key stays in the Keychain (this device only). Notes are encrypted with
  AES-256-GCM before they leave the Mac; the server sees only random ids and padded ciphertext.
- The local cache keeps the records and attachments exactly as sealed on the server. Notes are
  decrypted only in memory. Opening a file in another app writes a plaintext copy to a private
  temporary folder that is deleted on quit.
- App Sandbox with network client and user-selected files only. Hardened runtime.
- HTTPS only (plain HTTP is accepted for `localhost` for testing). Ephemeral URL session: no
  cookies, no cache. No analytics, no other network calls.
- `NotallyXYZ.app/Contents/MacOS/NotallyXYZ --selftest` checks Keychain, storage and
  notifications inside the sandbox.

## Known limitations

- No audio recording (playback only), no home screen widgets.
- Unknown JSON fields are kept at the top level of a note only, not inside items or spans.

## License

GPL-3.0, like NotallyX, whose design and icon this app uses. See `LICENSE.md`.
