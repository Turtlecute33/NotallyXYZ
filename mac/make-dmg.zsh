#!/bin/zsh
# Packs NotallyXYZ.app into a compressed disk image with a link to /Applications,
# so that users install it by dragging (an app run from Downloads is not installed).
#   ./make-dmg.zsh <output.dmg>
set -euo pipefail
out=${1:?usage: ./make-dmg.zsh <output.dmg>}
cd "${0:A:h}"
stage=$(mktemp -d)/NotallyXYZ
mkdir -p $stage
ditto NotallyXYZ.app $stage/NotallyXYZ.app
ln -s /Applications $stage/Applications
rm -f $out
hdiutil create -quiet -volname NotallyXYZ -srcfolder $stage -fs APFS -format ULFO -ov $out
rm -rf ${stage:h}
hdiutil verify -quiet $out
print "Built $out ($(du -h $out | cut -f1))"
