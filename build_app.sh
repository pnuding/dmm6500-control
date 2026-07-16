#!/bin/bash
# Builds the release binary and wraps it into a standalone, double-clickable
# .app bundle. No Xcode project needed - built entirely via Swift Package
# Manager, mirroring udp3000s-control's build_app.sh.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DMM6500 Control.app"
APP="$DIR/$APP_NAME"
BIN_NAME="DMM6500Control"

echo "Building release binary..."
(cd "$DIR" && swift build -c release)
# Resolved, not hardcoded: the build output lands in an
# architecture-specific directory (arm64-apple-macosx vs
# x86_64-apple-macosx), so a hardcoded path breaks on Intel Macs.
BIN_PATH="$(cd "$DIR" && swift build -c release --show-bin-path)"

echo "Bundling $APP_NAME ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$DIR/icon.icns" "$APP/Contents/Resources/icon.icns"

# Localizable.strings live outside Sources/ (not an SPM target resource) so
# SPM never wraps them in its own nested Bundle.module resource bundle -
# they're copied straight into Contents/Resources/<locale>.lproj here,
# exactly like a classic Xcode-built app, so plain Bundle.main-based
# lookups (String(localized:), SwiftUI's Text/.help() etc.) find them
# without any special bundle plumbing in the source. Mirrors
# udp3000s-control's build_app.sh.
cp -R "$DIR/Localization/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.dmm6500.control</string>
    <key>CFBundleName</key>
    <string>DMM6500 Control</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>ca</string>
        <string>fr</string>
        <string>pt-PT</string>
        <string>nl</string>
        <string>it</string>
        <string>pl</string>
        <string>cs</string>
        <string>da</string>
        <string>sv</string>
        <string>nb</string>
        <string>fi</string>
        <string>zh-Hans</string>
        <string>ja</string>
        <string>pt-BR</string>
        <string>ko</string>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
du -sh "$APP"
