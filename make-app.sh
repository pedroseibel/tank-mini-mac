#!/bin/sh
# Builds "Tank Mini.app" (release) and the tankctl tool into ./dist.
# Needs only the Xcode Command Line Tools.
# The icon is drawn by Tools/make-icon.swift; to regenerate Resources/AppIcon.icns:
#   swift Tools/make-icon.swift /tmp/tankicon && iconutil -c icns /tmp/tankicon/AppIcon.iconset -o Resources/AppIcon.icns
set -e
cd "$(dirname "$0")"
swift build -c release --product TankMiniApp
swift build -c release --product tankctl
APP="dist/Tank Mini.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TankMiniApp "$APP/Contents/MacOS/TankMini"
cp .build/release/tankctl dist/tankctl
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/pt-BR.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tank Mini</string>
    <key>CFBundleDisplayName</key><string>Tank Mini</string>
    <key>CFBundleIdentifier</key><string>local.tankmini.editor</string>
    <key>CFBundleExecutable</key><string>TankMini</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
