#!/bin/bash
# Writes findings/index.json, the list of every finding file with its SHA-256, and signs it with the
# Sparkle EdDSA key. The app only accepts downloaded findings that match a signed index, so run this
# after every change below findings/ and commit the index and its signature with it.
# The key is read from the login keychain, or from SPARKLE_KEY_FILE.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL="$PWD/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$TOOL" ]] || swift package resolve
KEY=()
[[ -z "${SPARKLE_KEY_FILE:-}" ]] || KEY=(--ed-key-file "$SPARKLE_KEY_FILE")

cd findings
ENTRIES=""
for FILE in */*.json; do
  # The same plain names the app accepts, so nothing here needs escaping.
  [[ "$FILE" =~ ^[a-z0-9-]+/[A-Za-z0-9._-]+\.json$ ]] || { echo "Unexpected file name: findings/$FILE" >&2; exit 1; }
  ENTRIES+="${ENTRIES:+,
}    \"$FILE\": \"$(shasum -a 256 "$FILE" | cut -d' ' -f1)\""
done
# The serial only ever grows, so the app can refuse an older index.
printf '{\n  "version": 1,\n  "serial": %s,\n  "files": {\n%s\n  }\n}\n' "$(date +%s)" "$ENTRIES" > index.json
# ${KEY[@]+...}: an empty array is an error under `set -u` in the bash 3.2 that macOS ships.
"$TOOL" -p ${KEY[@]+"${KEY[@]}"} index.json > index.json.sig
echo "Signed findings/index.json"
