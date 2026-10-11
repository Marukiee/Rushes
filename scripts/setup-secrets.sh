#!/usr/bin/env bash
# Uploads the signing material in ~/keystores to the GitHub repository as Actions
# secrets, so the release workflow signs with the same keys as local builds.
#
# Values travel through pipes into `gh secret set`, never through arguments or
# output, so nothing shows up in the process list or in a terminal log. Safe to run
# again: it overwrites the secrets with the same values.
#
#   scripts/setup-secrets.sh
set -euo pipefail

REPO="${RUSHES_REPO:-Marukiee/Rushes}"
DIR="${RUSHES_KEYSTORES:-$HOME/keystores}"

for file in rushes-mac-signing.p12 rushes-mac-signing.password rushes-update-ed25519.secret; do
  [ -s "$DIR/$file" ] || { echo "missing $DIR/$file (run the key scripts first)" >&2; exit 1; }
done

set_secret() { # name, then the value on stdin
  gh secret set "$1" --repo "$REPO" >/dev/null
  echo "set $1"
}
b64() { base64 <"$1" | tr -d '\n'; }
text() { tr -d '[:space:]' <"$1"; }

b64 "$DIR/rushes-mac-signing.p12" | set_secret MACOS_CERT_P12_B64
text "$DIR/rushes-mac-signing.password" | set_secret MACOS_CERT_PASSWORD
text "$DIR/rushes-update-ed25519.secret" | set_secret RUSHES_UPDATE_ED25519_SECRET

echo "done, names only:"
gh secret list --repo "$REPO"
