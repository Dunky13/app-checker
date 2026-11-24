#!/bin/bash
# Publishes a signed, notarized release and updates the Sparkle feed.
#   scripts/release.sh 0.2.0
# Needs: a Developer ID Application certificate, the Sparkle EdDSA key in the login keychain
# (or SPARKLE_KEY_FILE), the gh CLI, and notarization credentials as either
#   NOTARY_KEYCHAIN_PROFILE=<notarytool profile>
# or NOTARY_KEY_FILE=<AuthKey.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER_ID=<issuer>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
REPO="Dunky13/app-checker"
APP="build/App Checker.app"
OUT="build/release"
ZIP="AppChecker-$VERSION-universal.zip"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2; exit 1
fi
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first: a release is built from a clean commit." >&2; exit 1; }
# The tag must point at exactly the commit that is built, and the feed is served from main.
COMMIT="$(git rev-parse HEAD)"
[[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$COMMIT" ]] || { echo "Check out main and push it first: HEAD is not the tip of origin/main." >&2; exit 1; }
[[ -z "$(git ls-remote origin "refs/tags/v$VERSION")" ]] || { echo "v$VERSION already exists." >&2; exit 1; }

swift test
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}" scripts/build-app.sh "$VERSION"

rm -rf "$OUT"
mkdir -p "$OUT" build/notary
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

# Submit once and keep the receipt. If waiting times out the submission is still pending at Apple:
# continue with `xcrun notarytool wait <id>` from the receipt instead of uploading again.
RECEIPT="build/notary/$ZIP.submit.json"
xcrun notarytool submit "$OUT/$ZIP" "${AUTH[@]}" --no-wait --output-format json > "$RECEIPT"
ID="$(plutil -extract id raw "$RECEIPT")"
echo "commit=$COMMIT sha256=$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1) submission=$ID" | tee "build/notary/$ZIP.receipt.txt"
xcrun notarytool wait "$ID" "${AUTH[@]}" --timeout 30m --output-format json > "build/notary/$ZIP.result.json" || true
xcrun notarytool log "$ID" "${AUTH[@]}" "build/notary/$ZIP.log.json" || true
STATUS="$(plutil -extract status raw "build/notary/$ZIP.result.json")"
[[ "$STATUS" == "Accepted" ]] || { echo "Notarization status: $STATUS. See build/notary/$ZIP.log.json" >&2; exit 1; }

# A zip cannot be stapled, so staple the app and zip it again. That second zip is what ships.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

# generate_appcast signs the archive with the EdDSA key and adds it to the existing feed.
KEY=()
[[ -z "${SPARKLE_KEY_FILE:-}" ]] || KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
# ${KEY[@]+...}: an empty array is an error under `set -u` in the bash 3.2 that macOS ships.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$OUT" ${KEY[@]+"${KEY[@]}"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" -o appcast.xml
grep -F "$ZIP" appcast.xml | grep -q "sparkle:edSignature" || { echo "The appcast entry for $ZIP is not signed." >&2; exit 1; }

# The download must exist before the feed points at it.
gh release create "v$VERSION" "$OUT/$ZIP" --repo "$REPO" --target "$COMMIT" --title "App Checker $VERSION" --generate-notes
git add appcast.xml
git commit -s -m "Release $VERSION"
git push
echo "Released $VERSION"
