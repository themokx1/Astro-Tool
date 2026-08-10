#!/bin/bash
# Launches the packaged app with an isolated UserDefaults suite. It proves a
# clean machine can reach the neutral first-run surface without inheriting a
# real library bookmark or crashing during startup.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_EXECUTABLE="build/AstroTool.app/Contents/MacOS/AstroTool"
SMOKE_SUITE="io.github.themokx1.AstroTool.clean-install-smoke.$$"
SMOKE_LOG="$(mktemp -t AstroTool-clean-install)"
SMOKE_LIBRARY="$(mktemp -d -t AstroTool-empty-library)"
smoke_pid=""

cleanup() {
    if [ -n "$smoke_pid" ] && kill -0 "$smoke_pid" 2>/dev/null; then
        kill "$smoke_pid"
        wait "$smoke_pid" 2>/dev/null || true
    fi
    defaults delete "$SMOKE_SUITE" >/dev/null 2>&1 || true
    rm -f "$SMOKE_LOG"
    rmdir "$SMOKE_LIBRARY" 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "ERROR: packaged app is missing; run ./build.sh first." >&2
    exit 1
fi

defaults delete "$SMOKE_SUITE" >/dev/null 2>&1 || true
ASTROTOOL_DEFAULTS_SUITE="$SMOKE_SUITE" "$APP_EXECUTABLE" -ResetOnboarding >"$SMOKE_LOG" 2>&1 &
smoke_pid=$!

for _ in {1..24}; do
    sleep 0.25
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
        echo "ERROR: AstroTool exited during clean-install startup." >&2
        sed -n '1,120p' "$SMOKE_LOG" >&2
        exit 1
    fi
done

if defaults read "$SMOKE_SUITE" rootBookmark >/dev/null 2>&1; then
    echo "ERROR: clean install created a library bookmark without a user choice." >&2
    exit 1
fi
if find "$SMOKE_LIBRARY" -mindepth 1 -print -quit | rg . >/dev/null; then
    echo "ERROR: clean install touched an unselected empty library." >&2
    exit 1
fi
if defaults export "$SMOKE_SUITE" - 2>/dev/null | rg -i "/Volumes/images|Canon R8|SV220|100.?400"; then
    echo "ERROR: clean preferences contain a personal placeholder." >&2
    exit 1
fi
if rg -i "fatal error|assertion failed|uncaught exception|segmentation fault" "$SMOKE_LOG"; then
    echo "ERROR: clean-install launch logged a crash signature." >&2
    exit 1
fi

echo "Clean-install smoke passed: neutral preferences, no inherited library, stable launch."
