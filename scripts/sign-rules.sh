#!/bin/bash
# Signs rules.json with the Sparkle EdDSA key. The app only accepts a downloaded rules.json whose
# signature in rules.json.sig matches, so run this after every change to rules.json and commit both.
# The key is read from the login keychain, or from SPARKLE_KEY_FILE.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x "$TOOL" ]] || swift package resolve
KEY=()
[[ -z "${SPARKLE_KEY_FILE:-}" ]] || KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
"$TOOL" -p ${KEY[@]+"${KEY[@]}"} rules.json > rules.json.sig
echo "Signed rules.json"
