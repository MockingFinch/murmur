#!/bin/zsh
# Creates Murmur's local signing certificate (once), so macOS keeps
# Accessibility and Microphone permissions across rebuilds and updates.
# See scripts/signing.sh for what it does and where it keeps things.
set -euo pipefail
source "${0:A:h}/signing.sh"
identity="$(murmur_signing_identity)"
echo "✓ Signing identity ready: ${identity%%$'\t'*}"
echo "  Next builds (scripts/build.sh) are signed with it. Allow Accessibility once more after the next build;"
echo "  from then on, rebuilds keep it."
