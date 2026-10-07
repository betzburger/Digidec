#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "=== 1. Building Digidec (Release) ==="
swift build -c release --manifest-cache none   # Package.swift prüft, ob Local/ existiert; ein alter Zwischenspeicher wüsste das nicht

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

# ICAO-Adressblöcke der Staaten (ADS-B, siehe Vendor/Adsb/UPSTREAM_ADSB.md)
mkdir -p "$APP_BUNDLE/Contents/Resources/ADSB"
cp "$DIR"/Resources/ADSB/* "$APP_BUNDLE/Contents/Resources/ADSB/"

mkdir -p "$APP_BUNDLE/Contents/Resources/Rtty"
cp "$DIR"/Resources/Rtty/* "$APP_BUNDLE/Contents/Resources/Rtty/"

mkdir -p "$APP_BUNDLE/Contents/Resources/Wefax"
cp "$DIR"/Resources/Wefax/* "$APP_BUNDLE/Contents/Resources/Wefax/"

# SondeHub-Startorte (CC BY-SA 2.0) als eingebauter Stand des Sonden-Plans
mkdir -p "$APP_BUNDLE/Contents/Resources/Sonde"
cp "$DIR"/Resources/Sonde/* "$APP_BUNDLE/Contents/Resources/Sonde/"

# OurAirports (gemeinfrei): Flughäfen für die ACARS-Karte
mkdir -p "$APP_BUNDLE/Contents/Resources/Airports"
cp "$DIR"/Resources/Airports/* "$APP_BUNDLE/Contents/Resources/Airports/"

# AD1C DXCC-Länderdatei (cty.dat) für Rufzeichen-Zuordnung
if [ -f "$DIR/Resources/cty.dat" ]; then
    cp "$DIR/Resources/cty.dat" "$APP_BUNDLE/Contents/Resources/cty.dat"
fi

# Lizenz (GPL-3.0-or-later), Quellen und Drittanbieter-Software: im Info-Fenster angezeigt, liegen auch lose im Bundle
cp "$DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$DIR/THIRD_PARTY.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY.md"

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
    <string>0.77.0</string>
    <key>CFBundleVersion</key>
    <string>0.77.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Peter Betz und Mitwirkende. Freie Software unter GPL-3.0-or-later.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Zugriff auf den Audio-Eingang des Funkgeräts (USB-Codec, USB-Soundkarte oder virtuelle Soundkarte), um das Empfangsaudio zu decodieren.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Digidec verbindet sich auf Wunsch mit einem rigctld (Hamlib) im lokalen Netz, um Frequenz und Mode des Funkgeräts zu lesen.</string>
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
