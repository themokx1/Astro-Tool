#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)"[[:space:]]*$/\1/p' Sources/AstroCore/Product/ProductInfo.swift)"
NOTES="docs/releases/v$VERSION.md"

if [ -z "$VERSION" ]; then
    echo "ERROR: ProductInfo.version could not be read." >&2
    exit 1
fi
if [ ! -s "$NOTES" ]; then
    echo "ERROR: required release notes are missing: $NOTES" >&2
    exit 1
fi
if ! rg --fixed-strings "# AstroTool $VERSION" "$NOTES" >/dev/null; then
    echo "ERROR: $NOTES does not identify AstroTool $VERSION." >&2
    exit 1
fi
if ! rg --fixed-strings "## [$VERSION]" CHANGELOG.md >/dev/null; then
    echo "ERROR: CHANGELOG.md has no $VERSION section." >&2
    exit 1
fi

echo "Release metadata check passed."
echo "Version $VERSION, CHANGELOG.md and $NOTES agree."
