#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [[ ! -d Engine/node_modules ]]; then
  (cd Engine && npm ci --ignore-scripts)
fi
node Engine/build.mjs
swift build --disable-sandbox -c release --scratch-path .build
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pandanote-package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Pandanote.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pandanote "$APP/Contents/MacOS/Pandanote"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr --noacl Engine/runtime "$APP/Contents/Resources/Engine"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
cp Resources/PandaSketch.png "$APP/Contents/Resources/"
xattr -cr "$APP"
IDENTITY="${PANDANOTE_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
  echo "Signed local development app (ad hoc signature)."
else
  codesign --force --options runtime --timestamp --entitlements Resources/Pandanote.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signed app with Developer ID."
fi
mkdir -p dist
# Preserve the verified bytes in an archive before FileProvider can add Finder
# metadata to the workspace's .app directory. Releases/installations use this ZIP.
ditto -c -k --norsrc --noextattr --keepParent "$APP" dist/Pandanote-build.zip
# Keep a running app's executable intact while replacing its bundle location.
if [[ -d dist/Pandanote.app ]]; then mv dist/Pandanote.app ".build/Pandanote-previous-$(date +%s).app"; fi
mv "$APP" dist/Pandanote.app
echo "Built $PWD/dist/Pandanote.app"
