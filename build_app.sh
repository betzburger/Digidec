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
VERSION="$(sed -n 's/.*static let short = "\(.*\)".*/\1/p' "$DIR/Sources/App/AppVersion.swift")"
[ -n "$VERSION" ] || VERSION="0.98.0"

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

# Lokalisierungen (Deutsch und Englisch) direkt ins Bundle kopieren
if [ -d "$DIR/Sources/Resources/de.lproj" ]; then
    cp -r "$DIR/Sources/Resources/de.lproj" "$APP_BUNDLE/Contents/Resources/"
fi
if [ -d "$DIR/Sources/Resources/en.lproj" ]; then
    cp -r "$DIR/Sources/Resources/en.lproj" "$APP_BUNDLE/Contents/Resources/"
fi

if [ -d "$DIR/.build/release/Digidec_Digidec.bundle" ]; then
    cp -r "$DIR/.build/release/Digidec_Digidec.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# 2b. SDR-Treiberbibliotheken (RTL-SDR, HackRF, libusb) einbetten, damit Drittanbieter-Hardware "out-of-the-box" funktioniert
FW_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FW_DIR"
if [ -f "/opt/homebrew/lib/librtlsdr.dylib" ] && [ -f "/opt/homebrew/lib/libhackrf.dylib" ]; then
    echo "=== 2b. Bundling SDR Libraries (RTL-SDR, HackRF, libusb) into $FW_DIR ==="
    cp -L "/opt/homebrew/lib/librtlsdr.dylib" "$FW_DIR/librtlsdr.dylib"
    cp -L "/opt/homebrew/lib/libhackrf.dylib" "$FW_DIR/libhackrf.dylib"
    LIBUSB_PATH=$(otool -L /opt/homebrew/lib/librtlsdr.dylib | grep libusb | awk '{print $1}')
    if [ -f "$LIBUSB_PATH" ]; then
        cp -L "$LIBUSB_PATH" "$FW_DIR/libusb-1.0.dylib"
        chmod 755 "$FW_DIR"/*.dylib
        install_name_tool -id @rpath/libusb-1.0.dylib "$FW_DIR/libusb-1.0.dylib"
        install_name_tool -id @rpath/librtlsdr.dylib "$FW_DIR/librtlsdr.dylib"
        install_name_tool -id @rpath/libhackrf.dylib "$FW_DIR/libhackrf.dylib"
        install_name_tool -change "$LIBUSB_PATH" @loader_path/libusb-1.0.dylib "$FW_DIR/librtlsdr.dylib"
        install_name_tool -change "$LIBUSB_PATH" @loader_path/libusb-1.0.dylib "$FW_DIR/libhackrf.dylib" 2>/dev/null || true
        LIBUSB_HACK=$(otool -L /opt/homebrew/lib/libhackrf.dylib | grep libusb | awk '{print $1}')
        [ -n "$LIBUSB_HACK" ] && install_name_tool -change "$LIBUSB_HACK" @loader_path/libusb-1.0.dylib "$FW_DIR/libhackrf.dylib" 2>/dev/null || true
    fi
fi

echo "=== 3. Writing Info.plist ==="
cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>de</string>
    <key>CFBundleAllowMixedLocalizations</key>
    <true/>
    <key>CFBundleLocalizations</key>
    <array>
        <string>de</string>
        <string>en</string>
    </array>
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
    <string>0.101.1</string>
    <key>CFBundleVersion</key>
    <string>0.101.1</string>
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

echo "=== 4. Code Signing ==="
ENTITLEMENTS="$DIR/Digidec.entitlements"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$DEV_ID" ]; then
        SIGN_IDENTITY="$DEV_ID"
    else
        SIGN_IDENTITY="-"
    fi
fi

# Framework-Bibliotheken vorab einzeln signieren
FALLBACK_ADHOC=0
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    for f in "$APP_BUNDLE/Contents/Frameworks"/*.dylib; do
        [ -e "$f" ] || continue
        if [ "$SIGN_IDENTITY" = "-" ]; then
            codesign --force --sign - "$f"
        else
            if ! codesign --force --options runtime --sign "$SIGN_IDENTITY" "$f" 2>/dev/null; then
                echo "Notice: Developer ID sign failed on $f (keychain locked or non-interactive), falling back to ad-hoc signing."
                codesign --force --sign - "$f"
                FALLBACK_ADHOC=1
            fi
        fi
    done
fi

if [ "$SIGN_IDENTITY" = "-" ] || [ "$FALLBACK_ADHOC" = "1" ]; then
    echo "Signing Ad-hoc with Entitlements ($ENTITLEMENTS)..."
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
else
    echo "Signing with '$SIGN_IDENTITY', Hardened Runtime and Entitlements ($ENTITLEMENTS)..."
    if ! codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
        echo "Notice: Developer ID sign failed on app bundle, falling back to ad-hoc signing."
        codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
    fi
fi

echo "=== 5. Registering URL scheme digidec:// with Launch Services ==="
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"

echo "=== 6. Packaging Release Zip ==="
ZIP_NAME="Digidec-${VERSION}-macOS-arm64.zip"
rm -f "$DIR/$ZIP_NAME"
ditto -c -k --keepParent "$APP_BUNDLE" "$DIR/$ZIP_NAME"

echo "=== ERFOLGREICH: $APP_BUNDLE und $ZIP_NAME sind bereit! ==="
