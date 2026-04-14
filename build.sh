#!/bin/bash
set -euo pipefail

IDENTITY="Developer ID Application: Alex Linde (TN7Z2D3D5R)"
BUNDLE_ID="com.lambda-monitor"

write_plist() {
    local plist_path="$1"
    cat > "$plist_path" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LambdaMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.lambda-monitor</string>
    <key>CFBundleName</key>
    <string>Lambda Monitor</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>lambda</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
PLIST
}

MOCK_MODE=false
if [[ "${1:-}" == "--mock-api" ]]; then
    MOCK_MODE=true
    shift
fi

if [[ "${1:-}" == "release" ]]; then
    swift build -c release
    PRODUCT=".build/release/LambdaMonitor"
    codesign --force --options runtime --entitlements Entitlements.plist \
        --sign "$IDENTITY" "$PRODUCT"
    echo "Signed release: $PRODUCT"

    APP_DIR="$HOME/Applications/LambdaMonitor.app/Contents/MacOS"
    APP_RES="$HOME/Applications/LambdaMonitor.app/Contents/Resources"
    mkdir -p "$APP_DIR" "$APP_RES"
    cp "$PRODUCT" "$APP_DIR/LambdaMonitor"
    cp -R "Resources/lambda.icon" "$APP_RES/lambda.icon"
    write_plist "$HOME/Applications/LambdaMonitor.app/Contents/Info.plist"

    codesign --force --options runtime --entitlements Entitlements.plist \
        --sign "$IDENTITY" "$HOME/Applications/LambdaMonitor.app"
    echo "Installed: ~/Applications/LambdaMonitor.app"
    open "$HOME/Applications/LambdaMonitor.app"
else
    swift build "$@"

    APP=".build/debug/LambdaMonitor.app"
    APP_MACOS="$APP/Contents/MacOS"
    APP_RESOURCES="$APP/Contents/Resources"
    mkdir -p "$APP_MACOS" "$APP_RESOURCES"
    cp ".build/debug/LambdaMonitor" "$APP_MACOS/LambdaMonitor"
    cp -R "Resources/lambda.icon" "$APP_RESOURCES/lambda.icon"
    write_plist "$APP/Contents/Info.plist"

    codesign --force --options runtime --entitlements Entitlements.plist \
        --sign "$IDENTITY" "$APP"
    echo "Signed: $APP"
    if [[ "$MOCK_MODE" == true ]]; then
        echo "Running in mock API mode"
        exec "$APP_MACOS/LambdaMonitor" --mock-api
    else
        exec "$APP_MACOS/LambdaMonitor"
    fi
fi
