#!/bin/zsh
# Runs the tests. The explicit plugin path avoids a Command Line Tools issue with swift-testing macros.
# The sync test needs the server binary: (cd ../server && go build -o /tmp/nxyz-mac-test-server .)
set -e
cd "${0:A:h}"
[[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
