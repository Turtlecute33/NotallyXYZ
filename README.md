# NotallyXYZ

NotallyX notes with end-to-end encrypted sync to your own server.

| Folder              | What                                                          |
|---------------------|---------------------------------------------------------------|
| [android](android)  | Fork of [NotallyX](https://github.com/Crustack/NotallyX) with sync (package `com.notallyxyz`) |
| [server](server)    | Zero-knowledge sync server (Go, Docker). Protocol: [server/PROTOCOL.md](server/PROTOCOL.md) |
| [mac](mac)          | Native macOS app (SwiftUI, Liquid Glass, macOS 26+)           |

The server stores only ciphertext. Notes, labels and attachments are encrypted on the device
with keys derived from one random sync key. There are no user names, passwords or e-mail
addresses, and no telemetry.

## Releases

- Android APK and macOS disk image: attached to each GitHub release (`./release.zsh <version>`
  builds them; the Android signing key stays on the build Mac).
- Server image: `ghcr.io/turtlecute33/notallyxyz-server`, built by
  [GitHub Actions](.github/workflows/server-image.yml) when a `v*` tag is pushed.

## Tests

```zsh
(cd server && go test -race ./... && go build -o /tmp/nxyz-android-test-server . && cp /tmp/nxyz-android-test-server /tmp/nxyz-mac-test-server)
(cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew testDebugUnitTest)
(cd mac && ./test.sh)
```

## Upstream updates (Android)

`android/` is a git subtree of NotallyX. To merge a new upstream version:

```zsh
git subtree pull --prefix=android https://github.com/Crustack/NotallyX.git main --squash
```

## License

GPL-3.0 (see [android/LICENSE.md](android/LICENSE.md)).
