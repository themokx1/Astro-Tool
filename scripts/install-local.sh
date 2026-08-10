#!/bin/bash
# Explicitly installs the already-built app. If an older installation exists,
# it is moved to a timestamped backup in /private/tmp before replacement.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_APP="build/AstroTool.app"
DESTINATION_APP="/Applications/AstroTool.app"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_APP="/private/tmp/AstroTool.previous.$TIMESTAMP.app"

if [ ! -d "$SOURCE_APP" ]; then
    echo "ERROR: build/AstroTool.app is missing. Run ./build.sh first." >&2
    exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"

if [ -e "$DESTINATION_APP" ]; then
    echo "==> Preserving the previous installation at $BACKUP_APP"
    mv "$DESTINATION_APP" "$BACKUP_APP"
fi

echo "==> Installing AstroTool in /Applications"
if ! ditto "$SOURCE_APP" "$DESTINATION_APP"; then
    if [ -e "$BACKUP_APP" ] && [ ! -e "$DESTINATION_APP" ]; then
        mv "$BACKUP_APP" "$DESTINATION_APP"
    fi
    echo "ERROR: Installation failed; the previous app was restored when possible." >&2
    exit 1
fi

echo "Installed: $DESTINATION_APP"
if [ -e "$BACKUP_APP" ]; then
    echo "Previous version: $BACKUP_APP"
fi
