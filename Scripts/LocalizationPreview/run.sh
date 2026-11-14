#!/bin/sh
# Render actual shared UI in an isolated, network-free executable. No installed app is modified.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-/tmp/nimbussync-localization-preview-evidence}
swift build --package-path "$HERE" --disable-sandbox
BIN=$(swift build --package-path "$HERE" --show-bin-path)
WORK=$(mktemp -d /tmp/nimbussync-localization-preview.XXXXXX)
APP="$WORK/LocalizationPreview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT"
cp "$BIN/LocalizationPreview" "$APP/Contents/MacOS/LocalizationPreview"
for resource in "$BIN"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
# Match the shipping Xcode targets: native SwiftUI controls resolve Bundle.main resources.
for language in en zh-Hans; do
    ditto "$HERE/../../Packages/NimbusSyncDomainKit/Sources/Resources/$language.lproj" "$APP/Contents/Resources/$language.lproj"
done
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib
import sys
identity = 'io.github.jorben.nimbussync.localization-preview'
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({
        'CFBundleIdentifier': identity,
        'CFBundleExecutable': 'LocalizationPreview',
        'CFBundleName': 'LocalizationPreview',
        'CFBundlePackageType': 'APPL',
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleLocalizations': ['en', 'zh-Hans'],
        'NimbusSyncBundleIdentifierBase': identity,
        'NimbusSyncAppGroupIdentifier': 'group.' + identity,
        'NimbusSyncDisplayName': 'NimbusSync Preview',
    }, stream)
PY
# Un-sandboxed, ad-hoc signed preview; it has no File Provider extension or shared production data.
codesign --force --deep --sign - "$APP"
exec "$APP/Contents/MacOS/LocalizationPreview" "$OUTPUT"
