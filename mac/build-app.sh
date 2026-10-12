#!/bin/zsh
# Builds NotallyXYZ.app (release, hardened runtime, App Sandbox).
#   ./build-app.sh              arm64
#   UNIVERSAL=1 ./build-app.sh  arm64 + x86_64
#   CONFIG=debug ./build-app.sh debug build (enables the NXYZ_DEMO_* screenshot hook)
# Signs with the stable self-signed identity of tools/make-signing-identity.zsh if it exists,
# else ad-hoc. SIGNED=1 requires the identity (release builds).
set -euo pipefail
cd "${0:A:h}"

# The macOS 27 SDK of the Command Line Tools declares SwiftUI's @State as a macro whose
# plugin ships only with Xcode. Build against the newest SDK that does not need it.
if [[ -z "${SDKROOT:-}" ]]; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [[ -d $sdk ]] && { export SDKROOT=$sdk; break; }
  done
fi

APP=NotallyXYZ.app
CONFIG=${CONFIG:-release}
archs=(arm64)
[[ "${UNIVERSAL:-0}" == 1 ]] && archs=(arm64 x86_64)

bins=()
tmp=$(mktemp -d)
for arch in $archs; do
  swift build -c $CONFIG --triple "$arch-apple-macosx26.0" --product NotallyXYZ
  cp "$(swift build -c $CONFIG --triple "$arch-apple-macosx26.0" --show-bin-path)/NotallyXYZ" "$tmp/NotallyXYZ-$arch"
  bins+=("$tmp/NotallyXYZ-$arch")
done

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
lipo -create $bins -output $APP/Contents/MacOS/NotallyXYZ
rm -rf $tmp
[[ $CONFIG == release ]] && strip -x $APP/Contents/MacOS/NotallyXYZ
cp Resources/Info.plist $APP/Contents/Info.plist
print -n "APPL????" > $APP/Contents/PkgInfo

# Icon: all sizes from the 1024 px master.
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p $iconset
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out $iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out $iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $iconset -o $APP/Contents/Resources/AppIcon.icns
rm -rf ${iconset:h}

# The same identity in every release keeps Gatekeeper approval and Keychain access after updates.
signing=$HOME/.config/notallyxyz/macos-signing.keychain-db
sign=(--sign -)
if [[ -f $signing ]]; then
  security unlock-keychain -p "$(security find-generic-password -s notallyxyz-macos-signing -a keychain -w)" $signing
  sign=(--sign NotallyXYZ --keychain $signing)
elif [[ "${SIGNED:-0}" == 1 ]]; then
  print -u2 "No signing identity: run tools/make-signing-identity.zsh (once) or restore $signing"
  exit 1
fi
codesign --force $sign --options runtime --timestamp=none \
  --entitlements NotallyXYZ.entitlements $APP
codesign --verify --strict $APP
print "Built $APP ($(du -sh $APP | cut -f1), binary $(du -h $APP/Contents/MacOS/NotallyXYZ | cut -f1))"
