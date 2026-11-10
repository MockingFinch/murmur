#!/bin/zsh
# A stable signing identity for local builds, made once.
#
# macOS remembers permissions (Accessibility, Microphone) by an app's code
# signature. Ad-hoc signatures change with every build, so every rebuild
# would look like a new app and lose them. A self-signed certificate keeps
# the signature's identity the same from build to build.
#
# The certificate lives in its own small keychain file, outside the repo and
# apart from your login keychain:
#   ~/Library/Application Support/Murmur/Signing/
# Its password is generated and kept next to it (mode 600). Your keychain
# search list is left exactly as it was.
#
# Create it with `scripts/setup-signing.sh` (once). After that, every
# `scripts/build.sh` signs with it. Source this file and call
# `murmur_signing_identity` to get the identity's SHA-1 and keychain path,
# separated by a tab; `--existing-only` returns nothing if it isn't set up.

murmur_signing_identity() {
  local dir="$HOME/Library/Application Support/Murmur/Signing"
  local kc="$dir/murmur-signing.keychain-db"
  local pwfile="$dir/keychain-password"
  local name="Murmur Local Signing"

  if [[ ! -f "$kc" && "${1:-}" == "--existing-only" ]]; then
    return 0
  fi

  if [[ ! -f "$kc" ]]; then
    echo "› Creating a local signing certificate (once)…" >&2
    mkdir -p "$dir" && chmod 700 "$dir"
    local pw; pw="$(openssl rand -hex 24)"
    print -r -- "$pw" > "$pwfile" && chmod 600 "$pwfile"

    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 \
      -config "$tmp/cert.cnf" -extensions ext \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "$name" -out "$tmp/identity.p12" -passout "pass:$pw"

    # `create-keychain` adds itself to the search list; put the list back.
    local -a saved
    saved=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
    security create-keychain -p "$pw" "$kc"
    security list-keychains -d user -s "${saved[@]}"
    security set-keychain-settings "$kc"          # never auto-lock
    security unlock-keychain -p "$pw" "$kc"
    security import "$tmp/identity.p12" -k "$kc" -P "$pw" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null
    rm -rf "$tmp"
  fi

  security unlock-keychain -p "$(cat "$pwfile")" "$kc"
  local sha
  sha="$(security find-identity -p codesigning "$kc" | awk -v n="\"$name\"" 'index($0, n) { print $2; exit }')"
  [[ -n "$sha" ]] || { echo "Couldn't find the signing identity in $kc" >&2; return 1; }
  printf '%s\t%s\n' "$sha" "$kc"
}
