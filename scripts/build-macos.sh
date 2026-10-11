#!/usr/bin/env bash
# Builds Rushes.app. Usage: scripts/build-macos.sh [debug|release]
# Set VERSION and BUILD to stamp a release. The update key comes from
# Resources/update-public-key.txt unless UPDATE_PUBLIC_KEY overrides it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
UPDATE_KEY="${UPDATE_PUBLIC_KEY:-}"
[ -n "$UPDATE_KEY" ] || UPDATE_KEY="$(tr -d '[:space:]' <Resources/update-public-key.txt 2>/dev/null || true)"
# An app without the key installs updates without checking who signed them.
[ "$CONFIG" != release ] || [ -n "$UPDATE_KEY" ] || { echo "no update public key for a release build"; exit 1; }
DIST="dist"
# A debug build is a separate app, so testing never touches the real ledger or preferences:
# another bundle id, and its data lives in Application Support/Rushes-Dev.
if [ "$CONFIG" = release ]; then
  BUNDLE_ID="nl.markmaaktmedia.Rushes"; APP_NAME="Rushes"
else
  BUNDLE_ID="nl.markmaaktmedia.Rushes.dev"; APP_NAME="Rushes Dev"
fi
APP="$DIST/$APP_NAME.app"

swift build -c "$CONFIG" --arch arm64 --product Rushes 2>&1 | grep -v "search path\|was built for newer" || true
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path 2>/dev/null)/Rushes"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rushes"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" -e "s|@UPDATE_KEY@|$UPDATE_KEY|" \
  -e "s|@BUNDLE_ID@|$BUNDLE_ID|" -e "s|@APP_NAME@|$APP_NAME|" \
  Resources/Info.plist >"$APP/Contents/Info.plist"

# Icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/base.png" 1024
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The script that talks to DaVinci Resolve, and what's new
cp Resources/resolve_bridge.py "$APP/Contents/Resources/resolve_bridge.py"
[ ! -f changelog.json ] || cp changelog.json "$APP/Contents/Resources/changelog.json"

# Translations
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

./scripts/mac-signing.sh sign "$APP"
echo "built $APP ($CONFIG, $VERSION)"
