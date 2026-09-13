#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Same Developer ID + Keychain notary profile convention as TidalDrift.
: "${PANDANOTE_SIGN_IDENTITY:?Set PANDANOTE_SIGN_IDENTITY to your Developer ID Application identity.}"
export PANDANOTE_SIGN_IDENTITY
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Pandanote-${VERSION}.dmg"
Scripts/build-app.sh
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pandanote-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto -x -k dist/Pandanote-build.zip "$STAGE"
xattr -cr "$STAGE/Pandanote.app"
codesign --verify --deep --strict "$STAGE/Pandanote.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Pandanote -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$PANDANOTE_SIGN_IDENTITY" "$DMG"
if [[ "${1:-}" == "--notarize" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "${PANDANOTE_NOTARY_PROFILE:-notarytool-profile}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
