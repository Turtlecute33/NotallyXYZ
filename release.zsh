#!/bin/zsh
# Builds the release files into dist/<version>/: signed Android APK, macOS disk image (universal) and
# SHA256SUMS. GitHub Actions builds the server image and the Linux and Windows apps when the tag is
# pushed, and adds the desktop files to SHA256SUMS of the release.
#   ./release.zsh 1.0.0
set -euo pipefail
version=${1:?usage: ./release.zsh <version>}
root=${0:A:h}
out=$root/dist/$version
rm -rf $out && mkdir -p $out

print "== Android"
$root/android/scripts/build-release.zsh
cp $root/android/app/build/outputs/apk/release/NotallyXYZ-*.apk $out/NotallyXYZ-android-$version.apk
git -C $root checkout -- android/app/obfuscation 2>/dev/null || true

print "== macOS"
(cd $root/mac && UNIVERSAL=1 SIGNED=1 ./build-app.sh)
$root/mac/make-dmg.zsh $out/NotallyXYZ-macos-$version.dmg

(cd $out && shasum -a 256 * > SHA256SUMS && cat SHA256SUMS)
