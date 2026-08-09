#!/bin/bash
# Builds AstroTool.app (SwiftUI) + the astrotool CLI, assembles the app
# bundle, ad-hoc signs it, packages a DMG and a CLI zip, installs the app to
# ~/Applications, and symlinks the CLI onto PATH.
# Run:  ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AstroTool"
APP_EXECUTABLE_TARGET="AstroToolApp"  # SwiftPM product name, distinct from
                                      # APP_NAME: on the default (case-
                                      # insensitive) macOS filesystem
                                      # "$BIN_PATH/AstroTool" would otherwise
                                      # silently resolve to the CLI binary
                                      # "astrotool" (same file, different case).
BUNDLE_ID="com.zoltanpalotai.astrotool"
SHORT_VERSION="0.15.1"
BUILD_VERSION="1"

BUILD="build"
APP="$BUILD/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"
CLI_STAGE="$BUILD/astrotool-cli"

echo "==> swift build -c release"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/$APP_EXECUTABLE_TARGET" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cp "$BIN_PATH/astrotool" "$APP/Contents/Resources/astrotool"
chmod +x "$APP/Contents/Resources/astrotool"

# App icon: use the committed icns if present; otherwise try to (re)generate
# it from icon/make_icon.swift when `swift` is available. Never fail the
# build if icon generation isn't possible -- the app just ships without a
# custom icon in that case.
if [ ! -f icon/AppIcon.icns ] && command -v swift >/dev/null 2>&1 && [ -f icon/make_icon.swift ]; then
    echo "==> icon/AppIcon.icns missing, generating via icon/make_icon.swift"
    swift icon/make_icon.swift || echo "WARNING: icon generation failed, continuing without a custom icon"
fi

ICON_LINE=""
if [ -f icon/AppIcon.icns ]; then
    cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_LINE="	<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
$ICON_LINE
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesign"
if ! codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
    echo "WARNING: codesign failed -- the app may refuse to launch (Gatekeeper)."
fi

if [ -z "${CI:-}" ]; then
    echo "==> Installing to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"
else
    echo "==> CI detected, skipping local install to $INSTALL_DIR"
fi

echo "==> Staging astrotool CLI ($CLI_STAGE)"
rm -rf "$CLI_STAGE"
mkdir -p "$CLI_STAGE"
cp "$BIN_PATH/astrotool" "$CLI_STAGE/astrotool"
chmod +x "$CLI_STAGE/astrotool"

if [ -z "${CI:-}" ]; then
    echo "==> Symlinking CLI onto PATH"
    mkdir -p "$BIN_DIR"
    ln -sf "$(pwd)/$CLI_STAGE/astrotool" "$BIN_DIR/astrotool"
    # NOTE: this points at build/astrotool-cli/astrotool inside the repo, not a
    # copy -- every `./build.sh` rerun refreshes the binary the symlink follows.
else
    echo "==> CI detected, skipping CLI symlink into $BIN_DIR"
fi

echo "==> Building DMG (drag-to-Applications installer)"
DMG_STAGE="$BUILD/dmg"
rm -rf "$DMG_STAGE" "$BUILD/$APP_NAME.dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$BUILD/$APP_NAME.dmg" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Building CLI zip for releases"
# CLI_STAGE (build/astrotool-cli/) contains only the `astrotool` binary.
# `ditto --sequesterRsrc` zips that directory's contents, so the archive has
# a single named entry: astrotool.zip -> astrotool (plus a __MACOSX/
# resource-fork sidecar, harmless). Unzip anywhere and run ./astrotool.
rm -f "$BUILD/astrotool.zip"
ditto -c -k --sequesterRsrc "$CLI_STAGE" "$BUILD/astrotool.zip"

echo ""
echo "Done."
echo "  App:  $INSTALL_DIR/$APP_NAME.app"
echo "  CLI:  $BIN_DIR/astrotool  (run 'astrotool --help')"
echo "  DMG:  $BUILD/$APP_NAME.dmg"
echo "  Zip:  $BUILD/astrotool.zip"
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "  NOTE: add $BIN_DIR to your PATH to use 'astrotool' directly." ;;
esac
