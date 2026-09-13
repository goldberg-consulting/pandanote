#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  ""|--prepare-only|--install-only) ;;
  *) echo "Usage: Scripts/build-homebrew.sh [--prepare-only|--install-only]" >&2; exit 2 ;;
esac
BREW="${PANDANOTE_BREW:-/opt/homebrew/bin/brew}"
if [[ ! -x "$BREW" ]]; then BREW="$(command -v brew)"; fi
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo 'Invalid app version.' >&2; exit 1; }
ARCHIVE="$PWD/dist/Pandanote-${VERSION}-${BUILD}.zip"
CASK="$PWD/.build/homebrew/Casks/pandanote.rb"
TAP="goldberg-consulting/pandanote-local"
TOKEN="$TAP/pandanote"
HOMEBREW_STAGE="$(mktemp -d /private/tmp/pandanote-homebrew.XXXXXX)"
trap 'rm -rf "$HOMEBREW_STAGE"' EXIT

if [[ "$MODE" != --install-only ]]; then
  export PANDANOTE_SIGN_IDENTITY="${PANDANOTE_SIGN_IDENTITY:-Developer ID Application: Eli Goldberg (97UY84BV45)}"
  Scripts/build-app.sh
  cp dist/Pandanote-build.zip "$HOMEBREW_STAGE/Pandanote-build.zip"
  # Keep the signed bundle outside FileProvider folders while attaching its ticket.
  ditto -x -k "$HOMEBREW_STAGE/Pandanote-build.zip" "$HOMEBREW_STAGE"
  NOTARY_APP="$HOMEBREW_STAGE/Pandanote.app"
  codesign --verify --deep --strict "$NOTARY_APP"
  echo 'Submitting the signed app to Apple for notarization.'
  if ! xcrun notarytool submit "$HOMEBREW_STAGE/Pandanote-build.zip" \
    --keychain-profile "${PANDANOTE_NOTARY_PROFILE:-notarytool-profile}" \
    --wait --output-format json > "$HOMEBREW_STAGE/notarization.json"; then
    cat "$HOMEBREW_STAGE/notarization.json" >&2
    exit 1
  fi
  /usr/bin/python3 - "$HOMEBREW_STAGE/notarization.json" <<'PY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
status = result.get('status', 'Unknown')
print(f"Apple notarization: {status} (submission {result.get('id', 'unknown')})")
if status != 'Accepted':
    raise SystemExit('Notarization was not accepted; no Homebrew archive was prepared.')
PY
  xcrun stapler staple "$NOTARY_APP"
  xcrun stapler validate "$NOTARY_APP"
  codesign --verify --deep --strict "$NOTARY_APP"
  # Preserve the stapled ticket and bundle metadata in the install archive.
  ditto -c -k --sequesterRsrc --keepParent "$NOTARY_APP" "$HOMEBREW_STAGE/Pandanote-notarized.zip"
  mv "$HOMEBREW_STAGE/Pandanote-notarized.zip" "$ARCHIVE"
fi

[[ -f "$ARCHIVE" && ( "$MODE" != --install-only || -f "$CASK" ) ]] || {
  echo 'Prepare the Homebrew build first.' >&2
  exit 1
}

# Validate the final archive before Homebrew can replace an installed app.
mkdir "$HOMEBREW_STAGE/verification"
cp "$ARCHIVE" "$HOMEBREW_STAGE/prepared.zip"
ditto -x -k "$HOMEBREW_STAGE/prepared.zip" "$HOMEBREW_STAGE/verification"
VERIFIED_APP="$HOMEBREW_STAGE/verification/Pandanote.app"
VERIFIED_PLIST="$VERIFIED_APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$VERIFIED_PLIST")" == "$VERSION" \
  && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$VERIFIED_PLIST")" == "$BUILD" \
  && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$VERIFIED_PLIST")" == com.goldbergconsulting.pandanote ]] || {
  echo 'Prepared app identity or version does not match Resources/Info.plist.' >&2
  exit 1
}
codesign --verify --deep --strict "$VERIFIED_APP"
xcrun stapler validate "$VERIFIED_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$VERIFIED_APP"

mkdir -p "$(dirname "$CASK")"
/usr/bin/python3 - "$ARCHIVE" "$HOMEBREW_STAGE/prepared.zip" "$CASK" "$VERSION" "$MODE" <<'PY'
import hashlib, pathlib, sys
archive, snapshot, cask, version, mode = sys.argv[1:]
template = pathlib.Path('Homebrew/pandanote.rb.in').read_text()
result = template.replace('@VERSION@', version).replace('@SHA256@', hashlib.sha256(pathlib.Path(snapshot).read_bytes()).hexdigest())
result = result.replace('@URL@', pathlib.Path(archive).resolve().as_uri())
if mode == '--install-only':
    if pathlib.Path(cask).read_text() != result:
        raise SystemExit('Prepared cask does not match the archive checksum, URL, version, or current template. Prepare it again.')
else:
    pathlib.Path(cask).write_text(result)
PY

if [[ "$MODE" == --prepare-only ]]; then
  echo "Prepared notarized PandaNote $VERSION ($BUILD) for Homebrew."
  exit 0
fi

if ! "$BREW" tap | /usr/bin/grep -Fxq "$TAP"; then "$BREW" tap-new --no-git "$TAP"; fi
TAP_PATH="$("$BREW" --repository "$TAP")"
mkdir -p "$TAP_PATH/Casks"
cp "$CASK" "$TAP_PATH/Casks/pandanote.rb"
# Trust only this locally generated, checksum-pinned cask, never the whole tap.
"$BREW" trust --cask "$TOKEN"
if "$BREW" list --cask --versions pandanote >/dev/null 2>&1; then
  "$BREW" reinstall --cask --appdir=/Applications --no-ask "$TOKEN"
else
  "$BREW" install --cask --appdir=/Applications --no-ask "$TOKEN"
fi
codesign --verify --deep --strict /Applications/Pandanote.app
xcrun stapler validate /Applications/Pandanote.app
/usr/sbin/spctl --assess --type execute --verbose=2 /Applications/Pandanote.app
"$BREW" list --cask --versions pandanote
