# Digidec unter Linux

Digidec läuft unter Linux mit derselben Swift-Quelle und derselben Oberfläche wie am Mac: Die SwiftUI-Ansichten aus `Sources/UI`
werden unverändert übersetzt, gegen eine eigene SwiftUI-Teilmenge auf GTK 4, Cairo und Pango (`Linux/UIKit`). Die Karte (Apple Karten am Mac)
zeigt unter Linux OpenStreetMap. Branch `linux-port`.

![FT8 unter Linux](images/linux-ft8-amber.png)

## Bauen und installieren

```bash
./build_linux.sh                       # Release bauen, nach ~/.local installieren (bin/, lib/digidec/, Starter, Symbol)
./build_linux.sh --prefix /usr/local   # anderer Zielort
./build_linux.sh --no-install          # nur bauen; Ergebnis unter dist/linux/
./build_linux.sh --uninstall
digidec                                # starten
```

Voraussetzungen zum Bauen (Namen für Arch; Debian/Fedora sinngemäß): Swift 6, `gtk4`, `pango`, `cairo`, `libpulse`, `libsndfile`, `libpng`, `libjpeg`.
Zur Laufzeit optional: `libfdk-aac` (xHE-AAC bei DRM, wird mit `dlopen` geladen), `pactl` (PulseAudio/PipeWire), `xdg-open`, `poppler` (`pdftotext`),
`libsecret` (`secret-tool` für Schlüssel), `libhackrf`, `librtlsdr`, SDRplay-API (SDR-Hardware, mit `dlopen` geladen).

Entwicklung:

```bash
swift build --product digidec-linux
DIGIDEC_MODULE=ft8 DIGIDEC_PLAY_FILE=aufnahme.wav .build/debug/digidec-linux
swift build -c release --product logic-tests && .build/release/logic-tests     # die Logiktests von macOS (7107 Prüfungen)
LT_ONLY=ft8,dab .build/release/logic-tests                                     # einzelne Gruppen
```

Umgebungsvariablen für Entwicklung und Schnappschüsse: `DIGIDEC_MODULE`, `DIGIDEC_PLAY_FILE`, `DIGIDEC_THEME` (night, amber, redNight, marine),
`DIGIDEC_MAPLAYOUT` (list, map, split), `DIGIDEC_MAP_VIEW="Breite,Länge,Spanne"`, dazu die modulbezogenen (`DIGIDEC_ADSB_FILE`, `DIGIDEC_AIS_NMEA`, …).
Ohne sichtbares Fenster zeichnen: `DIGIDEC_SNAPSHOT=bild.png` (mit `DIGIDEC_SNAPSHOT_AFTER`, `_WIDTH`, `_HEIGHT`) schreibt ein Bild und beendet das Programm;
`DIGIDEC_SCRIPT=ablauf.txt` spielt Bedienschritte ab (`wait`, `click x y`, `drag …`, `scroll …`, `key`, `shot datei.png`, `quit`).

## Aufbau

| Pfad | Inhalt |
|---|---|
| `Linux/UIKit/` | Eigene SwiftUI-Teilmenge (Modul `DigidecSwiftUI`, in den Quellen als `import SwiftUI`): Ansichtsbaum, Layout nach SwiftUI-Regeln, Zustand (`@State`, `@Binding`, `@ObservedObject`, `@AppStorage` …), Umgebung, Formen, Canvas mit `GraphicsContext` auf Cairo, Text mit Pango, Bedienelemente, Gesten, Menüs, Blätter, Popover, Bilder und Symbole, GTK-Fenster |
| `Linux/App/` | Programmstart: Fenster und Hooks (Übersetzung, Zwischenablage, Dateidialog), Stil der Eingabefelder |
| `Linux/Shims/…` | Ersatzmodule für Apple-Frameworks, damit `import Combine`, `import Accelerate` usw. im Quelltext unverändert bleiben |
| `Linux/excluded-files.txt` | Dateien, die unter Linux nicht übersetzt werden (macOS-Programmstart, Kartenbild-Export, Assistent-Bild) |
| `Sources/**/*+Linux.swift`, `#if canImport(…)` | Linux-Fassungen von Audio, Aufnahme, Wiedergabe, Geräteliste, Tastenbund, PDF, Karte, Empfangstext, QRZ |

Ersatzmodule: `os` (Sperren), `Accelerate` (vDSP: FFT, Skalarprodukte, Fenster …, an einer naiven DFT geprüft), `Combine` (OpenCombine plus
`CombineLatest`/`MergeMany`), `CryptoKit` (swift-crypto), `CoreGraphics` und `ImageIO` (Rasterbild, PNG/JPEG über libpng/libjpeg),
`UniformTypeIdentifiers`, `Network` (TCP über POSIX-Sockets), `SwiftUI` (die Teilmenge oben), `AVTestShim` (nur für die Logiktests).

Die Instrumente (S-Meter, Tasten) teilen sich den Zeichencode mit dem Mac (`Sources/Instruments/*Painter.swift`).

## Was unter Linux anders ist

- **Ton aus/ein:** PulseAudio-Schnittstelle (läuft mit PipeWire): `PullAudioOutput`, `VoicePlayer`, `LiveAudioCapture`. Geräteliste über `pactl`.
- **Datei-Wiedergabe und Aufnahme:** libsndfile (WAV, AIFF, FLAC, OGG, …).
- **xHE-AAC (DRM):** libfdk-aac, zur Laufzeit geladen. FFmpegs USAC-Decoder verarbeitet die Beispieldatei nicht (MPS212 mit SBR 8:3), FDK schon.
- **Karte:** OpenStreetMap-Kacheln (`tile.openstreetmap.org`, zwischengespeichert unter `~/.cache/digidec/tiles`), Nachtdarstellung durch Umfärben der Kacheln,
  Satellit und Hybrid mit Esri World Imagery. Punkte, Wege, Großkreise, Isobaren und Farbflächen wie am Mac; Bild speichern nach `~/Documents/Digidec/Maps`.
  Bitte die Nutzungsbedingungen der Kartendienste beachten (Quellenangabe steht auf der Karte).
- **QRZ.com:** öffnet den Standardbrowser (kein eingebetteter Web-Inhalt).
- **Lokalisierung:** `String(localized:)` liest `Localizable.strings` aus `<Sprache>.lproj` neben dem Programm; Sprache aus `DIGIDEC_LANG`, `LC_ALL`, `LANG`.
- **Ressourcen:** liegen neben dem Programm (`build_linux.sh` kopiert sie), wie am Mac im Bundle.
- **Bedienung:** Rechtsklick = Kontextmenü; Mausrad über dem Wasserfall stimmt ab, mit Alt wird gezoomt.

## Grenzen

- Markdown-Auszeichnung im KI-Assistenten und in der Info-Seite erscheint als reiner Text.
- Die Karte kennt keinen Kompass und keine Neigung; Hochzoomen endet bei Stufe 18.
- Logiktests: `FakeSDRconnect` (braucht WebSocket aus Network.framework) fehlt; die Gruppe `sonde` ist zeitempfindlich und schlägt bei hoher Last fehl.
- SDR-Hardware (HackRF, RTL-SDR, SDRplay) wurde unter Linux nicht mit Geräten geprüft; die Bibliotheken werden über übliche Pfade gesucht (`/usr/lib`, `/usr/local/lib`).
- Hann-Fenster (`vDSP_HANN_NORM`): Skalierung nach Apples Beschreibung nachgebildet, nicht am Mac verglichen.
- Vor dem Zusammenführen mit `main` am Mac bauen und die Logiktests laufen lassen (alle Änderungen liegen hinter `#if`).
