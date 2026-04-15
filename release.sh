#!/bin/bash
set -euo pipefail

APP_NAME="LambdaMonitor"
BUNDLE_ID="com.lambda-monitor"
IDENTITY="Developer ID Application: Alex Linde (TN7Z2D3D5R)"
NOTARY_PROFILE="LambdaMonitor"
VERSION="1.0"
ICON_NAME="lambda"

STAGING=".build/release-staging"
APP_BUNDLE="$STAGING/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_TEMP="$STAGING/$APP_NAME-temp.dmg"
DMG_FINAL=".build/$DMG_NAME"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

write_plist() {
    local plist_path="$1"
    cat > "$plist_path" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Lambda Monitor</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>lambda</string>
    <key>CFBundleIconName</key>
    <string>lambda</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
PLIST
}

# ── Build ──────────────────────────────────────────────────────────────────────

echo "▸ Building release…"
swift build -c release

# ── Assemble .app bundle ───────────────────────────────────────────────────────

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
xcrun actool \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --output-partial-info-plist /dev/null \
    --app-icon "$ICON_NAME" \
    "$PWD/Resources/$ICON_NAME.icon"
write_plist "$APP_BUNDLE/Contents/Info.plist"

# ── Codesign (hardened runtime) ────────────────────────────────────────────────

echo "▸ Signing with hardened runtime…"
codesign --force --options runtime \
    --entitlements Entitlements.plist \
    --sign "$IDENTITY" \
    "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "  Signature verified."

# ── Create DMG ─────────────────────────────────────────────────────────────────

echo "▸ Creating DMG…"
rm -f "$DMG_TEMP" "$DMG_FINAL"

DMG_VOLUME="$APP_NAME"
DMG_SIZE=32  # MB, generous for a small app

hdiutil create \
    -size "${DMG_SIZE}m" \
    -fs HFS+ \
    -volname "$DMG_VOLUME" \
    "$DMG_TEMP"

MOUNT_DIR=$(hdiutil attach "$DMG_TEMP" -readwrite -noverify | grep "/Volumes/" | tail -1 | awk '{print $NF}')

cp -R "$APP_BUNDLE" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Style the DMG window
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 200, 900, 460}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "$APP_NAME.app" of container window to {120, 130}
        set position of item "Applications" of container window to {380, 130}
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet

hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL"

rm -f "$DMG_TEMP"
echo "  Created: $DMG_FINAL"

# ── Notarize ───────────────────────────────────────────────────────────────────

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "▸ Skipping notarization (--skip-notarize)."
else
    echo "▸ Notarizing (profile: $NOTARY_PROFILE)…"
    echo "  (Set up credentials once with: xcrun notarytool store-credentials $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG_FINAL" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "▸ Stapling notarization ticket…"
    xcrun stapler staple "$DMG_FINAL"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "✔ Release ready: $DMG_FINAL"
ls -lh "$DMG_FINAL"
