#!/bin/zsh
# Creates the self-signed code signing identity for release builds of the macOS app (run once).
# With the same identity in every release, the designated requirement of the app stays the same,
# so the Gatekeeper approval (Homebrew carries it over on upgrade) and the Keychain access of the
# app stay valid after an update.
#
# The identity goes into its own keychain (~/.config/notallyxyz/macos-signing.keychain-db); its
# random password goes into the login Keychain (service "notallyxyz-macos-signing"), so that
# build-app.sh can sign without prompts. Back up the keychain file together with the Android keystore:
# a new identity means one more Gatekeeper approval and Keychain prompt for every user.
set -euo pipefail
dir=$HOME/.config/notallyxyz
kc=$dir/macos-signing.keychain-db
[[ -e $kc ]] && { print -u2 "Already exists: $kc"; exit 1 }
mkdir -p -m 700 $dir
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
pw=$(/usr/bin/openssl rand -base64 30)

# macOS LibreSSL: its PKCS#12 format is what `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -subj "/CN=NotallyXYZ" \
  -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
/usr/bin/openssl pkcs12 -export -name NotallyXYZ -inkey $tmp/key.pem -in $tmp/cert.pem \
  -out $tmp/identity.p12 -passout pass:$pw

security create-keychain -p $pw $kc
security set-keychain-settings $kc
security unlock-keychain -p $pw $kc
security import $tmp/identity.p12 -k $kc -P $pw -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k $pw $kc >/dev/null
security add-generic-password -U -s notallyxyz-macos-signing -a keychain -l "NotallyXYZ macOS signing keychain" -w $pw
security find-identity -p codesigning $kc
print "Created $kc"
