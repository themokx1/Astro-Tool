#!/bin/bash
# Produces and verifies a signed, notarized public release. This script fails
# closed: a public artifact is never silently downgraded to ad-hoc signing.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to a valid Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

ASTROTOOL_SIGNING_IDENTITY="$DEVELOPER_ID_APPLICATION" ./build.sh

VERSION="$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)"[[:space:]]*$/\1/p' Sources/AstroCore/Product/ProductInfo.swift)"
DMG="build/AstroTool-$VERSION.dmg"
CLI_ZIP="build/astrotool-$VERSION-macos-universal.zip"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Notarizing standalone CLI archive"
xcrun notarytool submit "$CLI_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Rewriting checksums after stapling"
(
    cd build
    shasum -a 256 "$(basename "$DMG")" "$(basename "$CLI_ZIP")"
) > build/SHA256SUMS.txt

codesign --verify --deep --strict --verbose=2 build/AstroTool.app
spctl --assess --type execute --verbose=2 build/AstroTool.app

echo "Signed and notarized release is ready in build/."
