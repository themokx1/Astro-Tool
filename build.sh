#!/bin/bash
# Build a distributable Universal AstroTool app and CLI without installing
# anything. Local installation is deliberately a separate explicit action:
# scripts/install-local.sh.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AstroTool"
APP_EXECUTABLE_TARGET="AstroToolApp"
PRODUCT_INFO_SOURCE="Sources/AstroCore/Product/ProductInfo.swift"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
CLI_STAGE="$BUILD/astrotool-cli"

read_product_value() {
    local key="$1"
    sed -n "s/^[[:space:]]*public static let ${key} = \"\([^\"]*\)\"[[:space:]]*$/\\1/p" "$PRODUCT_INFO_SOURCE"
}

BUNDLE_ID="$(read_product_value bundleIdentifier)"
SHORT_VERSION="$(read_product_value version)"
BUILD_VERSION="$(read_product_value build)"
SIGNING_IDENTITY="${ASTROTOOL_SIGNING_IDENTITY:--}"

if [ -z "$BUNDLE_ID" ] || [ -z "$SHORT_VERSION" ] || [ -z "$BUILD_VERSION" ]; then
    echo "ERROR: Could not read product identity from $PRODUCT_INFO_SOURCE" >&2
    exit 1
fi
if [ ! -f "icon/AppIcon.icns" ]; then
    echo "ERROR: icon/AppIcon.icns is required for a public build." >&2
    exit 1
fi

DMG="$BUILD/$APP_NAME-$SHORT_VERSION.dmg"
CLI_ZIP="$BUILD/astrotool-$SHORT_VERSION-macos-universal.zip"
CHECKSUMS="$BUILD/SHA256SUMS.txt"

SWIFT_BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
if [ "${ASTROTOOL_DISABLE_SWIFTPM_SANDBOX:-0}" = "1" ]; then
    SWIFT_BUILD_ARGS+=(--disable-sandbox)
fi

echo "==> Building Universal release (arm64 + x86_64)"
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP" "$CLI_STAGE" "$BUILD/dmg-stage" "$DMG" "$CLI_ZIP" "$CHECKSUMS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CLI_STAGE"

cp "$BIN_PATH/$APP_EXECUTABLE_TARGET" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_PATH/astrotool" "$APP/Contents/Resources/astrotool"
cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/astrotool"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>hu</string>
    <key>CFBundleLocalizations</key><array><string>hu</string><string>en</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 AstroTool contributors.</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

for binary in "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/Resources/astrotool"; do
    architectures="$(lipo -archs "$binary")"
    case " $architectures " in
        *" arm64 "*) : ;;
        *) echo "ERROR: $binary is missing arm64." >&2; exit 1 ;;
    esac
    case " $architectures " in
        *" x86_64 "*) : ;;
        *) echo "ERROR: $binary is missing x86_64." >&2; exit 1 ;;
    esac
done

echo "==> Signing app"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP/Contents/Resources/astrotool"
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/astrotool"
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Packaging drag-to-Applications DMG"
DMG_STAGE="$BUILD/dmg-stage"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Packaging standalone CLI"
cp "$APP/Contents/Resources/astrotool" "$CLI_STAGE/astrotool"
cp LICENSE "$CLI_STAGE/LICENSE"
chmod +x "$CLI_STAGE/astrotool"
COPYFILE_DISABLE=1 ditto -c -k --keepParent "$CLI_STAGE" "$CLI_ZIP"

echo "==> Writing SHA-256 checksums"
(
    cd "$BUILD"
    shasum -a 256 "$(basename "$DMG")" "$(basename "$CLI_ZIP")"
) > "$CHECKSUMS"

echo ""
echo "Build complete — nothing was installed."
echo "  App:       $APP"
echo "  DMG:       $DMG"
echo "  CLI:       $CLI_ZIP"
echo "  Checksums: $CHECKSUMS"
