# NotallyXYZ

NotallyX notes with end-to-end encrypted sync to your own server.

| Folder              | What                                                          |
|---------------------|---------------------------------------------------------------|
| [android](android)  | Fork of [NotallyX](https://github.com/Crustack/NotallyX) with sync (package `com.notallyxyz`) |
| [server](server)    | Zero-knowledge sync server (Go, Docker). Protocol: [server/PROTOCOL.md](server/PROTOCOL.md) |
| [mac](mac)          | Native macOS app (SwiftUI, Liquid Glass, macOS 26+)           |
| [desktop](desktop)  | Linux and Windows app (Go, Wails, system web view)            |

The server stores only ciphertext. Notes, labels and attachments are encrypted on the device
with keys derived from one random sync key. There are no user names, passwords or e-mail
addresses, and no telemetry.

## Releases

- Android APK and macOS disk image: attached to each GitHub release (`./release.zsh <version>`
  builds them; the Android signing key and the macOS signing identity stay on the build Mac, in
  `~/.config/notallyxyz/`: back up both).
- macOS with Homebrew: `brew install --cask turtlecute33/tap/notallyxyz`, then `brew upgrade`.
  After the release is published, `./update-tap.zsh <version>` points the cask in
  [homebrew-tap](https://github.com/Turtlecute33/homebrew-tap) to the new disk image.
- Linux (`.deb`, `.tar.gz`, x86_64 and aarch64) and Windows (portable `.exe`): built by
  [GitHub Actions](.github/workflows/desktop.yml) when a `v*` tag is pushed, attached to the same
  release with build provenance (`gh attestation verify <file> -R Turtlecute33/NotallyXYZ`).
- Server image: `ghcr.io/turtlecute33/notallyxyz-server`, built by
  [GitHub Actions](.github/workflows/server-image.yml) when a `v*` tag is pushed.
- `SHA256SUMS` in the release covers all files.

Update the server and all apps together: since 1.1.0 every deletion is sealed (see
[PROTOCOL.md](server/PROTOCOL.md) §5), and 1.0.0 apps cannot sync deletions with a 1.1.0 server.

## Tests

```zsh
(cd server && go test -race ./... && go build -o /tmp/nxyz-android-test-server . && cp /tmp/nxyz-android-test-server /tmp/nxyz-mac-test-server)
(cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew testDebugUnitTest)
(cd mac && ./test.sh)
(cd desktop && go test -race ./core/)
```

## Upstream updates (Android)

`android/` is a git subtree of NotallyX. To merge a new upstream version:

```zsh
git subtree pull --prefix=android https://github.com/Crustack/NotallyX.git main --squash
```

## License

GPL-3.0 (see [android/LICENSE.md](android/LICENSE.md)).
