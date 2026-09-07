#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 <artifact.zip> [external-evidence.json]" >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT=$1
EVIDENCE=${2:-}
[ -f "$ARTIFACT" ] || { printf '%s\n' "missing artifact: $ARTIFACT" >&2; exit 2; }
if [ -n "$EVIDENCE" ] && [ ! -f "$EVIDENCE" ]; then
    printf '%s\n' "missing external evidence: $EVIDENCE" >&2
    exit 2
fi
if [ -n "$EVIDENCE" ]; then
    "$ROOT/Scripts/validate-phase-5-evidence.sh" "$EVIDENCE" >/dev/null
fi

command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is required' >&2; exit 2; }

signing_mode=${NIMBUSSYNC_SIGNING_MODE:-unknown}
case "$signing_mode" in
    signed|unsigned|unknown) ;;
    *)
        printf '%s\n' "unsupported NIMBUSSYNC_SIGNING_MODE: $signing_mode" >&2
        exit 2
        ;;
esac

artifact_hash=$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')
artifact_size=$(stat -f '%z' "$ARTIFACT")
commit=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    dirty=true
else
    dirty=false
fi

swift_version=$(swift --version 2>/dev/null | sed -n '1p')
xcode_version=$(xcodebuild -version | sed -n '1p')
rust_version=$(rustc --version | sed -n '1p')
cargo_version=$(cargo --version | sed -n '1p')

if [ -n "$EVIDENCE" ]; then
    evidence_kind=$(jq -r '.kind' "$EVIDENCE")
    evidence_verified=$(jq '[.gates[] | select(.status == "verified")] | length' "$EVIDENCE")
    evidence_unsupported=$(jq '[.gates[] | select(.status == "unsupported")] | length' "$EVIDENCE")
    evidence_unverified=$(jq '[.gates[] | select(.status == "unverified")] | length' "$EVIDENCE")
else
    evidence_kind=null
    evidence_verified=0
    evidence_unsupported=0
    evidence_unverified=0
fi

jq -n \
    --arg commit "$commit" \
    --argjson dirty "$dirty" \
    --arg artifact "$(basename "$ARTIFACT")" \
    --arg hash "$artifact_hash" \
    --argjson size "$artifact_size" \
    --arg swift "$swift_version" \
    --arg xcode "$xcode_version" \
    --arg rust "$rust_version" \
    --arg cargo "$cargo_version" \
    --arg signingMode "$signing_mode" \
    --arg evidenceKind "$evidence_kind" \
    --argjson verified "$evidence_verified" \
    --argjson unsupported "$evidence_unsupported" \
    --argjson unverified "$evidence_unverified" \
    '{
        schema_version: 1,
        kind: "nimbussync.release-manifest",
        candidate: {
            commit: $commit,
            working_tree_dirty: $dirty,
            signing_mode: $signingMode,
            artifact: {name: $artifact, sha256: $hash, size_bytes: $size},
            toolchain: {swift: $swift, xcode: $xcode, rust: $rust, cargo: $cargo}
        },
        external_evidence: {
            kind: (if $evidenceKind == "null" then null else $evidenceKind end),
            verified: $verified,
            unsupported: $unsupported,
            unverified: $unverified
        }
    }'
