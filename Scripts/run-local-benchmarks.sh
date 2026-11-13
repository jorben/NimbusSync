#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# This benchmark is deliberately local-only. It creates a temporary SQLite
# database and emits redacted timing JSON; it never contacts Cloudreve,
# opens Keychain credentials, or touches a File Provider Domain.
swift run -c release --disable-sandbox NimbusSyncBenchmarks
