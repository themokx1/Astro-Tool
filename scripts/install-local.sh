#!/bin/bash
# Explicitly installs the already-built app. If an older installation exists,
# it is moved to a timestamped backup in /private/tmp before replacement.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_APP="build/AstroTool.app"
DESTINATION_APP="/Applications/AstroTool.app"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_APP="/private/tmp/AstroTool.previous.$TIMESTAMP.app"
FAILED_APP="/private/tmp/AstroTool.failed-install.$TIMESTAMP.app"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

restore_previous_app() {
    FAILURE_RESULT="no previous installation existed"
    if [ -e "$DESTINATION_APP" ]; then
        echo "==> Preserving the failed installation at $FAILED_APP"
        mv "$DESTINATION_APP" "$FAILED_APP"
    fi
    if [ -e "$BACKUP_APP" ]; then
        mv "$BACKUP_APP" "$DESTINATION_APP"
        FAILURE_RESULT="the previous app was restored"
    fi
    echo "ERROR: Installation failed; $FAILURE_RESULT." >&2
    exit 1
}

verify_installed_app() {
    local source_plist="$SOURCE_APP/Contents/Info.plist"
    local installed_plist="$DESTINATION_APP/Contents/Info.plist"
    local expected_version expected_build expected_identifier architectures cli_version
    expected_version="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$source_plist")"
    expected_build="$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$source_plist")"
    expected_identifier="$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$source_plist")"
    test "$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$installed_plist")" = "$expected_version"
    test "$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$installed_plist")" = "$expected_build"
    test "$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$installed_plist")" = "$expected_identifier"
    codesign --verify --deep --strict "$DESTINATION_APP"
    for binary in "$DESTINATION_APP/Contents/MacOS/AstroTool" "$DESTINATION_APP/Contents/Resources/astrotool"; do
        architectures="$(lipo -archs "$binary")"
        case " $architectures " in *" arm64 "*) : ;; *) return 1 ;; esac
        case " $architectures " in *" x86_64 "*) : ;; *) return 1 ;; esac
    done
    cli_version="$($DESTINATION_APP/Contents/Resources/astrotool --version)"
    case "$cli_version" in *"$expected_version"*) : ;; *) return 1 ;; esac
}

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
    restore_previous_app
fi

echo "==> Verifying installed app"
if ! verify_installed_app; then
    restore_previous_app
fi

echo "Installed: $DESTINATION_APP"
if [ -e "$BACKUP_APP" ]; then
    echo "Previous version: $BACKUP_APP"
fi
