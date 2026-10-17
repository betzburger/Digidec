# Digidec unter Linux

Stand: Kern und Logiktests laufen unter Linux. Das Frontend (GTK 4 über SwiftCrossUI, Instrumente und Tasten mit Cairo) zeigt als erstes Modul FT8 mit dem echten `DigidecState`: Kopfzeile, Modulleiste, Wasserfall, Bandaktivität, S-Meter, Zyklus, Einstellungen (`docs/linux/images/linux-ft8-amber.png`). Branch `linux-port`.

## Bauen und testen

```bash
swift build --product digidec-linux            # Kern + Frontend (GTK-Fenster)
DIGIDEC_MODULE=ft8 DIGIDEC_PLAY_FILE=aufnahme.wav .build/debug/digidec-linux   # Modul wählen, Datei statt Live-Eingang
DIGIDEC_THEME=amber .build/debug/digidec-linux  # Theme: night, amber, redNight, marine
swift build -c release --product logic-tests   # die Logiktests von macOS (7107 Prüfungen)
LT_ONLY=ft8,dab .build/release/logic-tests     # einzelne Gruppen; ohne LT_ONLY alle
```

Unter Linux bauen `swift build` und `swift test` das Ziel `DigidecCore` (alles aus `Sources/` außer den Dateien in
`Linux/ui-files.txt`, also ohne die macOS-Oberfläche). `Package.swift` verhält sich unter macOS wie bisher.

Bauabhängigkeiten (Arch/Fedora/Debian-Namen sinngemäß): `libpulse`, `libsndfile`, `libpng`, `libjpeg`, `poppler` (pdftotext, zur Laufzeit),
`libsecret` (secret-tool, zur Laufzeit, optional). Zur Laufzeit optional: `libfdk-aac` (xHE-AAC für DRM, wird mit `dlopen` geladen),
`pactl` (PulseAudio/PipeWire), `xdg-open`.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `Linux/Shims/…` | Ersatzmodule für Apple-Frameworks, damit `import Combine`, `import Accelerate` usw. im Quelltext unverändert bleiben |
| `Linux/ui-files.txt` | Dateien der macOS-Oberfläche, die unter Linux nicht übersetzt werden |
| `Linux/App/` | Linux-Frontend: `AppModel` (Brücke zu `DigidecState`), `Screens` (SwiftCrossUI-Ansichten, bisher FT8), `Canvases`/`OriginalChrome` (Zeichnen), `CairoCanvas` (Zeichenfläche als GTK-Widget), `Kit` (RadioCard …), `Style` (GTK-CSS aus dem Theme) |
| `Sources/**/*+Linux.swift`, `#if canImport(…)` | Linux-Fassungen von Audio, Aufnahme, Wiedergabe, Geräteliste, Tastenbund, PDF |

Ersatzmodule: `os` (Sperren), `Accelerate` (vDSP: FFT, Skalarprodukte, Fenster …, an einer naiven DFT geprüft), `Combine` (OpenCombine plus
`CombineLatest`/`MergeMany`), `CryptoKit` (swift-crypto), `CoreGraphics` und `ImageIO` (Rasterbild, PNG/JPEG über libpng/libjpeg),
`UniformTypeIdentifiers`, `Network` (TCP über POSIX-Sockets für den Web-Server), `SwiftUI` (nur Platzhalter für `ObservableObject`/`@Published`
in den Zustandsklassen), `AVTestShim` (nur für die Logiktests).

## Was unter Linux anders ist

- **Ton aus/ein:** PulseAudio-Schnittstelle (läuft mit PipeWire): `PullAudioOutput`, `VoicePlayer`, `LiveAudioCapture`. Geräteliste über `pactl`.
- **Datei-Wiedergabe und Aufnahme:** libsndfile (WAV, AIFF, FLAC, OGG, …).
- **xHE-AAC (DRM):** libfdk-aac, zur Laufzeit geladen. FFmpegs USAC-Decoder verarbeitet die Beispieldatei nicht (MPS212 mit SBR 8:3), FDK schon.
- **Lokalisierung:** `String(localized:)` liest `Localizable.strings` aus `Resources/<Sprache>.lproj`; Sprache aus `DIGIDEC_LANG`, `LC_ALL`, `LANG`.
- **Ressourcen:** wie am Mac neben dem Programm (`Bundle.main.resourceURL`); ein Installationsschritt muss `Sources/Resources` dorthin kopieren.
- **fldigi:** `abs()` auf `double` im CW-Empfänger wurde mit libstdc++ zu `int` (siehe `Vendor/Fldigi/UPSTREAM_CW.md`).

## Offen

- Oberfläche: siehe `Linux/ui-files.txt` (70 Dateien, rund 27 000 Zeilen) und `ChannelHub+Linux.swift` (zweite Fassung der Kanalerzeugung ohne Ansichten,
  bei Änderungen an `ChannelHub.swift` mitführen).
- `Assistant`: Markdown-Auszeichnung fehlt, Wasserfallbild ohne Beschriftung; `ProcessInfo.beginActivity` ist ein Platzhalter.
- Logiktests: `FakeSDRconnect` (braucht WebSocket aus Network.framework) fehlt; die Gruppe `sonde` ist zeitempfindlich und schlägt bei hoher Last fehl.
- HackRF/RTL-SDR: `dlopen` sucht Homebrew-Pfade (`ADSBSources.swift`), noch nicht auf `.so` umgestellt; SDRplay-Anbindung unter Linux ungeprüft.
- Hann-Fenster (`vDSP_HANN_NORM`): Skalierung nach Apples Beschreibung nachgebildet, nicht am Mac verglichen.
