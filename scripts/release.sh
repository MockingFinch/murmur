#!/bin/zsh
# Builds a release: build/Murmur-<version>.dmg (drag to Applications) and
# build/Murmur-<version>.zip, with their SHA-256 sums.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

swift test
scripts/build.sh

echo "› Packaging $version…"
stage="build/dmg"
rm -rf "$stage" "build/Murmur-$version.dmg" "build/Murmur-$version.zip"
mkdir -p "$stage"
ditto build/Murmur.app "$stage/Murmur.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Murmur $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov \
  "build/Murmur-$version.dmg" >/dev/null
rm -rf "$stage"
ditto -c -k --sequesterRsrc --keepParent build/Murmur.app "build/Murmur-$version.zip"

(cd build && shasum -a 256 "Murmur-$version.dmg" "Murmur-$version.zip" | tee "Murmur-$version.sha256")
echo "✓ build/Murmur-$version.dmg"
