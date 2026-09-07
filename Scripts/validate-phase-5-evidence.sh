#!/bin/sh
set -eu

# Validate a redacted external acceptance report without turning an absent
# Apple/Cloudreve environment into a false pass. The report is intentionally
# data-only: this script never performs a network request or changes a Domain.

usage() {
    printf '%s\n' "usage: $0 <capability-report.json> [--require-go]" >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
REPORT=$1
MODE=${2:-}
[ -f "$REPORT" ] || { printf '%s\n' "missing evidence report: $REPORT" >&2; exit 2; }
case "$MODE" in
    ""|--require-go) ;;
    *) usage ;;
esac

command -v jq >/dev/null 2>&1 || {
    printf '%s\n' 'jq is required to validate external evidence' >&2
    exit 2
}

# Reports may contain only redacted versions, booleans, timings, capability
# states, and short evidence references. In particular, never check in a
# bearer credential, signed URL, remote URI, local path, or response body.
if rg -n -i \
    '(authorization|bearer[[:space:]]+[A-Za-z0-9._~+/=-]{8,}|access[_-]?token|refresh[_-]?token|signed[_-]?url|callback[_-]?secret|upload[_-]?urls|cloudreve://|https?://|file://|/Users/|/private/|/tmp/|response[_-]?body|password)' \
    "$REPORT" >/dev/null 2>&1; then
    printf '%s\n' 'external evidence contains a credential, URL, path, or response-body-like value' >&2
    exit 1
fi

required_gates='[
  "stable_entity_identity",
  "stable_root_identity",
  "complete_pagination",
  "cursor_pagination",
  "snapshot_safe_pagination",
  "conditional_content_write",
  "idempotent_create",
  "conditional_metadata_mutation",
  "content_version_semantics",
  "resumable_upload",
  "upload_completion_queryable",
  "provider_selection",
  "zero_byte_write",
  "delete_semantics",
  "trash_restore",
  "sse_resume",
  "account_identity",
  "refresh_rotation",
  "tls_proxy",
  "thumbnail",
  "native_conflict_copy",
  "fallback_conflict",
  "signed_finder",
  "performance",
  "long_run",
  "notarization",
  "clean_machine_upgrade"
]'

jq -e --argjson required "$required_gates" '
    (.schema_version == 1)
    and (.kind == "nimbussync.phase5.external-evidence")
    and (.candidate | type == "object")
    and ((.candidate.commit | type) == "string" and (.candidate.commit | test("^[0-9a-fA-F]{7,64}$")))
    and ((.candidate.checked_at | type) == "string" and (.candidate.checked_at | length) >= 10)
    and ((.candidate.macos | type) == "string" and (.candidate.macos | length) >= 2)
    and ((.candidate.architecture | type) == "string" and (.candidate.architecture == "arm64" or .candidate.architecture == "x86_64" or .candidate.architecture == "universal2"))
    and ((.candidate.cloudreve_version | type) == "string" and (.candidate.cloudreve_version | length) >= 1)
    and ((.candidate.provider | type) == "string" and (.candidate.provider | length) >= 1)
    and (.gates | type == "object")
    and ([$required[] as $name | select((.gates[$name] | type) != "object")] | length == 0)
    and ([
        $required[] as $name
        | select(
            (.gates[$name].status == "verified" or .gates[$name].status == "unsupported" or .gates[$name].status == "unverified")
            and ((.gates[$name].evidence | type) == "array")
            and ((.gates[$name].evidence | all(type == "string" and length > 0 and length <= 160)))
            and ((.gates[$name].duration_ms | type) == "number" and .gates[$name].duration_ms >= 0 and .gates[$name].duration_ms <= 86400000)
            and ((.gates[$name].status != "verified") or (.gates[$name].evidence | length > 0))
            and ((.gates[$name].status != "unsupported") or ((.gates[$name].notes // "") | type == "string" and length > 0))
        )
    ] | length == ($required | length))
    and ((.gates.native_conflict_copy.status // "unverified") != "verified")
' "$REPORT" >/dev/null || {
    printf '%s\n' 'external evidence schema or gate data is invalid' >&2
    exit 1
}

verified=$(jq '[.gates[] | select(.status == "verified")] | length' "$REPORT")
unsupported=$(jq '[.gates[] | select(.status == "unsupported")] | length' "$REPORT")
unverified=$(jq '[.gates[] | select(.status == "unverified")] | length' "$REPORT")
printf '%s\n' "validated external evidence: verified=$verified unsupported=$unsupported unverified=$unverified"

if [ "$MODE" = '--require-go' ] && [ "$unverified" -ne 0 ]; then
    printf '%s\n' 'release gate blocked: unverified external acceptance gates remain' >&2
    exit 1
fi

if [ "$MODE" = '--require-go' ]; then
    go_gates='["stable_entity_identity","stable_root_identity","complete_pagination","signed_finder","performance","long_run","notarization","clean_machine_upgrade"]'
    core_unverified=$(jq --argjson required "$go_gates" '[ $required[] as $name | select(.gates[$name].status != "verified") ] | length' "$REPORT")
    if [ "$core_unverified" -ne 0 ]; then
        printf '%s\n' 'release gate blocked: core signed/release evidence is not verified' >&2
        exit 1
    fi
fi
