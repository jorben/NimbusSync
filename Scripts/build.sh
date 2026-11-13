#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/Config/build.local.sh"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
CONFIGURATION=${CONFIGURATION:-${NIMBUSSYNC_CONFIGURATION:-Debug}}
BUILD_ROOT=${BUILD_ROOT:-${NIMBUSSYNC_APP_BUILD_ROOT:-"$ROOT/.build/ci"}}
DIST_DIR=${DIST_DIR:-${NIMBUSSYNC_DIST_DIR:-"$ROOT/Dist"}}
VERSION=${VERSION:-${NIMBUSSYNC_VERSION:-0.1.0}}
SIGNING_MODE=${SIGNING_MODE:-${NIMBUSSYNC_SIGNING_MODE:-unsigned}}
# platform=macOS builds only the host architecture; CI passes generic/platform=macOS for a
# universal (arm64 + x86_64) bundle.
DESTINATION=${DESTINATION:-${NIMBUSSYNC_DESTINATION:-platform=macOS}}
# Optional version stamping: CFBundleShortVersionString and CFBundleVersion. Unset keeps the
# values from Config/*.xcconfig and the project.
MARKETING_VERSION=${MARKETING_VERSION:-${NIMBUSSYNC_MARKETING_VERSION:-}}
BUILD_NUMBER=${BUILD_NUMBER:-${NIMBUSSYNC_BUILD_NUMBER:-}}
# Optional Xcode compilation cache (LLVM CAS) directory. CI restores and saves it between runs;
# cache keys include the derived data path, so keep BUILD_ROOT stable for hits.
COMPILATION_CACHE_PATH=${COMPILATION_CACHE_PATH:-${NIMBUSSYNC_COMPILATION_CACHE_PATH:-}}

# The App Group, Keychain group and bundle IDs come from Config/<Configuration>.xcconfig: Debug
# builds use the `.dev` identity, Release the shipping one. A single override for every
# configuration would make the Dev build share (and corrupt) the Release app's data.
if [ -n "${APP_GROUP_IDENTIFIER:-}${NIMBUSSYNC_APP_GROUP_IDENTIFIER:-}" ]; then
    printf '%s\n' "APP_GROUP_IDENTIFIER/NIMBUSSYNC_APP_GROUP_IDENTIFIER is no longer supported; the App Group is set per configuration in Config/*.xcconfig. Remove it from Config/build.local.sh or the environment." >&2
    exit 2
fi

# The bundle name follows the identity (Config/<Configuration>.xcconfig NIMBUSSYNC_APP_NAME): macOS
# lists apps by bundle name in Login Items and System Settings' File Providers, so the Dev build
# is NimbusSyncDev.app and never shows up as a second "NimbusSync".
case "$CONFIGURATION" in
    Debug) CONFIG_KEY=DEBUG; APP_NAME=NimbusSyncDev ;;
    Release) CONFIG_KEY=RELEASE; APP_NAME=NimbusSync ;;
    *)
        printf '%s\n' "unsupported CONFIGURATION: $CONFIGURATION" >&2
        exit 2
        ;;
esac

# `build.sh --print-app-path` resolves the configuration exactly as a build would (local config,
# environment) and prints where the app will land, so `make dev` can launch the right bundle.
if [ "${1:-}" = --print-app-path ]; then
    printf '%s\n' "$DIST_DIR/$APP_NAME.app"
    exit 0
fi

# Signing value for this configuration: NIMBUSSYNC_<DEBUG|RELEASE>_<NAME>, then NIMBUSSYNC_<NAME>,
# then the legacy NIMBUSSYNC_<NAME>_UUID. Debug and Release are different App IDs, so each needs its
# own provisioning profiles (and Debug, with File Provider testing mode, a development identity).
# CONFIG_KEY and every NAME are fixed literals above and below, so the eval sees no user input.
signing_value() {
    eval "signing_value_result=\${NIMBUSSYNC_${CONFIG_KEY}_$1:-\${NIMBUSSYNC_$1:-\${NIMBUSSYNC_$1_UUID:-}}}"
    printf '%s' "$signing_value_result"
}

CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:-${CI_SIGNING_IDENTITY:-$(signing_value CODE_SIGN_IDENTITY)}}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s\n' "required tool not found: $1 ($2)" >&2
        exit 127
    }
}

# Fail closed: rg exits 0 when a forbidden pattern matches, 1 when the tree is
# clean, and >=2 on any error (bad pattern, missing or unreadable path). Only a
# clean "no match" may pass; every other status must stop the build.
scan_forbidden() {
    scan_message=$1
    shift
    scan_status=0
    rg "$@" || scan_status=$?
    case "$scan_status" in
        0)
            printf '%s\n' "$scan_message" >&2
            return 1
            ;;
        1)
            return 0
            ;;
        *)
            printf '%s\n' "scan could not complete (rg exit $scan_status): $scan_message" >&2
            return 1
            ;;
    esac
}

secret_scan() {
    # File names only: a matching line would copy the credential into the build log.
    scan_forbidden 'secret scan found a credential-like value' \
        --files-with-matches \
        --hidden \
        --glob '!Artifacts/**' \
        --glob '!.git/**' \
        --glob '!*.lock' \
        --glob '!Scripts/build.sh' \
        "(Bearer[[:space:]]+[A-Za-z0-9_-]{12,}|refresh_token[\"=:[:space:]]+[\"']?[A-Za-z0-9_-]{12,}[\"']?|signedUrl|signed_url)" \
        "$ROOT"
}

release_scan() {
    scan_forbidden 'release scan found a forbidden entitlement or transport exception' \
        -n \
        'com\.apple\.developer\.fileprovider\.testing-mode|NSAllowsArbitraryLoads|allowInsecure|http://localhost|http://127\.0\.0\.1' \
        "$ROOT/Config/Release.xcconfig" \
        "$ROOT/Config/NimbusSyncRelease.entitlements" \
        "$ROOT/Config/NimbusSyncFileProviderRelease.entitlements" \
        "$ROOT/Config/NimbusSyncFileProviderUI.entitlements" \
        "$ROOT/NimbusSync.xcodeproj"
}

artifact_scan() {
    [ -d "$ROOT/Artifacts" ] || return 0
    scan_forbidden 'artifact scan found credential-like output' \
        --files-with-matches \
        --hidden \
        '(access_token|refresh_token|callback_secret|upload_urls|signed_url|signedUrl|Authorization)' \
        "$ROOT/Artifacts"
}

# Notarization rejects a Release bundle without the hardened runtime. An unmatched
# PlugIns glob stays literal, so codesign fails on it and the build stops.
require_hardened_runtime() {
    for bundle in "$1" "$1"/Contents/PlugIns/*.appex; do
        if ! codesign -d --verbose=2 "$bundle" 2>&1 | grep -q 'flags=.*runtime'; then
            printf '%s\n' "signed bundle lacks the hardened runtime: $(basename "$bundle")" >&2
            exit 1
        fi
    done
}

external_evidence_scan() {
    if [ -n "${NIMBUSSYNC_EXTERNAL_EVIDENCE:-}" ]; then
        case "${NIMBUSSYNC_REQUIRE_GO:-0}" in
            1|true|TRUE)
                "$ROOT/Scripts/validate-phase-5-evidence.sh" "$NIMBUSSYNC_EXTERNAL_EVIDENCE" --require-go
                ;;
            0|false|FALSE|'')
                "$ROOT/Scripts/validate-phase-5-evidence.sh" "$NIMBUSSYNC_EXTERNAL_EVIDENCE"
                ;;
            *)
                printf '%s\n' "unsupported NIMBUSSYNC_REQUIRE_GO: ${NIMBUSSYNC_REQUIRE_GO}" >&2
                return 2
                ;;
        esac
    fi
}

require_tool rg 'install with: brew install ripgrep'
require_tool git 'install Xcode Command Line Tools'
secret_scan
release_scan
artifact_scan
external_evidence_scan
git --no-pager -C "$ROOT" diff --check

mkdir -p "$BUILD_ROOT" "$DIST_DIR"

set -- xcodebuild \
    -project "$ROOT/NimbusSync.xcodeproj" \
    -scheme NimbusSync \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$BUILD_ROOT/derived" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/source-packages" \
    -packageCachePath "$BUILD_ROOT/package-cache" \
    -skipPackageUpdates \
    build

[ -z "$MARKETING_VERSION" ] || set -- "$@" MARKETING_VERSION="$MARKETING_VERSION"
[ -z "$BUILD_NUMBER" ] || set -- "$@" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
[ -z "$COMPILATION_CACHE_PATH" ] || set -- "$@" \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    COMPILATION_CACHE_CAS_PATH="$COMPILATION_CACHE_PATH"
# xcodebuild's autogenerated scheme turns on code coverage for every configuration, which
# instruments Release binaries (-profile-generate, ~35% larger, writes default.profraw at
# runtime). Only command-line settings also reach the Swift package targets.
if [ "$CONFIGURATION" = Release ]; then
    set -- "$@" ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
fi

case "$SIGNING_MODE" in
    unsigned)
        set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        ;;
    signed)
        DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-${NIMBUSSYNC_DEVELOPMENT_TEAM:-}}
        NIMBUSSYNC_APP_PROFILE=$(signing_value APP_PROFILE)
        NIMBUSSYNC_FILE_PROVIDER_PROFILE=$(signing_value FILE_PROVIDER_PROFILE)
        NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE=$(signing_value FILE_PROVIDER_UI_PROFILE)
        : "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM or NIMBUSSYNC_DEVELOPMENT_TEAM is required for a signed build}"
        : "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required for a signed build}"
        : "${NIMBUSSYNC_APP_PROFILE:?NIMBUSSYNC_APP_PROFILE is required for a signed build}"
        : "${NIMBUSSYNC_FILE_PROVIDER_PROFILE:?NIMBUSSYNC_FILE_PROVIDER_PROFILE is required for a signed build}"
        : "${NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE:?NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE is required for a signed build}"
        set -- "$@" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_ALLOWED=YES \
            CODE_SIGNING_REQUIRED=YES \
            CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
            DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
            NIMBUSSYNC_APP_PROFILE="$NIMBUSSYNC_APP_PROFILE" \
            NIMBUSSYNC_FILE_PROVIDER_PROFILE="$NIMBUSSYNC_FILE_PROVIDER_PROFILE" \
            NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE="$NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE"
        ;;
    *)
        printf '%s\n' "unsupported SIGNING_MODE: $SIGNING_MODE" >&2
        exit 2
        ;;
esac

app="$BUILD_ROOT/derived/Build/Products/$CONFIGURATION/$APP_NAME.app"
# Rebuild the app bundle every time so it never keeps an extension embedded by an
# earlier incremental build. Xcode can skip re-copying an .appex whose only change is
# its signature (for example a newly enabled hardened runtime), which leaves the old
# signature inside a freshly signed app. Compiled objects stay incremental.
rm -rf "$app"

"$@"

[ -d "$app" ] || { printf '%s\n' "missing built app: $app" >&2; exit 1; }

if [ "$SIGNING_MODE" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$app"
    if [ "$CONFIGURATION" = Release ]; then
        require_hardened_runtime "$app"
    fi
fi

# Copy the bundle under the name it was built and signed with: NimbusSync.app (Release) or
# NimbusSyncDev.app (Debug). Renaming a signed .app after codesign breaks the bundle-level
# signature even when the Mach-O executable still carries a valid signature.
artifact="$DIST_DIR/$APP_NAME.app"
archive="$DIST_DIR/$APP_NAME-$VERSION.zip"
rm -rf "$artifact" "$archive" "$archive.sha256"
ditto "$app" "$artifact"
if [ "$SIGNING_MODE" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$artifact"
fi
ditto -c -k --sequesterRsrc --keepParent "$artifact" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

printf '%s\n' "built: $artifact"
printf '%s\n' "archive: $archive"
