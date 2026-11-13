#!/bin/sh
# Packages an app bundle into a styled installer DMG (fixed 600x400 window, background
# with a drag-to-Applications hint). Requires dmgbuild: python3 -m pip install dmgbuild
#
# Usage: Scripts/make-dmg.sh <path/to/App.app> <output.dmg> [volume name]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${1:?usage: make-dmg.sh <App.app> <output.dmg> [volume name]}
DMG=${2:?usage: make-dmg.sh <App.app> <output.dmg> [volume name]}
VOLUME_NAME=${3:-$(basename "$APP" .app)}
DMGBUILD=${DMGBUILD:-dmgbuild}

command -v "$DMGBUILD" >/dev/null 2>&1 || {
    printf '%s\n' "required tool not found: $DMGBUILD (python3 -m pip install dmgbuild)" >&2
    exit 127
}
[ -d "$APP" ] || { printf '%s\n' "app bundle not found: $APP" >&2; exit 1; }

rm -f "$DMG"
"$DMGBUILD" \
    -s "$ROOT/Scripts/dmg-settings.py" \
    -D app="$APP" \
    -D background="$ROOT/Design/DMG/background.png" \
    "$VOLUME_NAME" "$DMG"
