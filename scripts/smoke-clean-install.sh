#!/bin/bash
# Launches the packaged app with an isolated UserDefaults suite and a real
# temporary empty library. It proves a clean machine can open a library and
# reach the first-scan state without inheriting personal defaults, without
# writing into the library itself, and without crashing during startup.
#
# V2 architecture notes (2026-08-20 rewrite):
# - Metadata and the index live OUTSIDE the library, under
#   ~/Library/Caches/AstroTool/Libraries/<id>/index.sqlite -- the old
#   in-library V1 database check no longer applies.
# - V2 auto-indexes (read-only) when a library opens, BY DESIGN -- the old
#   "must not scan without a user choice" invariant is gone with it. The
#   invariant that matters is preserved and checked: the LIBRARY directory
#   itself stays untouched.
# - The app-side hook is V2RootView's clean-install-smoke branch (the V1
#   shell keeps its own in AppState.markCleanInstallFirstScanVisible).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_EXECUTABLE="build/AstroTool.app/Contents/MacOS/AstroTool"
SMOKE_SUITE="io.github.themokx1.AstroTool.clean-install-smoke.$$"
SMOKE_LOG="$(mktemp -t AstroTool-clean-install)"
SMOKE_LIBRARY="$(mktemp -d -t AstroTool-empty-library)"
CACHE_LIBRARIES="$HOME/Library/Caches/AstroTool/Libraries"
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

for _ in {1..160}; do
    sleep 0.25
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
        echo "ERROR: AstroTool exited during clean-install startup." >&2
        sed -n '1,120p' "$SMOKE_LOG" >&2
        exit 1
    fi
    if [ "$(defaults read "$SMOKE_SUITE" cleanInstallSmokeReachedFirstScan 2>/dev/null || true)" = "1" ]; then
        break
    fi
done

if [ "$(defaults read "$SMOKE_SUITE" cleanInstallSmokeReachedFirstScan 2>/dev/null || true)" != "1" ]; then
    echo "ERROR: packaged app did not open the selected empty library." >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
fi

# The index must exist OUTSIDE the library, in the per-library cache home.
if ! find "$CACHE_LIBRARIES" -mindepth 2 -maxdepth 2 -name index.sqlite -print -quit 2>/dev/null | grep -q .; then
    echo "ERROR: no external index.sqlite appeared under $CACHE_LIBRARIES." >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
fi

# The library itself must stay untouched (at most the private .astro_tool
# metadata directory, which config writes may create later -- never content).
if find "$SMOKE_LIBRARY" -mindepth 1 -maxdepth 1 ! -name .astro_tool -print -quit | grep -q .; then
    echo "ERROR: first-run path created content inside the library." >&2
    exit 1
fi

if defaults export "$SMOKE_SUITE" - 2>/dev/null | grep -Eiq "/Volumes/images|Canon R8|SV220|100.?400"; then
    echo "ERROR: clean preferences contain a personal placeholder." >&2
    exit 1
fi
if grep -Eiq "fatal error|assertion failed|uncaught exception|segmentation fault" "$SMOKE_LOG"; then
    echo "ERROR: clean-install launch logged a crash signature." >&2
    sed -n '1,120p' "$SMOKE_LOG" >&2
    exit 1
fi

echo "Clean-install smoke passed: opened the empty library, external index created, library untouched, neutral preferences, stable launch."
