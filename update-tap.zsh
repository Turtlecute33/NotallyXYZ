#!/bin/zsh
# Points the Homebrew cask (github.com/Turtlecute33/homebrew-tap) to a published release.
# Run after the macOS disk image is attached to the GitHub release of <version>.
#   ./update-tap.zsh 1.1.1
set -euo pipefail
version=${1:?usage: ./update-tap.zsh <version>}
dmg=NotallyXYZ-macos-$version.dmg
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

# The hash of the file that users download, not of a local build.
gh release download v$version -R Turtlecute33/NotallyXYZ -p $dmg -D $tmp
sha=$(shasum -a 256 $tmp/$dmg | cut -d' ' -f1)

gh repo clone Turtlecute33/homebrew-tap $tmp/tap -- --quiet --depth 1
cask=$tmp/tap/Casks/notallyxyz.rb
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" $cask
if git -C $tmp/tap diff --quiet; then
  print "The cask is already at $version."
  exit 0
fi
git -C $tmp/tap commit --quiet -am "notallyxyz $version"
git -C $tmp/tap push --quiet
print "Cask updated: notallyxyz $version ($sha)"
