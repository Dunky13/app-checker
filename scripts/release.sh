#!/bin/bash
# Publishes a signed, notarized release and updates the Sparkle feed and the Homebrew cask.
#   scripts/release.sh 0.2.0
# Needs: a Developer ID Application certificate, the Sparkle EdDSA key in the login keychain
# (or SPARKLE_KEY_FILE), the gh CLI, create-dmg (brew install create-dmg), a logged-in session in which
# this terminal may control Finder (create-dmg arranges the disk image window through Finder, and waits
# for it without a time limit), and notarization credentials as either
#   NOTARY_KEYCHAIN_PROFILE=<notarytool profile>
# or NOTARY_KEY_FILE=<AuthKey.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER_ID=<issuer>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
# Checked first: the version ends up in a file name, a tag, the feed and the cask.
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}$ ]] || { echo "Not a version like 1.2 or 1.2.3: $VERSION" >&2; exit 1; }
REPO="Dunky13/kanarie"
APP="build/Kanarie.app"
OUT="build/release"
ZIP="Kanarie-$VERSION-universal.zip"
# Kept out of $OUT: generate_appcast publishes every archive there, and Sparkle updates from the zip.
DMG="build/dmg/Kanarie-$VERSION-universal.dmg"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  AUTH=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2; exit 1
fi
command -v create-dmg >/dev/null || { echo "Install create-dmg first: brew install create-dmg" >&2; exit 1; }
# Asked now rather than after the first notarization: the first time, macOS asks whether this terminal may control Finder.
osascript -e 'tell application "Finder" to get name' >/dev/null || { echo "Let this terminal control Finder (System Settings, Privacy & Security, Automation), in a logged-in session." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first: a release is built from a clean commit." >&2; exit 1; }
# The tag must point at exactly the commit that is built, and the feed is served from main.
COMMIT="$(git rev-parse HEAD)"
[[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$COMMIT" ]] || { echo "Check out main and push it first: HEAD is not the tip of origin/main." >&2; exit 1; }
[[ -z "$(git ls-remote origin "refs/tags/v$VERSION")" ]] || { echo "v$VERSION already exists." >&2; exit 1; }

# Submit once and keep the receipt. If waiting times out the submission is still pending at Apple:
# continue with `xcrun notarytool wait <id>` from the receipt instead of uploading again.
notarize() {
  local file="$1" name; name="$(basename "$1")"
  xcrun notarytool submit "$file" "${AUTH[@]}" --no-wait --output-format json > "build/notary/$name.submit.json"
  local id; id="$(plutil -extract id raw "build/notary/$name.submit.json")"
  # The hash of the file as submitted: stapling or zipping again afterwards changes the file, not its signature.
  echo "commit=$COMMIT sha256=$(shasum -a 256 "$file" | cut -d' ' -f1) submission=$id" | tee "build/notary/$name.receipt.txt"
  xcrun notarytool wait "$id" "${AUTH[@]}" --timeout 30m --output-format json > "build/notary/$name.result.json" || true
  xcrun notarytool log "$id" "${AUTH[@]}" "build/notary/$name.log.json" || true
  local status; status="$(plutil -extract status raw "build/notary/$name.result.json")"
  [[ "$status" == "Accepted" ]] || { echo "Notarization status: $status. See build/notary/$name.log.json" >&2; exit 1; }
}

swift test
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}" scripts/build-app.sh "$VERSION"

rm -rf "$OUT" build/dmg
mkdir -p "$OUT" build/notary build/dmg/source
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
notarize "$OUT/$ZIP"

# A zip cannot be stapled, so staple the app and zip it again. That second zip is what ships.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm "$OUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"

# For downloads from the release page: open it and drag Kanarie onto Applications.
# The disk image holds the stapled app and is notarized and stapled itself, so it also opens offline.
ditto "$APP" build/dmg/source/Kanarie.app
create-dmg --volname "Kanarie" --window-size 540 360 --icon-size 128 \
  --icon Kanarie.app 140 170 --hide-extension Kanarie.app --app-drop-link 400 170 \
  --no-internet-enable "$DMG" build/dmg/source
# Signed here rather than by create-dmg, which leaves the timestamp to codesign's default.
codesign --sign "${CODESIGN_IDENTITY:-Developer ID Application}" --timestamp "$DMG"
codesign --verify --strict "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# generate_appcast signs the archive with the EdDSA key and adds it to the existing feed.
KEY=()
[[ -z "${SPARKLE_KEY_FILE:-}" ]] || KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
# ${KEY[@]+...}: an empty array is an error under `set -u` in the bash 3.2 that macOS ships.
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$OUT" ${KEY[@]+"${KEY[@]}"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" -o appcast.xml
grep -F "$ZIP" appcast.xml | grep -q "sparkle:edSignature" || { echo "The appcast entry for $ZIP is not signed." >&2; exit 1; }

# Homebrew installs the same archive: the cask in this repository names the version and its hash.
SHA="$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)"
perl -pi -e "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/kanarie.rb
if ! grep -qxF "  version \"$VERSION\"" Casks/kanarie.rb || ! grep -qxF "  sha256 \"$SHA\"" Casks/kanarie.rb; then
  echo "Casks/kanarie.rb was not updated." >&2; exit 1
fi

# The download must exist before the feed and the cask point at it.
gh release create "v$VERSION" "$OUT/$ZIP" "$DMG" --repo "$REPO" --target "$COMMIT" --title "Kanarie $VERSION" --generate-notes
git add appcast.xml Casks/kanarie.rb
git commit -s -m "Release $VERSION"
# main may have moved during notarization; the tag already points at $COMMIT, and this commit only touches the feed and the cask.
git pull --rebase origin main
git push origin HEAD:main
echo "Released $VERSION"
