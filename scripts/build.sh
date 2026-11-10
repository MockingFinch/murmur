#!/bin/zsh
# Builds Murmur.app into ./build.
#
#   scripts/build.sh            release build
#   scripts/build.sh --open     …and launch it
#
# Signing, in order:
#   1. MURMUR_SIGN_IDENTITY, if set (e.g. "Apple Development: you@example.com (TEAMID)");
#   2. the local certificate from scripts/setup-signing.sh, if you made one;
#   3. otherwise ad-hoc. Ad-hoc builds look like a new app to macOS each
#      time, so Accessibility must be allowed again after every rebuild.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
app="build/Murmur.app"
identity="${MURMUR_SIGN_IDENTITY:-}"
keychain_args=()
if [[ -z "$identity" ]]; then
  source scripts/signing.sh
  local_identity="$(murmur_signing_identity --existing-only)"
  if [[ -n "$local_identity" ]]; then
    identity="${local_identity%%$'\t'*}"
    keychain_args=(--keychain "${local_identity#*$'\t'}")
  else
    identity="-"
  fi
fi

echo "› Compiling (release)…"
swift build -c release --product Murmur
bin="$(swift build -c release --product Murmur --show-bin-path)/Murmur"

echo "› Drawing the icon…"
iconset="build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p build
swift scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o build/AppIcon.icns

echo "› Assembling $app…"
was_running=0
if pgrep -x Murmur >/dev/null; then
  was_running=1
  osascript -e 'tell application id "local.murmur.dictation" to quit' >/dev/null 2>&1 || pkill -x Murmur || true
  sleep 0.5
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Murmur"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

echo "› Signing (${identity})…"
codesign --force --sign "$identity" "${keychain_args[@]}" --timestamp=none "$app"
codesign --verify --strict "$app"

echo "✓ Built $root/$app"
if [[ "${1:-}" == "--open" || $was_running == 1 ]]; then
  open "$app"
fi
