#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if swift test --no-parallel --filter MobilePackageSmokeTests; then
    echo "SMOKE OK: mobile package round trip left the source library manifest bit-identical"
else
    echo "SMOKE FAILED: mobile package round trip" >&2
    exit 1
fi
