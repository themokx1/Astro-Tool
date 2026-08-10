#!/bin/bash
# Launches the packaged app with an isolated UserDefaults suite and a real
# temporary empty library. It proves a clean
# machine can render the selected-library/first-scan path without inheriting
# personal defaults, scanning automatically, or crashing during startup.
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
    rm -rf "$SMOKE_LIBRARY"
}
trap cleanup EXIT

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "ERROR: packaged app is missing; run ./build.sh first." >&2
    exit 1
fi

defaults delete "$SMOKE_SUITE" >/dev/null 2>&1 || true
ASTROTOOL_DEFAULTS_SUITE="$SMOKE_SUITE" \
ASTROTOOL_CLEAN_INSTALL_SMOKE_LIBRARY="$SMOKE_LIBRARY" \
    "$APP_EXECUTABLE" -ResetOnboarding >"$SMOKE_LOG" 2>&1 &
smoke_pid=$!

for _ in {1..80}; do
    sleep 0.25
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
        echo "ERROR: AstroTool exited during clean-install startup." >&2
        sed -n '1,120p' "$SMOKE_LOG" >&2
        exit 1
    fi
    if [ -f "$SMOKE_LIBRARY/.astro_tool/astrotool.sqlite" ] && \
       [ "$(defaults read "$SMOKE_SUITE" cleanInstallSmokeReachedFirstScan 2>/dev/null || true)" = "1" ]; then
        break
    fi
done

if [ ! -f "$SMOKE_LIBRARY/.astro_tool/astrotool.sqlite" ]; then
    echo "ERROR: packaged app did not open the selected empty library." >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
fi
if [ "$(defaults read "$SMOKE_SUITE" cleanInstallSmokeReachedFirstScan 2>/dev/null || true)" != "1" ]; then
    echo "ERROR: selected-library first-scan UI did not become visible." >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
fi
if find "$SMOKE_LIBRARY" -mindepth 1 -maxdepth 1 ! -name .astro_tool -print -quit | rg . >/dev/null; then
    echo "ERROR: first-run path created content outside its private metadata directory." >&2
    exit 1
fi
scan_count="$(sqlite3 "$SMOKE_LIBRARY/.astro_tool/astrotool.sqlite" \
    "SELECT COUNT(*) FROM runs WHERE kind = 'scan' AND finished_at IS NOT NULL;")"
if [ "$scan_count" != "0" ]; then
    echo "ERROR: first-run path scanned the empty library without a user choice." >&2
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

echo "Clean-install smoke passed: selected empty library, first-scan state, neutral preferences, stable launch."
