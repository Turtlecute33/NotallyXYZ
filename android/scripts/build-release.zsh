#!/bin/zsh
# Builds a signed release APK. The keystore password comes from the macOS Keychain
# (service "notallyxyz-android-keystore") and is passed to Gradle only via the environment.
set -euo pipefail
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
keystore=${NOTALLYXYZ_KEYSTORE:-$HOME/.config/notallyxyz/release.jks}
password=$(security find-generic-password -s notallyxyz-android-keystore -a release -w)
cd "${0:A:h}/.."
ORG_GRADLE_PROJECT_RELEASE_STORE_FILE=$keystore \
ORG_GRADLE_PROJECT_RELEASE_STORE_PASSWORD=$password \
ORG_GRADLE_PROJECT_RELEASE_KEY_ALIAS=notallyxyz \
ORG_GRADLE_PROJECT_RELEASE_KEY_PASSWORD=$password \
  ./gradlew --console=plain assembleRelease "$@"
apk=(app/build/outputs/apk/release/*.apk)
"$HOME/Library/Android/sdk/build-tools/$(ls $HOME/Library/Android/sdk/build-tools | sort -V | tail -1)/apksigner" verify --print-certs $apk | grep -i 'SHA-256'
echo "APK: $PWD/$apk"
