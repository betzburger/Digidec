#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Baut Digidec für Linux (Release) und installiert es samt Daten, Starter und Symbol.
#
#   ./build_linux.sh                      bauen und nach ~/.local installieren
#   ./build_linux.sh --prefix /usr/local  anderer Zielort (ggf. mit sudo)
#   ./build_linux.sh --no-install         nur bauen, Ergebnis unter dist/linux/
#   ./build_linux.sh --uninstall          wieder entfernen
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

PREFIX="$HOME/.local"
INSTALL=1
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n 4,10p "$0"; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

APP_ID="de.betz.digidec"
ICON_SIZES="16 32 48 64 128 256 512"
LIB="$PREFIX/lib/digidec"

if [ "$UNINSTALL" = 1 ]; then
    rm -rf "$LIB" "$PREFIX/bin/digidec" "$PREFIX/share/applications/$APP_ID.desktop"
    for s in $ICON_SIZES; do rm -f "$PREFIX/share/icons/hicolor/${s}x${s}/apps/$APP_ID.png"; done
    command -v update-desktop-database >/dev/null && update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
    echo "Digidec aus $PREFIX entfernt."
    exit 0
fi

echo "=== Voraussetzungen prüfen ==="
missing=()
command -v swift >/dev/null || missing+=("swift (Swift 6)")
for lib in gtk4 cairo pango pangocairo libpulse-simple sndfile; do
    pkg-config --exists "$lib" 2>/dev/null || missing+=("$lib (Entwicklungsdateien)")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Es fehlt: ${missing[*]}" >&2
    echo "Arch: pacman -S gtk4 libpulse libsndfile pango cairo    Debian/Ubuntu: apt install libgtk-4-dev libpulse-dev libsndfile1-dev" >&2
    exit 1
fi

echo "=== 1. Digidec bauen (Release) ==="
swift build -c release --product digidec-linux --manifest-cache none

OUT="$DIR/dist/linux"
STAGE="$OUT/lib/digidec"
rm -rf "$OUT"
mkdir -p "$STAGE" "$OUT/bin" "$OUT/share/applications"

echo "=== 2. Daten zusammenstellen ==="
cp "$DIR/.build/release/digidec-linux" "$STAGE/digidec"
strip "$STAGE/digidec" 2>/dev/null || true
# Gleiche Dateien wie im macOS-Bundle (build_app.sh); unter Linux liegen sie neben dem Programm
for d in Stations ADSB Rtty Wefax Sonde Airports; do
    mkdir -p "$STAGE/$d"
    cp "$DIR"/Resources/$d/* "$STAGE/$d/"
done
cp "$DIR/Resources/cty.dat" "$STAGE/cty.dat"
cp "$DIR/LICENSE" "$DIR/THIRD_PARTY.md" "$STAGE/"
cp -r "$DIR/Sources/Resources/de.lproj" "$DIR/Sources/Resources/en.lproj" "$STAGE/"
# Swift-Laufzeit, falls das Programm mit gemeinsamer Laufzeit gebunden wurde
if ldd "$STAGE/digidec" 2>/dev/null | grep -q 'libswiftCore'; then
    SWIFT_LIB="$(dirname "$(dirname "$(command -v swift)")")/lib/swift/linux"
    if [ -d "$SWIFT_LIB" ]; then
        mkdir -p "$STAGE/swift"
        ldd "$STAGE/digidec" | awk '/libswift|libFoundation|lib_Foundation|libdispatch|libBlocksRuntime|libicu/ {print $3}' | while read -r so; do
            [ -f "$so" ] && cp -L "$so" "$STAGE/swift/"
        done
    fi
fi

cat > "$OUT/bin/digidec" <<LAUNCH
#!/bin/sh
# Startet Digidec aus seinem Verzeichnis (Daten liegen neben dem Programm)
HERE="\$(cd "\$(dirname "\$(readlink -f "\$0")")/../lib/digidec" && pwd)"
[ -d "\$HERE/swift" ] && export LD_LIBRARY_PATH="\$HERE/swift\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$HERE/digidec" "\$@"
LAUNCH
chmod +x "$OUT/bin/digidec"

for s in $ICON_SIZES; do
    mkdir -p "$OUT/share/icons/hicolor/${s}x${s}/apps"
    cp "$DIR/Resources/Linux/icons/AppIcon-$s.png" "$OUT/share/icons/hicolor/${s}x${s}/apps/$APP_ID.png"
done
cat > "$OUT/share/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Digidec
GenericName=Digital Mode Decoder
Comment=Decoder für Digital- und Datenfunk (FT8, RTTY, DRM, ADS-B, AIS, APRS und viele mehr)
Comment[en]=Decoder for digital and data radio modes (FT8, RTTY, DRM, ADS-B, AIS, APRS and many more)
Exec=$PREFIX/bin/digidec %u
Icon=$APP_ID
Terminal=false
Categories=Network;HamRadio;
Keywords=radio;sdr;ft8;rtty;decoder;ham;amateur;
StartupWMClass=$APP_ID
MimeType=x-scheme-handler/digidec;
DESKTOP
command -v desktop-file-validate >/dev/null && desktop-file-validate "$OUT/share/applications/$APP_ID.desktop"

echo "Fertig gebaut: $OUT"

if [ "$INSTALL" = 1 ]; then
    echo "=== 3. Installieren nach $PREFIX ==="
    mkdir -p "$PREFIX"
    rm -rf "$LIB"
    cp -r "$OUT/lib" "$OUT/bin" "$OUT/share" "$PREFIX/"
    # Pfad im Starter bleibt relativ; Desktop-Datenbank auffrischen, falls vorhanden
    command -v update-desktop-database >/dev/null && update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
    # Aufträge `digidec://…` (wie die Commander am Mac) an Digidec leiten
    command -v xdg-mime >/dev/null && xdg-mime default "$APP_ID.desktop" x-scheme-handler/digidec 2>/dev/null || true
    echo "Digidec ist installiert: $PREFIX/bin/digidec"
    case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "Hinweis: $PREFIX/bin gehört nicht zu \$PATH." ;; esac
fi
