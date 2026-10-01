#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "=== 1. Building Digidec (Release) ==="
swift build -c release

APP_NAME="Digidec"
APP_BUNDLE="$DIR/$APP_NAME.app"

echo "=== 2. Creating macOS App Bundle: $APP_BUNDLE ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$DIR/.build/release/Digidec" "$APP_BUNDLE/Contents/MacOS/Digidec"
chmod +x "$APP_BUNDLE/Contents/MacOS/Digidec"

if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Stationslisten für SYNOP- und NAVTEX-Decoder (aus fldigi 4.2.13, siehe Vendor/Fldigi/UPSTREAM_SYNOP.md)
mkdir -p "$APP_BUNDLE/Contents/Resources/Stations"
cp "$DIR"/Resources/Stations/* "$APP_BUNDLE/Contents/Resources/Stations/"

echo "=== 3. Writing Info.plist ==="
cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Digidec</string>
    <key>CFBundleIdentifier</key>
    <string>com.peterbetz.digidec</string>
    <key>CFBundleName</key>
    <string>Digidec</string>
    <key>CFBundleDisplayName</key>
    <string>Digidec</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.13.1</string>
    <key>CFBundleVersion</key>
    <string>0.13.1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Zugriff auf den USB-Audio-Codec von IC-PCR1500 und FT-991A (oder eine virtuelle Soundkarte), um das Empfangsaudio zu decodieren.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.peterbetz.digidec.decode</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>digidec</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "=== 4. Ad-hoc Code Signing ==="
codesign --force --deep --sign - "$APP_BUNDLE"

echo "=== 5. Registering URL scheme digidec:// with Launch Services ==="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"

echo "=== ERFOLGREICH: $APP_BUNDLE ist bereit! ==="
