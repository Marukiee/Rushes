#!/usr/bin/env bash
# A real screenshot of the debug app's own window, with real glass, from a fake card and a fake disk.
#
#   scripts/screenshot.sh <page> <out.png> [seconds to wait] [language]
#   pages: overview, review, library, history, resolve
#
# A folder of test footage stands in for the card (RUSHES_DEBUG_CARD) and an empty one for the disk (RUSHES_DEBUG_DEST), both
# under $RUSHES_TEST_DIR (default /tmp/rushes-test). Put a few clips in $RUSHES_TEST_DIR/card first, laid out like a Sony card
# (PRIVATE/M4ROOT/CLIP, SUB, THMBNL, GENERAL/LUT, DCIM). Only the app's own window is captured, never the screen.
# ACTIONS="page:library,wait:1" scripts the app (see DebugSupport.swift). NOBUILD=1 skips the build, KEEP=1 leaves the app open.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="${RUSHES_TEST_DIR:-/tmp/rushes-test}"
PAGE="${1:-review}"; OUT="${2:?usage: screenshot.sh <page> <out.png> [wait] [lang]}"
mkdir -p "$DIR/card" "$DIR/dest" "$DIR/data" "$DIR/debug"
pkill -f "Rushes Dev.app/Contents/MacOS/Rushes" 2>/dev/null || true; sleep 1
[ -n "${NOBUILD:-}" ] || VERSION=0.0.0 ./scripts/build-macos.sh debug >/dev/null
rm -rf "$DIR/debug" "$DIR/data"; mkdir -p "$DIR/debug" "$DIR/data"
env RUSHES_DATA_DIR="$DIR/data" RUSHES_DEBUG_DIR="$DIR/debug" RUSHES_DEBUG_CARD="$DIR/card" RUSHES_DEBUG_DEST="$DIR/dest" \
  RUSHES_DEBUG_PAGE="$PAGE" RUSHES_DEBUG_ACTIONS="${ACTIONS:-wait:1}" \
  "dist/Rushes Dev.app/Contents/MacOS/Rushes" -AppleLanguages "(${4:-nl})" >"$DIR/run.log" 2>&1 &
sleep "${3:-12}"
open "dist/Rushes Dev.app" >/dev/null 2>&1 || true   # brings it to the front, so the glass is drawn as in use
sleep 2
kill -USR1 "$(pgrep -f 'Rushes Dev.app/Contents/MacOS/Rushes' | head -1)"; sleep 2
ID="$(sed -n 2p "$DIR/debug/snapshot.txt" | awk '{print $1}')"
screencapture -x -o -l"$ID" "$OUT"
echo "$OUT"
[ -n "${KEEP:-}" ] || pkill -f "Rushes Dev.app/Contents/MacOS/Rushes" || true
