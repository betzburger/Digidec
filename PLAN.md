# Digidec – Projektplan

> **Zweck dieser Datei:** Übergabedokument für jede weitere Sitzung, egal mit welchem LLM oder Menschen.
> Hier steht, **was gebaut wird, warum, woraus, und wo wir gerade stehen.**
> Beim Sitzungsstart zuerst diese Datei lesen, am Sitzungsende Abschnitt 11 („Aktueller Stand“) fortschreiben.

- **Name:** Digidec (festgelegt am 30.09.2026; Bundle-ID-Vorschlag `com.peterbetz.digidec`, URL-Schema `digidec://`)
- **Projektordner:** `/Volumes/X9-Mac-mini/src/swift/Swift_2026/Digidec/`
- **Erstellt:** 30.09.2026
- **Nutzung:** rein privat, keine Weitergabe, kein App Store
- **Plattform:** macOS 14+, Swift 6, SwiftUI, Swift Package (wie die Hauptprogramme)

---

## 1. Ziel

Eine eigenständige macOS-App, die als **externes Decoder-Modul** zu den beiden eigenen Hauptprogrammen arbeitet:

| Programm | Quellcode | Gerät | rigctld-Port |
|---|---|---|---|
| **FT-991A Commander** (v0.5.1 Alpha) | `Swift_2026/FT991ACommander/` | Yaesu FT-991A (Transceiver) | **4533** |
| **PCR-1500 Commander** (v0.21.1 Alpha) | `Swift_2026/PCR1500Commander/` | Icom IC-PCR1500 (Empfänger, 10 kHz – 3,3 GHz) | **4532** |

Arbeitsablauf aus Nutzersicht:

1. Im Commander eine Frequenz einstellen (z. B. DWD 147,3 kHz).
2. Button **„RTTY decodieren“** drücken.
3. Digidec startet oder kommt in den Vordergrund, übernimmt Quelle, Preset und Audiogerät und decodiert sofort.

Anforderungen:

- **Gleicher Qualitätsanspruch wie die Hauptprogramme:** stabil, sauber strukturiert, professionelle Bedienung.
- **Gleiches Design:** `RadioTheme` aus den Commandern (siehe Abschnitt 7).
- **Decodierqualität mindestens auf fldigi-Niveau.** Deshalb wird der Algorithmus von fldigi übernommen und nicht neu erfunden.
- Erster Decoder ist **RTTY**, genauso frei konfigurierbar wie in fldigi. Weitere Betriebsarten folgen als weitere Module (Abschnitt 9).

---

## 2. Beteiligte Programme und Signalfluss

```
┌──────────────────────┐   Audio (Soundkarte/USB-Codec)
│ FT-991A / IC-PCR1500 │ ───────────────┐
└──────────────────────┘                ▼
                              ┌──────────────────────┐   CAT seriell (exklusiv!)
                              │  FT-991A Commander / │◀────────────── Gerät
                              │  PCR-1500 Commander  │
                              └──────────────────────┘
               Audio-Ausgabe     │            │  rigctld TCP 4533 / 4532
               (Output-Auswahl   │            │  (Frequenz, Mode lesen)
                in der App)      ▼            │
                   ┌─────────────────────┐    │     URL-Aufruf
                   │ Virtuelle Soundkarte│    │   digidec://…         
                   │ BlackHole 16ch oder │    │   („RTTY decodieren“)
                   │ VALHost 2ch         │    │           │
                   └─────────────────────┘    │           │
                              │ Input         ▼           ▼
                              └────────▶┌──────────────────────┐
                                        │  Digidec             │
                                        │  (dieses Projekt)    │
                                        └──────────────────────┘
```

Fakten aus dem Bestand (geprüft am 30.09.2026):

- Beide Commander haben bereits eine **Audio-Ausgabegeräte-Auswahl** mit Erkennung virtueller Kabel (`AudioOutputDevice.isVirtualCable`, `refreshAvailableOutputDevices()` in `*AudioManager.swift`; UI in `LiveAudioRecorderView.swift`).
- Installierte virtuelle Geräte: **BlackHole 16ch** und **VALHost 2ch**. VALHost 2ch kommt vom eigenen Loopback-Treiber `Swift_2026/VALDriver` (AudioServerPlugIn, latenzfrei).
- Beide Commander haben einen **Hamlib-rigctld-Server** (`Sources/Hardware/HamlibRigctldServer.swift`), standardmäßig aktiv: PCR-1500 auf Port **4532**, FT-991A auf Port **4533**.
  Darüber liest der Decoder Frequenz und Mode, ohne den seriellen Port anzufassen. Der Port ist exklusiv und gehört dem Commander.
- Der FT-991A Commander kennt die Modes `.rttyL` / `.rttyU` (rigctld: `RTTY` / `RTTYR`).

---

## 3. Kopplung Commander ↔ Decoder (Schnittstelle)

Der Decoder soll ohne die Commander lauffähig bleiben, zum Beispiel für WAV-Dateien oder beliebige Audioquellen. Deshalb gibt es nur eine **lose Kopplung** über zwei Kanäle:

### 3.1 Start und Steuerung: URL-Schema (Commander → Decoder)

Der Commander ruft `NSWorkspace.shared.open(url)` auf. macOS startet den Decoder, falls er noch nicht läuft, oder holt ihn nach vorne.

```
digidec://open?source=pcr1500&rigctl=4532&device=<CoreAudio-UID>
digidec://decode?mode=rtty&preset=dwd-lw&source=pcr1500&rigctl=4532&device=<CoreAudio-UID>&center=1000
```

| Parameter | Bedeutung | Beispiel |
|---|---|---|
| `mode` | Decoder-Modul (optional bei `open`, Pflicht bei `decode`) | `rtty`, `navtex`, `cw`, `wefax`, `ft8`, `ft4`, `dcf77`, `efr` |
| `preset` | Preset-ID (Abschnitt 5) | `ham`, `dwd-kw`, `dwd-lw`, `custom` |
| `source` | Name des aufrufenden Programms, nur für die Anzeige | `pcr1500`, `ft991a` |
| `rigctl` | rigctld-Port des aufrufenden Programms | `4532` / `4533` |
| `device` | UID des Audiogeräts (USB-Codec des Transceivers/Empfängers) | Codec-UID des PCR-1500 bzw. FT-991A |
| `center` | optionale Audio-Mittenfrequenz in Hz | `1000` |

- Im Decoder: `CFBundleURLTypes` in der Info.plist, die in `build_app.sh` geschrieben wird, plus `.onOpenURL` / `NSAppleEventManager`.
- Im Commander: Kopfzeilen-Knopf **DIGIDEC** öffnet per Einfachklick (`openURL`) direkt die App und übergibt Funkgeräte-Quelle, Codec-UID und rigctld-Port. Die Betriebsartenwahl erfolgt direkt in Digidec.
  Das ist eine **Änderung an den Hauptprogrammen**. Dabei gelten ihre Regeln: Version erhöhen, Backup, Logiktests (siehe `CLAUDE.md` / `GEMINI.md` dort).
- Optionaler Rückkanal später: `DistributedNotificationCenter`, damit der Commander „Decoder aktiv“ und eine Signalanzeige darstellen kann.

### 3.2 Frequenz und Mode: rigctld (Decoder → Commander, nur lesend)

- Der Decoder verbindet sich per TCP mit `127.0.0.1:<rigctl>` und fragt zyklisch ab (z. B. 1×/s): `f` (Frequenz), `m` (Mode/Bandbreite).
- Verwendung: Anzeige in der Kopfzeile, Zeitstempel und Frequenz im Log, Plausibilitätsprüfung des Presets (z. B. LSB/USB ↔ Invertierung).
- **Standardmäßig nur lesend.** Nie Befehle senden, die das Gerät umstimmen, außer der Nutzer schaltet das ausdrücklich frei (z. B. „Klick im Wasserfall stimmt nach“).

---

## 4. RTTY-Decoder: Quelle und Vorgehen

### 4.1 Quelle: fldigi

- Kanonisches Repository: SourceForge `https://git.code.sf.net/p/fldigi/fldigi`.
  Der GitHub-Spiegel `github.com/w1hkj/fldigi` ist veraltet (letzter Push 06/2023, alte Pfade wie `src/cw_rtty/`). Nicht verwenden.
- **Festgelegter Stand: fldigi v4.2.13**, Commit `e7c3ab3709ad62a7d91829364eb48a05fa325c0d` (29.07.2026, zugleich `master` am 30.09.2026).
  Lokale Kopie als Nachschlagewerk: `Vendor/_upstream/fldigi-4.2.13/` (per `.gitignore` nicht im Digidec-Git; neu holen mit
  `git clone --depth 1 --branch v4.2.13 https://git.code.sf.net/p/fldigi/fldigi Vendor/_upstream/fldigi-4.2.13`).
  Zeilenangaben unten beziehen sich auf diesen Stand.
- Lizenz GPLv3. Für die rein private Nutzung spielt das keine Rolle. Bei einer späteren Weitergabe müsste das Projekt GPLv3 werden.
- Relevante Dateien:

| Datei | Inhalt |
|---|---|
| `src/rtty/rtty.cxx` (1637 Zeilen) | RTTY-Modem; **RX-Teil**: `rx_init` (Z. 134), `reset_filters` (221), `restart` (231), `mixer` (393), `decode_char` (447), `rx` (484), `rx_process` (628 – ≈890), `baudot_dec` (1445) |
| `src/include/rtty.h` | Klasse, Zustände, Konstanten (SHIFT/BAUD/BITS-Tabellen) |
| `src/filters/fftfilt.cxx`, `src/include/fftfilt.h` | Overlap-Add-FFT-Filter inkl. `rtty_filter()` (Raised-Cosine / erweitertes Nyquist-Filter nach W7AY) |
| `src/include/misc.h` | `decayavg()` und andere Helfer |
| `src/include/gfft.h` (`g_fft<double>`), `src/include/complex.h` (`cmplx`) | FFT und Komplextyp, die fftfilt nutzt; zunächst 1:1 übernehmen, vDSP erst nach bestandenem Vergleichstest |
| `src/dialogs/confdialog.fl` (Z. 495–499 Tabellen, ≈6700–6950 RTTY-Dialog) | Konfigurationsdialog = Referenz für alle Einstellmöglichkeiten |
| `src/rtty/view_rtty.cxx` | Mehrkanal-RTTY-Browser (später interessant) |
| `src/synop/…` | SYNOP-Decodierung, die fldigi direkt auf DWD-RTTY anwendet (später interessant) |

### 4.2 So arbeitet der fldigi-RTTY-Empfänger (zum Verständnis)

1. Reelles Audiosignal → komplex, getrennt **zweimal gemischt**: auf Mark (`f + shift/2`) und Space (`f − shift/2`) ins Basisband.
2. Je ein **FFT-Tiefpass** mit `rtty_filter` (Raised-Cosine, Formfaktor 1,0–2,0; Standard 1,25; „W1HKJ best 1.275“, „DO2SMF best 1.5“). Filterlänge hängt von der Baudrate ab (`FILTLEN[]`).
3. Beträge `mark_mag`, `space_mag`; daraus per `decayavg` die Hüllkurven (`*_env`) und Rauschböden (`*_noise`).
4. Entscheidung per **„Optimal ATC“** (Automatic Threshold Correction, Kok Chen W7AY). Clipping auf Hüllkurve und Rauschboden, dann
   `v3 = (mclip−nf)(menv−nf) − (sclip−nf)(senv−nf) − 0.25·((menv−nf)² − (senv−nf)²)`, `bit = v3 > 0`.
   Im Code stehen auskommentiert noch „No ATC“, „Linear“, „Clipped“ und „Kahn-Squarer“. Die übernehmen wir als Expertenoption.
5. **CWI-Unterdrückung:** Mark-Space (normal), nur Mark, nur Space (`rtty_cwi`).
6. Bit-Zustandsautomat `rx()`: Startbit-Suche, Mitten-Abtastung, Datenbits, Parität, Stopbit-Prüfung.
7. `baudot_dec`: ITA2 mit Buchstaben/Ziffern-Umschaltung, optional **Unshift-on-Space**.
8. **AFC**: Frequenzfehler aus der Phasendrehung des Mark- bzw. Space-Signals bei gültigen Zeichen, geglättet mit Slow/Normal/Fast (Faktor 8/4/1), nur oberhalb der Squelch-Schwelle.
9. Zusatzausgaben: XY-Scope (Kreuzellipse, „classic“ oder „pseudo“), Metrik/SNR für Squelch.

### 4.3 Vorgehen beim Herauslösen

`rtty.cxx` hängt stark an fldigi-Globalen (`progdefaults`, `progStatus`, `wf` = Wasserfall, digiscope, synop, FLTK). Deshalb:

1. **Nur den RX-Pfad** in ein eigenes, GUI-freies C++-Modul `Vendor/Fldigi/` kopieren:
   `rtty_rx.cpp/.h`, `fftfilt.cpp/.h`, benötigte Helfer. Die Algorithmik **1:1** übernehmen, keine „Verbesserungen“ beim Kopieren.
2. Alle Globalen ersetzen durch ein Konfig-Struct `RTTYConfig` (Abschnitt 5) und Callbacks:
   - `on_char(char, userdata)` statt `put_rx_char`
   - `on_freq_correction(double hz)` statt `set_freq` (AFC)
   - `get_scope(xy[], n)`, `get_metrics(markMag, spaceMag, snr, freqErr)`
3. Eine **C-API** (`include/fldigi_rtty.h`) darüberlegen, damit Swift sie ohne C++-Interop-Sonderfälle aufrufen kann:
   `rtty_create(cfg)`, `rtty_process(float*, n)`, `rtty_set_center(hz)`, `rtty_reset()`, `rtty_destroy()`.
4. Als SwiftPM-C/C++-Target einbinden, nach dem Muster von `Vendor/CRNNoise` in den Commandern (`publicHeadersPath: "include"`).
5. Jede Abweichung vom Original kommentieren (`// ABWEICHUNG fldigi: …`) und die fldigi-Version bzw. den Commit notieren, aus dem kopiert wurde.

---

## 5. RTTY-Einstellungen und Presets

### 5.1 Einstellmöglichkeiten (vollständig wie fldigi RX, plus Ergänzungen)

| Einstellung | fldigi-Werte | Bemerkung |
|---|---|---|
| Shift (Hz) | 23, 85, 160, 170, 182, 200, 240, 350, 425, 850, **benutzerdefiniert** | Quelle: `szShifts` in confdialog.fl |
| Baud | 45, 45.45, 50, 56, 75, 100, 110, 150, 200, 300 | `szBauds` |
| Bits | 5 (Baudot/ITA2), 7 (ASCII), 8 (ASCII) | `szSelBits` |
| Parität | none, even, odd, zero, one | bei 5 Bit immer none |
| Stoppbits | 1, 1.5, 2 | |
| Invertiert (Reverse) | an/aus | zusätzlich automatisch bei LSB (fldigi: `reverse = wfrev ^ !usb`) |
| Audio-Mittenfrequenz | frei (Hz) | per Klick im Wasserfall |
| AFC | aus / Slow / Normal / Fast | |
| Squelch | an/aus + Schwelle | |
| Filter-Formfaktor | 1,0 – 2,0 (Standard 1,25) | „Filter Shape Factor“ |
| Decode (CWI-Unterdrückung) | Mark-Space / nur Mark / nur Space | |
| Unshift on Space | an/aus | |
| Detektor (Experte) | Optimal ATC (Std.), Linear, Clipped, Kahn linear, Kahn clipped, ohne ATC | im Original auskommentiert |
| Zeilenumbruch | automatisch nach n Zeichen, CR-CR-LF-Behandlung | |
| XY-Scope | classic / pseudo | |
| **Ergänzung:** Auto-Invertierung | an/aus | beide Polaritäten parallel decodieren und die mit gültigen Zeichen bzw. bekannten Kennungen (`ZCZC`, `EDZW`, `NNNN`) wählen |

### 5.2 Presets

| Preset-ID | Name | Baud | Shift | Bits | Stop | Parität | Invert | Hinweis |
|---|---|---|---|---|---|---|---|---|
| `ham` | Amateurfunk (Standard) | 45,45 | 170 Hz | 5 | 1,5 | none | nein* | ITA2, Mark = höhere HF (Amateurkonvention); klassisch LSB, Mark 2125 / Space 2295 Hz |
| `dwd-kw` | DWD Kurzwelle | 50 | 450 Hz (± 225) | 5 | 1,5 | none | **zu prüfen** | 4583 / 7646 / 10100,8 / 11039 / 14467,3 kHz |
| `dwd-lw` | DWD Langwelle 147,3 kHz | 50 | 85 Hz (± 42,5) | 5 | 1,5 | none | **zu prüfen** | DDH47, 20 kW |
| `custom` | Benutzerdefiniert | frei | frei | frei | frei | frei | frei | vom Nutzer gespeichert |

\* „Invert“ bezieht sich auf die Decoder-Logik **nach** der automatischen LSB/USB-Korrektur.

**Polarität DWD – bestätigt am 30.09.2026, 19:22 UTC:** DDK2 4583 kHz, PCR-1500 in **LSB**, Dial 4584,700 kHz, Mitte 1696 Hz:
fehlerfreie Testschleife („CQ CQ CQ DE DDK2 DDH7 DDK9 / FREQUENCIES 4583 KHZ 7646 KHZ 10100.8 KHZ“) **ohne REV**
(Mark im Audio oben bei 1921 Hz). Mark liegt also auf der **tieferen HF** (4582,775 kHz), wie bei kommerziellem F1B üblich und umgekehrt zum Amateurfunk.
Solange Digidec das Seitenband nicht kennt, gilt: **DWD in LSB → REV aus, in USB → REV an.**
Ab M7 liest Digidec den Mode über rigctld und korrigiert automatisch wie fldigi (`reverse = REV xor LSB`). Dann erhalten die DWD-Presets `reverse = true` im Sinne der HF-Konvention.
**ITA2** für den DWD ist noch zu bestätigen. Die Testschleife enthält kein `+` oder `=`; die Wetterberichte, zum Beispiel WODL45 zur vollen 3-Stunden-Marke, enthalten sie.

**Abstimmhilfe:** Audio-Mitte 1000 Hz → Dial in USB = Sollfrequenz − 1,0 kHz.
Beispiel DWD LW: USB, Dial **146,300 kHz** → Töne bei ≈ 957,5 / 1042,5 Hz.
Beispiel DWD KW: USB, Dial **10099,800 kHz** → Töne bei 775 / 1225 Hz.

### 5.3 DWD-Sendeplan (Stand: DWD-Sendeplan RTTY, abgerufen 30.09.2026)

| Frequenz | Rufzeichen | Sendezeit (UTC) | Leistung | Programm |
|---|---|---|---|---|
| 147,3 kHz | DDH47 | 05:00 – 22:00 | 20 kW | 2. Programm |
| 11039 kHz | DDH9 | 05:00 – 22:00 | 1 kW | 2. Programm |
| 14467,3 kHz | DDH8 | 05:00 – 22:00 | 1 kW | 2. Programm |
| 4583 kHz | DDK2 | 00:00 – 24:00 | 1 kW | 1. Programm |
| 7646 kHz | DDH7 | 00:00 – 24:00 | 1 kW | 1. Programm |
| 10100,8 kHz | DDK9 | 00:00 – 24:00 | 10 kW | 1. Programm |

Alle Sender: F1B, 50 Baud; Hub ± 42,5 Hz (LW) bzw. ± 225 Hz (KW). Sender Pinneberg.
Sturmwarnungen `WODL45 EDZW` zu jeder vollen 3-Stunden-Marke (00, 03, 06, … UTC), im 2. Programm ab 05:00.
Gut für Tests: Seewetterbericht Nord- und Ostsee (`FQEN50` / `FQEN70`) kurz nach jeder Warnung.
Der PCR-1500-Commander kennt 147,3 kHz DDH47 bereits in seiner Frequenzdatenbank (GEMINI.md, Abschnitt 5).

Quellen:
- DWD-Sendeplan RTTY: https://www.dwd.de/DE/derdwd/it/_functions/Teasergroup/sendeplan_rtty.pdf
- DWD RTTY Prog. 2 (engl., 2014): https://www.dwd.de/EN/specialusers/shipping/broadcast_en/broadcast_rtty_2_052014.pdf
- HFUnderground-Wiki: https://www.hfunderground.com/wiki/RTTY_maritime_weather_transmissions
- fldigi-Handbuch RTTY: https://www.w1hkj.org/FldigiHelp/rtty_page.html und https://www.w1hkj.org/FldigiHelp/rtty_fsk_configuration_page.html

---

## 6. App-Architektur

```
Digidec/
├── PLAN.md                     ← diese Datei
├── Package.swift               (swift-tools 6.0, macOS 14, wie Commander)
├── build_app.sh                (Bundle, Info.plist inkl. CFBundleURLTypes, ad-hoc Signatur)
├── Sources/
│   ├── App/        DigidecApp.swift, AppVersion.swift, URLRouter.swift
│   ├── Audio/      AudioInputManager.swift   (CoreAudio/AVAudioEngine, Geräteauswahl per UID,
│   │                                          Kanalwahl, Resampling auf 8 kHz bzw. 48 kHz, Pegel)
│   │               WAVFileSource.swift        (Datei statt Live-Audio, für Tests)
│   ├── Rig/        RigctlClient.swift        (TCP, nur lesend: f, m)
│   ├── Decoders/   DecoderModule.swift       (Protokoll für alle Decoder)
│   │               RTTY/RTTYDecoder.swift, RTTYConfig.swift, RTTYPresets.swift
│   ├── DSP/        Spectrum.swift            (vDSP-FFT für Wasserfall)
│   ├── Log/        DecodeLogger.swift        (Textlog pro Sitzung mit UTC, Frequenz, Preset)
│   └── UI/         Theme.swift (Kopie aus Commander), MainWindowView, WaterfallView,
│                   XYScopeView, DecodeTextView, RTTYSettingsView, StatusBarView
├── Vendor/
│   └── FldigiRTTY/ (C++ Kern + C-API, siehe 4.3)
├── Tools/
│   └── LogicTests/ (wie Commander: run_logic_tests.sh, Exit-Code 0 = bestanden)
└── TestData/       (WAV-Aufnahmen + erwartete Texte)
```

**Decoder-Protokoll:** Grundlage für alle späteren Module.

```swift
protocol DecoderModule: AnyObject {
    var id: String { get }                      // "rtty"
    var displayName: String { get }             // "RTTY"
    var sampleRate: Double { get }              // gewünschte Eingangsrate
    func process(_ samples: UnsafeBufferPointer<Float>)   // Audio-Thread, keine Allokation
    var events: AsyncStream<DecoderEvent> { get }         // Text, Metriken, AFC, Scope
    func reset()
}
```

Leitlinien, übernommen aus den Commander-Projekten (`GEMINI.md`):

- CoreAudio-Stop und -Dispose **nie** synchron auf dem Main Thread unter Locks, sondern auf einer eigenen Audio-Queue.
- Audio-Callback: keine Allokationen, keine Locks. Übergabe über einen Ringpuffer an den Decoder-Thread.
- UI-Updates gebündelt (≈ 20–30 Hz), nicht pro Zeichen oder Sample.
- Einstellungen in `UserDefaults` (wie Commander), Presets als Codable-JSON.

---

## 7. Design

Das Design übernimmt `Sources/UI/Theme.swift` der Commander 1:1. Beide Commander enthalten identische Kopien.

- Farben: `RadioTheme.bgDeep / bgPanel / bgCard / borderSubtle / borderActive`,
  Anzeigen in `vfdAmber`, `vfdCyan`, `vfdGreen`, LEDs `ledRed` / `ledYellow`, Text `textBright / textMuted / textDim`.
- Karten: `.radioCard(title:)`, mit Titel in Großbuchstaben, 10 pt, monospaced, `tracking 1.2`.
- Buttons: `ModeButtonStyle(isSelected:)`, 11 pt monospaced semibold, Cyan bei Auswahl.
- Versionsanzeige oben links neben dem Namen (`AppVersion.string`), wie in den Commandern.
- Später: `Theme.swift` in ein gemeinsames lokales Swift Package (z. B. `RadioUIKit`) auslagern, das alle drei Apps nutzen.
  Das geht erst nach Rücksprache, weil es auch die Hauptprogramme ändert.

**Fenster-Layout RTTY (Entwurf):**

```
┌ DIGIDEC  0.1.0 Alpha ───────────────── Quelle: PCR-1500 · 146,300 kHz USB · rigctl ● ── 14:32:07 UTC ┐
│ [RTTY] [CW] [NAVTEX] …   (Modul-Leiste, ModeButtonStyle)                                            │
├───────────────────────────────────────────────────────────────┬──────────────────────────────────────┤
│ WASSERFALL / SPEKTRUM (Mark/Space-Marker, Klick = Mitte)      │ XY-SCOPE     │ PRESET               │
│                                                               │  (Ellipsen)  │ [Amateur][DWD KW]    │
│                                                               │              │ [DWD LW][Eigene]     │
├───────────────────────────────────────────────────────────────┤ PEGEL / SNR  │ 50 Bd · 85 Hz · 5/1.5│
│ DECODIERTER TEXT (monospaced, vfdGreen auf bgDeep)            │ AFC ● Squelch│ [Invert][AFC][UOS]   │
│ ZCZC …                                                        │ ─────────────┴──────────────────────│
│ WODL45 EDZW 301200 …                                          │ [Einstellungen …]  [Log ●] [Löschen] │
└───────────────────────────────────────────────────────────────┴──────────────────────────────────────┘
```

---

## 8. Qualitätssicherung: „genauso gut wie fldigi“ nachweisen

### 8.0 Ablauf für den Vergleich (Werkzeuge seit v0.8.0)

1. **Aufnehmen:** In Digidec bei laufendem Empfang auf **REC** drücken (Leiste über dem Empfangstext), einige Minuten, dann Stopp.
   Es entstehen zwei Dateien in `~/Documents/Digidec/Recordings/`: `RTTY_<UTC>_<Hz>_<Mode>_<PRESET>.wav` (Eingang nach Kanalwahl, Quellrate, 16 Bit mono)
   und die gleichnamige `.json` mit Preset, Decoder-Parametern (Reverse nach Seitenband), Optionen, Mitte, Frequenz und Mode.
2. **Digidec offline:** `Tools/DecodeFile/decode_file.sh <wav> --loop ddk2` → `<wav>.digidec.txt` und Auswertung.
   `--loop ddk2` wertet gegen die bekannte DWD-Testschleife („RYRY…“, „CQ CQ CQ DE DDK2 DDH7 DDK9“, „FREQUENCIES …“). Nicht dazugehörige Zeilen werden ignoriert.
3. **fldigi:** fldigi 4.2.13 starten (installiert: `/Applications/fldigi-4.2.13.app`), dann `Tools/fldigi_rtty.py prepare <wav>`.
   Das setzt RTTY, Mitte, Reverse und AFC per XML-RPC und nennt die Werte für Configure → Modems → TTY (Shift, Baud, **Unshift on Space aus** für DWD, ITA2).
   Danach in fldigi **File → Audio → Playback** mit der WAV-Datei. Wenn sie durchgelaufen ist: `Tools/fldigi_rtty.py fetch <wav>` → `<wav>.fldigi.txt`.
4. **Vergleich:** `Tools/DecodeFile/decode_file.sh <wav> --loop ddk2 --compare <wav>.fldigi.txt`
   liefert Zeichenfehler beider Programme gegen die Testschleife und die Abweichung Digidec ↔ fldigi.
5. Ergebnisse in die Tabelle unten eintragen.

| Datum | Aufnahme | Bedingungen | Digidec Fehler | fldigi Fehler | Abweichung |
|---|---|---|---|---|---|
| 30.09.2026 | `RTTY_2026-09-30_195246Z_4584700Hz_LSB_DWD-KW.wav` (DDK2 4583 kHz, PCR-1500 LSB, 140 s) | KW abends, Signal gut bis mäßig | 0,79 % (6/758), 13/17 Zeilen fehlerfrei | 0,79 % (6/758), 13/17 Zeilen fehlerfrei | 0,66 % (nur Einschwingen erste Zeile) |

**Ergebnis 30.09.2026:** Digidec und fldigi 4.2.13 liefern auf derselben Aufnahme **zeichengleichen Text**, einschließlich jedes einzelnen Fehlers.
Einziger Unterschied ist die erste, angeschnittene Zeile beim Einsetzen des Signals: fldigi hatte vorher Rauschen verarbeitet, sein Filter- und AFC-Zustand war dadurch minimal anders.
fldigi-Einstellungen: RTTY 450/50, 5 Bit, 1,5 Stopp, Unshift on Space aus, AFC normal, Mitte 1695 Hz, Reverse aus, Seitenband USB, ohne Funkgeräte-Verbindung.
Hinweis zum Ablauf: fldigi war vor der Wiedergabe neu gestartet worden. Der Empfangstext enthielt deshalb Vorlauf, der für den Vergleich bis zum Wiedergabebeginn abgeschnitten wurde (`…fldigi_playback.txt`).
**Achtung:** fldigi ist beim Nutzer per Hamlib mit `127.0.0.1:4533` (rigctld des FT-991A Commanders) verbunden. Während des Vergleichs den FT-991A Commander nicht laufen lassen, sonst kennt fldigi das Seitenband und dreht zusätzlich um.

Selbsttest der Werkzeuge (synthetische Testschleife, DWD KW, 48 kHz): sauber 0,00 %, −6 dB 8,2 %, −9 dB kaum noch Zeilen erkannt.

1. **Testdaten aufnehmen:** Mit dem PCR-1500 bzw. FT-991A über die virtuelle Soundkarte WAV-Dateien aufzeichnen (Commander haben einen Live-Audio-Recorder).
   Ziel: je mindestens 3 Aufnahmen DWD-LW, DWD-KW und Amateur-RTTY, gute und schlechte Bedingungen.
2. **Referenz:** Dieselben WAVs mit fldigi (macOS-Version installieren, Audio-Eingang = Datei bzw. Loopback) decodieren und den Text speichern.
3. **Synthetische Tests:** Generator in den LogicTests erzeugt RTTY mit bekanntem Text und additivem Rauschen bei definiertem SNR (z. B. −5 … +15 dB in 3 kHz), optional Frequenzversatz und Drift für die AFC.
4. **Metrik:** Zeichenfehlerrate (CER) gegen den bekannten Text. Abnahme: CER ≤ fldigi bei allen Testpunkten.
5. **Regressionsschutz:** Tests laufen per `Tools/LogicTests/run_logic_tests.sh` nach jeder Änderung am Decoder-Kern.

---

## 9. Decoder-Quellen für spätere Module

Priorität nach Nutzen und Aufwand. „Leicht“ = C/C++ mit wenig Abhängigkeiten.

### KW-Digimodes (Soundkarte)

| Modes | Quelle | Sprache | Aufwand |
|---|---|---|---|
| RTTY, CW, PSK31/63/125, QPSK, 8PSK, Olivia, Contestia, MFSK, DominoEX, Thor, Throb, MT63, IFKP, FSQ, Feld-Hell, **NAVTEX/SITOR-B**, **WEFAX** | **fldigi** | C++ | mittel (gleiches Herauslöse-Muster wie RTTY) |
| SYNOP-Decodierung im DWD-Text | fldigi `src/synop` | C++ | mittel |
| FT8, FT4 | **ft8_lib** (kgoba) | C | sehr leicht |
| WSPR | **wsprd** aus WSJT-X (`lib/wsprd`) | C | leicht |
| JT65, JT9, Q65, MSK144, FST4 | **WSJT-X** | Fortran + C++ | schwer; alternativ `jt9` als Prozess |
| JS8 | JS8Call | Fortran + C++ | schwer |
| SSTV | slowrx (einfach) / QSSTV (mehr Modi) | C / C++ (Qt) | leicht / schwer |
| FreeDV | codec2 | C | leicht |
| DRM | Dream | C++ | schwer |

### VHF/UHF: Packet, Pager, Selektivruf

| Modes | Quelle | Sprache | Aufwand |
|---|---|---|---|
| AX.25/APRS (1200/300/9600), FX.25, IL2P | **direwolf** | C | mittel |
| POCSAG, FLEX, DTMF, ZVEI, CCIR/EEA, EAS | **multimon-ng** | C | leicht |

### Digitale Sprache

| Modes | Quelle | Sprache | Aufwand |
|---|---|---|---|
| DMR, dPMR, NXDN, P25, D-Star, YSF, EDACS | **dsd-fme** oder **dsdcc** | C / C++ | mittel |
| AMBE/IMBE-Sprache | mbelib | C | leicht |
| M17 | libm17 / m17-cxx-demod + codec2 | C / C++ | leicht |
| TETRA | osmo-tetra | C | schwer |

### Luftfahrt, Seefahrt, Satelliten, Sonstiges

| Modes | Quelle | Sprache | Aufwand |
|---|---|---|---|
| ADS-B 1090 | readsb / dump1090 | C | leicht (braucht I/Q, nicht Audio!) |
| ACARS | acarsdec | C | leicht |
| VDL2 / HFDL | dumpvdl2 / dumphfdl | C | mittel |
| AIS | AIS-catcher | C++ | leicht–mittel |
| DSC, VOR, ILS, LoRa | SDRangel | C++ (Qt) | schwer |
| NOAA APT / Meteor LRPT | aptdec / SatDump | C / C++ | leicht / schwer |
| Radiosonden | zilog80/radiosonde | C | leicht |
| RDS | redsea | C++ | leicht |
| DAB/DAB+ | welle.io / dab-cmdline | C++ | mittel–schwer |
| ISM 433/868 MHz | rtl_433 | C | leicht (braucht I/Q) |

**Wichtig:** Die Commander liefern **demoduliertes NF-Audio**. Alles, was I/Q-Rohdaten braucht (ADS-B, rtl_433, DAB, breitbandige Digitalmodi), geht über diesen Weg **nicht**. Dafür bräuchte es später einen SDR-Eingang.
Über NF-Audio funktionieren: alle KW-Digimodes, NAVTEX, WEFAX, CW, APRS 1200, POCSAG, DTMF/Selektivruf, ACARS (AM), FM-Digitalsprache, sofern der Empfänger ungefiltertes Diskriminator-Audio liefert (beim IC-PCR1500 prüfen), und SSTV.

OpenWebRX dient nur als **Einkaufsliste**: Es bindet genau diese Einzelprojekte ein. SDRangel nur für das, was es sonst nicht gibt.

---

## 10. Meilensteine

| # | Meilenstein | Ergebnis / Abnahme |
|---|---|---|
| M0 | Plan (diese Datei) | ✅ 30.09.2026 |
| M1 | Projektgerüst | ✅ 30.09.2026 (v0.1.0): Package.swift, build_app.sh (inkl. `digidec://` + Launch-Services-Registrierung), AppVersion, Fenster im RadioTheme mit Platzhaltern, URL-Parser, LogicTests (26 Prüfungen) |
| M2 | Audio-Eingang | ✅ 30.09.2026 (v0.3.0): direkt vom USB-Codec des Funkgeräts, portunabhängig; VALHost 2ch manuell wählbar |
| M3 | Wasserfall | ✅ 30.09.2026 (v0.4.1): vDSP-FFT, Spektrumkurve, Mark/Space-Marker, Klick/Ziehen setzt Mitte, Zoom, Dynamik; Presets wählbar |
| M4 | fldigi-RTTY-Kern herausgelöst | ✅ 30.09.2026 (v0.5.0): `Vendor/Fldigi` + C-API, Signalverarbeitung zeilengleich mit fldigi 4.2.13, alle Presets synthetisch fehlerfrei |
| M5 | RTTY in der App | ✅ 30.09.2026 (v0.6.1): Text, Log, XY-Scope, Signalanzeige, REV/AFC/SQL, Einstellungsdialog; Bedienung durch den Nutzer noch zu prüfen |
| M6 | Qualitätsnachweis | ✅ 30.09.2026 (v0.8.0): Werkzeuge fertig; echte DDK2-Aufnahme: Digidec und fldigi 4.2.13 zeichengleich, beide 0,79 % (Abschnitt 8.0) |
| M7 | rigctld-Anbindung | ✅ 30.09.2026 (v0.7.1): Frequenz/Mode in Kopfzeile und Log, automatische Seitenband-Korrektur (AUTO/USB/LSB) |
| M8 | URL-Schema + Buttons in beiden Commandern | ✅ 30.09.2026: Knopf DIGIDEC in PCR-1500 Commander 0.22.0 und FT-991A Commander 0.6.0; automatische DWD-Erkennung mit NF-Mitte; Klick durch den Nutzer noch zu prüfen |
| M5b | SYNOP-Klartext | ✅ 30.09.2026 (v0.9.0): SYNOP/SHIP/BUOY-Decoder aus fldigi, Klartext in Amber unter den Meldungen, Schalter SYNOP |
| M9 | NAVTEX | ✅ 01.10.2026 (v0.10.1): fldigi-NAVTEX-Empfänger, Modul-Umschaltung, Nachrichtenliste mit Station, Log; Live-Empfang durch den Nutzer offen |
| M10 | CW | ✅ 01.10.2026 (v0.11.0): fldigi-CW-Empfänger (Tabelle/SOM, Geschwindigkeitsnachführung, Matched Filter), Hüllkurvenanzeige, Log, `decode_file.sh --cw`; Live-Empfang durch den Nutzer offen |
| M11 | WEFAX | ✅ 01.10.2026 (v0.12.0): fldigi-WEFAX-Empfänger (APT, Phasing, Korrelation, AFC, Auto-Zentrierung), Live-Bild, PNG-Ablage, Galerie, `decode_file.sh --wefax`; Live-Empfang durch den Nutzer offen |
| M12 | FT8 | ✅ 01.10.2026 (v0.13.0): ft8mon (AB1HL, MIT) statt ft8_lib: 90,7 % der WSJT-X-Decodes statt 73 %; Bandaktivität, Rx-Frequenz, Entfernungen, ALL.TXT-Log; Live-Empfang durch den Nutzer offen |
| M13 | DCF77 | ✅ 01.10.2026 (v0.14.0): AM-Impulsbreiten-Decoder (77,5 kHz, AM 100/200 ms), VFD-Atomuhr, Δt-Vergleich zur Systemzeit in ms, 60-Bit-Telegramm-Matrix, Scope, Log; 404 Tests bestanden |
| M14 | EFR | ✅ 01.10.2026 (v0.15.0): FSK-Demodulator (200 Baud, Shift 340 Hz, 8E1), DIN 19244 / FT1.2-Parser (Zeitsynchronisation, Rundsteuerbefehle, EEG-Abregelung), Stations-Presets DCF49 (129,1 kHz) / DCF39 (139,0 kHz) / HGA22 (135,6 kHz), FSK-Oszilloskop, Log; 433 Tests bestanden |
| M15 | FT4 | ✅ 01.10.2026 (v0.16.0): ft8_lib FT4-Demodulator & LDPC/CRC-Decoder (7,5 s Slot, 4-GFSK, 20,8333 Baud), Bandaktivität, Rx-Frequenz, 7,5-s-Zyklus Scope/Timeline, ALL.TXT-Log; 452 Tests bestanden |
| M16 | DXCC | ✅ 01.10.2026 (v0.17.0): ARRL/AD1C DXCC-Länderdatei (cty.dat, 346 Gebiete, 21.800 Sonderrufzeichen, 7.500 Präfixe), automatische Flaggen, CQ-/ITU-Zonen, Koordinaten, Portabel- & Gastland-Auflösung, Integration in FT8/FT4 Tabellen & Tooltips; 502 Tests bestanden |
| M17 | SSTV | ✅ 01.10.2026 (v0.18.0): 11 Betriebsarten (Martin 1/2, Scottie 1/2/DX, Robot 36/72, PD 90/120/180, Wraase SC2-180), VIS-Erkennung mit Parität, Sync-Verfolgung mit Flywheel und Wiedereinrasten, Live-Bild, PNG-Ablage, Galerie; Pixel-Roundtrip aller Modi und echter Scottie-1-Mitschnitt (sigidwiki) lesbar dekodiert |
---

## 11. Aktueller Stand

> Nach jeder Sitzung fortschreiben: Datum, was erledigt ist, was als Nächstes kommt, offene Probleme.

**30.09.2026:**
- Plan erstellt. Bestand der beiden Commander gesichtet (Theme, rigctld-Ports, Audio-Ausgabe auf virtuelle Geräte, Projektregeln).
- DWD-Parameter aus dem offiziellen Sendeplan übernommen (Abschnitt 5.3).
- fldigi-RTTY-Quellen und alle Konfigurationsoptionen identifiziert (Abschnitte 4 und 5.1).
- **Noch kein Code geschrieben.**
- Name festgelegt: **Digidec** (Ordner umbenannt).
- Entscheidungen: Standardgerät VALHost 2ch, lokales Git ohne Remote, fldigi v4.2.13 (nach `Vendor/_upstream/` geklont).
- Git-Repository angelegt, Plan als erster Commit.
- **M1 erledigt (v0.1.0 Alpha):**
  - `Sources/App`: `DigidecApp` (einzelnes `Window`, URL-Aufträge über `AppDelegate.application(_:open:)`, damit kein zweites Fenster aufgeht), `DigidecState` (Singleton, `handle(url:)`), `AppVersion`.
  - `Sources/Models`: `DecoderModuleInfo` (RTTY verfügbar; NAVTEX, CW, WEFAX, FT8 geplant), `DecodeRequest` + `DecodeRequestParser` (Parameter aus 3.1, Prüfung von Port 1025–65535 und Mitte 100–4000 Hz, Dezimalkomma erlaubt).
  - `Sources/UI`: `Theme.swift` (identische Kopie aus beiden Commandern), `MainWindowView` (Kopfzeile mit Version, Quelle und UTC-Uhr, Modul-Leiste, Platzhalter für Wasserfall, Text, Scope, Eingang, Preset-Anzeige, Statuszeile).
  - `Tools/LogicTests`: Versionsabgleich AppVersion ↔ build_app.sh, 26 Prüfungen zum URL-Parser, alle bestanden.
  - `swift build` ohne Warnungen; `Digidec.app` gebaut, signiert, `digidec://` bei Launch Services registriert.
  - **v0.1.1:** App-Start und URL-Aufrufe am echten System getestet: Kaltstart per URL, zweiter Aufruf bei laufender App (kein zweites Fenster, Quelle/Preset/Mitte übernommen), abgelehnter Aufruf (`mode=navtex` → Meldung in der Statuszeile).
    Fehler behoben: Bei laufender App kam das Fenster nicht nach vorne, weil macOS 14+ `activate(ignoringOtherApps:)` ignoriert. Jetzt `NSApp.activate()` plus `makeKeyAndOrderFront` im `AppDelegate` (`@MainActor`).
    Für M8 merken: Die Commander sollen mit `NSWorkspace.OpenConfiguration` (`activates = true`) öffnen.
  - Kein App-Icon (`Resources/AppIcon.icns` fehlt noch).
- **M2 umgesetzt (v0.2.0 Alpha):**
  - `Sources/Audio`:
    - `AudioInputDevice` + `AudioDeviceSelection` (Reihenfolge: Gerät aus Auftrag → zuletzt gewählt → VALHost 2ch → erstes virtuelles Kabel → erstes Gerät).
    - `AudioDeviceCatalog` (CoreAudio: Geräte mit Eingangskanälen, UID, Nennrate).
    - `LiveAudioCapture` (AudioQueue wie in den Commandern, Gerät per `kAudioQueueProperty_CurrentDevice`, 48 kHz Float stereo; Start/Stop auf eigener Queue; Callback ohne Allokation).
    - `AudioPipeline` (Ringpuffer → 20-ms-Takt → Pegel → Wandlung auf 8 kHz → Senken). Hier hängt ab M3/M5 der Wasserfall und der Decoder an (`addSink`).
    - `SampleRateConverter`: **eigener** Polyphasen-Sinc-Resampler mit Kaiser-Fenster (β = 9, 24 Nulldurchgänge, 128 Phasen).
      AVAudioConverter wurde verworfen: Im Streaming-Betrieb verlor er je nach Blockgröße Samples (≈ 54/s bei 4800er-Blöcken), das hätte den Bit-Takt verfälscht.
      Jetzt exakt 8000 Samples/s, bitgleich bei jeder Blockgröße, 6 kHz um > 60 dB gedämpft, ≈ 2000× Echtzeit.
    - `WAVFileSource` (WAV/AIFF/CAF in Echtzeit in die Pipeline), `AudioBasics` (Kanalwahl L/R/L+R, Pegel, Ringpuffer).
    - `AudioInputManager` (@MainActor; Pegel in eigenem `LevelModel` mit 20 Hz, damit nur das Messinstrument neu zeichnet; reagiert auf An-/Abstecken von Geräten).
  - UI: Karte „Eingang“ mit LIVE/DATEI, L/R/L+R, Gerätemenü, Pegelanzeige −60…0 dBFS (Balken = Effektivwert, Strich = Spitze mit Haltezeit), Status.
  - Auftrag mit `device=<UID>` schaltet auf dieses Gerät um.
  - Logiktests: 70 Prüfungen (Ringpuffer, Kanalwahl, Pegel, Resampler inkl. Blockgrößen- und Alias-Test, Pipeline Ende-zu-Ende, Gerätewahl, WAV öffnen), alle bestanden.
  - **Am echten System geprüft:** App startet mit VALHost 2ch, Status grün. Aufnahme funktioniert nachweislich (USB-Codec: Rauschen −72 dBFS; Webcam-Mikrofon: Raumgeräusche).
  - **Offen / ungeklärt:** Ein Testton, der aus der Claude-Code-Umgebung auf VALHost 2ch **oder** BlackHole 16ch gespielt wurde, kam bei keinem Aufnahmeprogramm an, auch nicht bei ffmpeg.
    Digidec ist damit nicht die Ursache. Vermutlich blockiert die Sandbox der Claude-Code-Shell die Tonausgabe; das ließ sich nicht prüfen.
    → Der Nutzer testet mit einem Commander (Ausgabe auf VALHost 2ch) oder mit `afplay` im eigenen Terminal.
  - **Risiko VALDriver:** `ReadInput` in `VALDriver.c` setzt jedes gelesene Sample auf 0. Liest ein zweites Programm von VALHost 2ch, zum Beispiel weil VALHost 2ch auch **Standard-Eingang** des Systems ist (Teams, Siri, Diktat), bekommt nur das schnellere Programm den Ton.
    Abhilfe, falls nötig: Standard-Eingang des Systems auf ein anderes Gerät stellen, oder VALDriver so ändern, dass er nicht mehr löscht (wie BlackHole).
- **Befund Live-Test (30.09.2026, PCR-1500 Commander lief, Ausgabe auf VALHost 2ch):**
  Am Codec des PCR-1500 kamen −14,6 dBFS an, auf VALHost 2ch nur Nullen, auch mit ffmpeg als einzigem Leser.
  Digidec direkt am Codec zeigte −15 dB. Ob der Commander nichts ausgab oder der Loopback in VALDriver versagt, ist **nicht geklärt**.
- **Entscheidung (Nutzer, 30.09.2026): Digidec liest direkt vom USB-Codec des Funkgeräts.** VALHost 2ch und andere Geräte bleiben manuell wählbar.
  Vorteile: keine virtuelle Soundkarte als Fehlerquelle, mehrere Leser am USB-Gerät möglich, unbearbeitetes Empfängersignal ohne Rauschminderung/Notch des Commanders.
- **v0.3.0 – Funkgeräte-Codec unabhängig vom USB-Port:**
  - `RadioCodecLocator`: Der Seriell-Wandler ist eindeutig (PCR-1500: USB-Seriennummer „IC-PCR1500…“, CP2101; FT-991A: CP2105 0xEA70). Der Codec ist das Gerät am selben eingebauten Hub.
    Gleiche Logik wie `findPCR1500AudioCodec` / `findFT991AAudioCodec` in den Commandern. Nur Lesen aus der IORegistry, **Digidec öffnet keine seriellen Ports**.
  - Gespeichert wird die **Quelle** (`radio:pcr1500`), nicht die UID. Die UID enthält die USB-Position und ändert sich beim Umstecken. UserDefaults-Schlüssel `audioInputSelection`.
  - Auftrag mit `source=pcr1500|ft991a`: Dieses Funkgerät gilt für die Sitzung, die mitgeschickte `device`-UID hat Vorrang; passt sie nicht, sucht Digidec über den Hub.
  - Ist das gewählte Funkgerät nicht angeschlossen: Meldung „… nicht angeschlossen – wartet“, **kein** Ausweichen auf eine andere Quelle. Beim Anstecken, auch an einem anderen Port, startet die Aufnahme automatisch.
  - Ohne gespeicherte Wahl: PCR-1500 vor FT-991A, sonst VALHost 2ch, sonst erstes virtuelles Kabel.
  - Gerätemenü: Abschnitt „Funkgeräte“ mit Anschlussstatus, darunter „Weitere Eingänge“.
  - Am echten System geprüft: IC-PCR1500 (Port 0x03114320) → Codec 0x03114310 korrekt gefunden. FT-991A war nicht angeschlossen.
  - Logiktests: 99 Prüfungen, darunter Umstecken, veraltete UID im Auftrag, beide Funkgeräte gleichzeitig.
  - Für M8 (Commander-Buttons): Die Commander schicken `source=` **und** die frisch ermittelte `device=`-UID ihres Codecs.
- **Hinweis:** Ändert sich der Mikrofon-Hinweistext in `build_app.sh`, fragt macOS die Freigabe neu ab.
- **M3 erledigt (v0.4.0 / 0.4.1):**
  - `Sources/DSP`:
    - `SpectrumAnalyzer`: vDSP-FFT mit Hann-Fenster, dBFS; ein Sinus der Amplitude 1 ergibt 0 dB.
    - `WaterfallProcessor`: Senke an der Pipeline, FFT 2048 bei 8 kHz, also 3,9 Hz je Bin; Vorschub 256 ergibt 31,25 Zeilen/s. Rauschboden = geglätteter Median.
    - `WaterfallColorMap`: Farbverlauf im RadioTheme, bgDeep → Blau → Cyan → Grün → Amber → Rot → Weiß.
  - `Sources/UI`:
    - `WaterfallModel`: 30 Hz, Bild 1024 × 360 Zeilen (≈ 11,5 s); Rauschen wird 8 dB über Schwarz dargestellt.
    - `WaterfallView`: Frequenzskala, Spektrumkurve, Wasserfall, Bandbreite und M/S-Marker, Klick oder Ziehen setzt die Mitte, Zoom 4 kHz / 2 kHz / 1 kHz / 500 Hz um die Mitte, Dynamik 20–90 dB.
  - `Sources/Models/RTTYSettings.swift`: `RTTYParameters` (Werte wie fldigi) und `RTTYPreset` (ham, dwd-kw, dwd-lw, custom). Mark = Mitte + Shift/2 wie in fldigi, `reverse` vertauscht.
  - `Sources/App/RTTYSettingsStore.swift`: Preset, eigene Parameter, Mittenfrequenz (100–3900 Hz, begrenzt, sodass Mark und Space im Band bleiben); wird gespeichert. Aufträge setzen Preset und `center`.
  - Die Preset-Knöpfe sind jetzt wählbar.
  - Logiktests: 133 Prüfungen, darunter Spektrum-Pegel/-Frequenz, Zeilenzahl, Farbskala, Presets laut Plan, Abstimmhilfe DWD LW (957,5 / 1042,5 Hz).
  - Am echten System geprüft: PCR-1500-Rauschen mit Durchlasskurve sichtbar; Auftrag `preset=dwd-lw&center=1500` setzt Marker auf 1458 / 1543 Hz.
  - **Nicht selbst geprüft** (keine Bedienrechte für Maus/Tastatur): Klick/Ziehen zum Abstimmen, Zoom- und Dynamik-Knöpfe, Preset-Knöpfe. Test durch den Nutzer steht aus.
- **M4 erledigt (v0.5.0):**
  - `Vendor/Fldigi`: Empfangsteil von fldigi 4.2.13 (`rtty_rx`, `fftfilt`, `gfft.h`) plus C-Schnittstelle `fldigi_rtty.h`.
    Herkunft, Dateizuordnung und **alle Abweichungen**: `Vendor/Fldigi/UPSTREAM_RTTY.md`.
    Maschinell geprüft: Die Signalverarbeitung ist zeilengleich mit dem Original. Abweichungen gibt es nur bei Einstellungen (cfg statt progdefaults), Ausgabe (Rückruf) und entfernter GUI.
  - `wf->powerDensity()` (Signalmaß für Squelch und S/N) aus dem fldigi-Wasserfall ist durch Goertzel auf denselben 1-Hz-Bins ersetzt.
  - Swift: `Sources/Decoders/RTTY/FldigiRTTYCore.swift` (Hülle, Optionen, Status, XY-Scope) und `RTTYSignalGenerator.swift` (AFSK mit Baudot, ITA2/US, Versatz, Rauschen mit S/N in 3 kHz).
  - `Package.swift`: C++-Target `FldigiRTTY` (C++17). Die Logiktests übersetzen den Kern mit.
  - Logiktests (158 Prüfungen): alle Presets sauber exakt, andere Mittenfrequenzen, Reverse, ITA2/US-Ziffern, nur Mark / nur Space, AFC (15 Hz Versatz, Mitte wird nachgeführt), Squelch, Rauschen.
  - **Gemessene Zeichenfehlerrate** (S/N in 3 kHz, synthetisch, Mittel aus 3 Läufen):

    | S/N | −12 dB | −9 dB | −6 dB | −3 dB | 0 dB | +6 dB |
    |---|---|---|---|---|---|---|
    | Amateur 45,45/170 | 60 % | 19 % | 1,1 % | 0 % | 0 % | 0 % |
    | DWD LW 50/85 | 66 % | 21 % | 1,7 % | 0 % | 0 % | 0 % |

    Ein Kommentar in fldigi nennt bei −9 dB 0,5 % Fehler, die S/N-Definition dort ist aber unbekannt. Deshalb ist die Werte-Tabelle **nicht** mit fldigi vergleichbar.
    Der echte Vergleich folgt in M6: dieselben WAV-Dateien durch fldigi und Digidec.
  - **Befunde für M5:**
    - Der „Filter Shape Factor“ in fldigi 4.2.13 ist wirkungslos, dort gilt fest K = 1,4. Digidec übernimmt 1,4, der Wert bleibt als Expertenoption einstellbar.
    - fldigi nutzt standardmäßig den **US-TTY**-Ziffernsatz. Für die DWD-Presets **ITA2** vorsehen und beim ersten Empfang prüfen.
    - Die fldigi-S/N-Anzeige ist bei starken Signalen niedrig oder negativ (Messfenster zwischen Mark und Space). Die Metrik (0–100) ist das bessere Anzeigemaß.
    - Bei DWD LW (85 Hz) erreicht die Metrik nur ≈ 30 → Squelch-Vorgabe für dieses Preset höchstens ≈ 20.
- **M5 erledigt (v0.6.0 / 0.6.1):**
  - `Sources/Decoders/RTTY/RTTYDecoder.swift`: fldigi-Kern als Senke der Pipeline. Alle Kern-Aufrufe laufen auf deren Verarbeitungs-Queue (`AudioPipeline.perform`). Text, Status und XY-Punkte werden thread-sicher mit `takeOutput()` abgeholt.
  - `RTTYController` (@MainActor): verbindet Einstellungen → Decoder (neu konfigurieren bei Parameter-/Optionsänderung, Mitte bei Handwahl), fragt mit 20 Hz ab.
    Die AFC führt die Mitte nach (`followAFC`), ausgenommen 0,3 s nach einer Handwahl, damit ein veralteter Status sie nicht zurücksetzt.
  - `ReceiveTextModel` + `ReceiveTextView` (NSTextView): Text wird nur angehängt, die Ansicht scrollt mit, wenn man am Ende steht. Obergrenze 200 000 Zeichen.
    CR, BEL und Steuerzeichen werden entfernt, LF bricht um. **Skalarweise**, weil Swift „\r\n“ als ein Character behandelt.
  - `DecodeLogger`: Tagesdateien `~/Documents/Digidec/Logs/RTTY-JJJJ-MM-TT.txt` (UTC), Kopfzeile je Sitzung bzw. Einstellungsänderung mit Preset, Parametern, REV, Mitte und Quelle. Standard: an.
  - Einstellungen (`RTTYSettingsStore`): `RTTYDecodeOptions` (AFC aus/langsam/normal/schnell, Squelch + Wert, Mark-Space/nur Mark/nur Space, Unshift on Space, Filter K, XY-Scope klassisch/pseudo).
    Reverse je Preset (REV-Knopf). `ita2` in `RTTYParameters`: DWD-Presets ITA2, Amateur US-TTY wie fldigi.
    Ändert man Übertragungsparameter eines festen Presets, wird eine Kopie als „Eigene“ angelegt.
  - UI:
    - Abstimmanzeige: XY-Scope (Kreuzellipse), Signalqualität 0–100 mit Squelch-Strich, S/N (fldigi-Formel), AFC-Fehler, Mitte.
    - Unter den Presets: REV / AFC / SQL, Squelch-Regler, Knopf für den Einstellungsdialog `RTTYSettingsSheet` (alle Optionen aus 5.1).
    - Empfangstext mit Aktivitäts-LED, LOG, Log-Ordner, Kopieren, Löschen.
  - Logiktests: 180 Prüfungen. Neu: Store-Logik, Speicherformat abwärtskompatibel, Optionen → Kern, Anzeige-Text, Log (Kopfzeile, Tageswechsel UTC) und **Ende-zu-Ende** 48 kHz → Resampler → fldigi-Kern → exakter Text (DWD LW, ITA2).
  - Am echten System: Live-Decodierung läuft (auf Rauschen ohne Squelch zufällige Zeichen wie in fldigi, Signalanzeige ≈ 2–4, Scope-Knäuel); Auftrag setzt Preset und Mitte.
  - v0.6.1: Wasserfall 260 pt, Scope 124 pt, Mindesthöhe 730 pt (Bildschirm des Nutzers 900 pt hoch).
  - **Nicht selbst geprüft:** Bedienung (Knöpfe, Regler, Einstellungsdialog, Kopieren/Ordner) – kein Zugriff auf Maus/Tastatur.
  - Beobachtung: Ohne Squelch wandert die AFC auf reinem Rauschen langsam (fldigi-Verhalten). Mit SQL an greift die AFC nur oberhalb der Schwelle.
- **Erster echter Empfang (30.09.2026, 19:22 UTC):** DDK2 4583 kHz über den PCR-1500 (LSB) sauber decodiert. Signalqualität 100, XY-Kreuz sauber, AFC hält bei ±0,1 Hz.
  Befund zur Polarität in Abschnitt 5.2. Vereinzelte Zeichen- und Umschaltfehler wie auf KW üblich.
- **Kleiner Fehler:** Die Statuszeile zeigt den letzten Auftrag („Preset dwd-lw · Mitte 1000 Hz“), auch wenn danach von Hand ein anderes Preset gewählt wurde. Soll den aktuellen Stand zeigen.
- **M7 erledigt (v0.7.0 / 0.7.1), vor M6 gezogen:**
  - `Sources/Rig/RigctlClient.swift`: POSIX-TCP zu `127.0.0.1:<Port>`, jede Sekunde **nur `f` und `m`**, Zeitlimit 1 s, Neuverbindung alle 3 s.
    `parse()` für das einfache rigctld-Protokoll, einschließlich „RPRT“-Fehlerzeilen.
    `defaultPort(for:)` liest einen geänderten Port aus den Einstellungen der Commander (`rigctldPort` bzw. `ft991aRigctldPort`), sonst 4532 / 4533.
  - `RigModel`: folgt dem Funkgerät, dessen Codec gerade gelesen wird (bei Dateiwiedergabe oder VALHost: keins). Der Port aus einem Auftrag hat Vorrang.
  - **Seitenband-Korrektur wie fldigi:** `RTTYParameters.reverse` bezieht sich jetzt auf USB. Die **DWD-Presets tragen `reverse = true`** (Mark auf der tieferen HF).
    Der Decoder bekommt `decoderParameters` mit `reverse xor LSB`. Kehrlage-Modes: LSB, PKTLSB, ECSSLSB, RTTY, CWR.
    `SidebandMode` AUTO (rigctld; unbekannt = USB) / USB / LSB, gespeichert. Schalter unter den Presets, Eintrag im Einstellungsdialog.
    Gespeicherte REV-Schalter aus älteren Versionen werden verworfen (neuer Schlüssel `rttyReverseByPreset2`).
  - Kopfzeile: `RigBadge` mit „IC-PCR1500 · 4.584,700 kHz · LSB“, grün = rigctld verbunden, gelb = nicht erreichbar, grau = kein Funkgerät.
  - Log-Kopfzeile mit Seitenband, Frequenz und Mode. Eine neue Kopfzeile entsteht bei jeder Änderung.
  - Statuszeile korrigiert: Links steht der aktuelle Decoder-Stand, rechts der letzte Auftrag mit Uhrzeit oder ein Fehler.
  - Logiktests: 203 Prüfungen, darunter Seitenband-Logik (DWD in LSB/USB), rigctld-Antworten und ein **echter TCP-Test gegen einen Test-rigctld**, der prüft, dass nur `f`/`m` gesendet werden.
  - Am echten System geprüft (19:29 UTC): PCR-1500 auf 4584,700 kHz LSB wird angezeigt. DDK2 decodiert nach dem Neustart ohne Eingriff weiter (REV aus Preset + A·LSB).
- **M8 erledigt (30.09.2026):**
  - **PCR-1500 Commander 0.21.1 → 0.22.0**, **FT-991A Commander 0.5.1 → 0.6.0.** Sicherung jeweils in `_Backup_<alt>_vor_Digidec/` (Quellen, Tests, GEMINI.md, altes App-Bundle).
  - Neu in beiden: `Sources/Models/DigidecLauncher.swift` (identisch) und `Sources/UI/DigidecHeaderButton.swift`. Der Knopf **DIGIDEC** steht in der Kopfzeile links neben HAMLIB. GEMINI.md beider Projekte hat einen Abschnitt „Anbindung an den Decoder Digidec“.
  - Menü:
    - „RTTY decodieren – DDK2 erkannt (Mitte 1700 Hz)“ bzw. „RTTY decodieren (Amateurfunk)“.
    - Dazu die drei Presets einzeln. Passt das gewählte Preset zum erkannten DWD-Sender, wird die Mitte mitgeschickt.
  - DWD-Erkennung: Sender liegt bei der Dial-Frequenz im NF-Durchlass 100–3900 Hz. USB: Mitte = Sender − Dial, LSB: Dial − Sender.
    Kehrlage: PCR `.lsb`; FT-991A `.lsb`, `.dataL`, `.rttyL`, `.cwL`.
  - Übergabe: `source=pcr1500|ft991a`, `rigctl=<Port>` (nur wenn der rigctld-Server aktiv ist), `device=<frisch ermittelte Codec-UID>` (Doppelpunkte als %3A), `center=`.
    Öffnen mit `NSWorkspace.OpenConfiguration.activates = true`. Ist Digidec nicht registriert, erscheint ein Hinweis.
  - Tests: PCR-Logiktests (22 111 Prüfungen) und FT-991A-Logiktests (76 Prüfungen) bestanden, darunter je 11 neue für den Launcher (DDK2/LSB → 1700 Hz, DDH47/USB → 1000 Hz, URL, UID-Rundreise).
    Im FT-991A-Test musste der feste Versionsvergleich (0.5.1) auf 0.6.0 nachgezogen werden.
  - Geprüft: Die vom Launcher erzeugte URL (DDK2, 4584,700 kHz LSB, PCR-Codec) wurde von Digidec angenommen: Preset DWD KW, Mitte 1700 Hz, Statuszeile „Auftrag von PCR-1500 Commander“.
  - **Nicht geprüft:** Klick auf den Knopf in den Commandern. Der PCR-1500 Commander lief mit der alten Version weiter und wurde nicht neu gestartet (Projektregel). Der FT-991A war nicht angeschlossen.
- **Befund Unshift on Space (v0.7.2):** Bei DWD-SYNOP-Meldungen (DDK2, 19:37 UTC) kamen die Zifferngruppen nach dem ersten Leerzeichen als Buchstaben („62198 QPPQY …“ statt „62198 10016 …“).
  Ursache: „Unshift on Space“ (fldigi-Standard an). Der DWD sendet FIGS nur einmal je Zeile. Die Option ist jetzt eine **Preset-Eigenschaft** (`RTTYParameters.unshiftOnSpace`): Amateur an, **DWD aus**.
  Sie steht im Einstellungsdialog unter „Übertragung“. Der Generator bildet beide Senderarten nach, und ein Test reproduziert das beobachtete Fehlerbild (209 Prüfungen).
  In fldigi müsste man für den DWD „RX – unshift on space“ ebenfalls ausschalten.
- **M6-Werkzeuge (v0.8.0):**
  - `InputRecorder` (Aufnahme über neue Roh-Senken `AudioPipeline.addRawSink`, Quellrate, 16 Bit mono) mit REC-Knopf und Begleitdatei `RecordingInfo` (.json).
  - `Tools/DecodeFile` (Offline-Decoder, ≈ 140× Echtzeit, Auswertung `--loop ddk2`, `--compare`) und `Tools/fldigi_rtty.py` (XML-RPC: prepare / status / fetch).
  - Ablauf in Abschnitt 8.0. Gefunden und behoben: Der Testgenerator verschluckte „\r\n“ (ein Character in Swift) → jetzt skalarweise.
  - Logiktests: 216 Prüfungen (Dateiname, Aufnahme Ende-zu-Ende 48 kHz → WAV, Begleitdatei).
- **M5b SYNOP-Klartext (v0.9.0, Wunsch des Nutzers):**
  - `Vendor/Fldigi`: SYNOP-Decoder aus fldigi 4.2.13 samt GNU-Regex, Koordinaten, Locator, Tabellen-Lader und Ersatzteilen für KML, ADIF und FLTK.
    Herkunft, Dateien und Abweichungen: `Vendor/Fldigi/UPSTREAM_SYNOP.md`.
  - **Zwei Fehler in fldigi gefunden und behoben:**
    1. Array-Zugriff mit Index −1 in `AddOtherTok` (Absturz)
    2. `mktime` statt `timegm` (UTC-Zeit um die Ortszeit verschoben)
  - Stationslisten (2,4 MB, alter fldigi-Stand) in `Resources/Synop`, im App-Bundle `Contents/Resources/Synop`. Sie werden beim Start auf der Verarbeitungs-Queue geladen.
  - `SynopDecoder.swift`: Hülle (Singleton wie in fldigi), Ausgabe als `TextSegment` (Rohtext / Klartext). UTF-8, weil synop.cpp „°C“ in UTF-8 enthält.
  - `RTTYDecoder`: Mit `options.synopDecoding` (Standard an) laufen die Zeichen wie in fldigi `rtty::rx()` durch den SYNOP-Decoder. Die Ausgabe erfolgt „interleaved“: Rohtext unverändert, Klartextblöcke dazwischen.
  - Anzeige: Klartext in Amber, 11,5 pt, eigene Zeilen, eingerückt. Schalter **SYNOP** in der Empfangstext-Leiste und im Einstellungsdialog. Das Log enthält beides.
  - `decode_file.sh --synop` schreibt `<aufnahme>.synop.txt`.
  - Logiktests: 232 Prüfungen, darunter die empfangene SHIP-Meldung 62170 (51,4° N 2,0° E, 20,2 °C, Taupunkt 19,3 °C, 1014 hPa, 18:00 UTC), Wuerzburg = WMO 10655 und der Weg DWD-RTTY → SYNOP-Klartext.
  - Offen:
    - Echter Empfang eines SYNOP-Blocks (DDK2: 00:35, 06:10, 12:10, 18:10 UTC Landstationen; SHIP 02:00, 07:35, 13:35, 19:35 UTC).
    - Deutsche Übersetzung der Klartexte (731 englische Texte) wäre eine eigene Aufgabe.
    - Stationslisten aktualisieren (neuere Quellen: OSCAR/WMO, NDBC).
- **Nächster Schritt:**
  - ~~Vergleich mit fldigi~~ → erledigt 30.09.2026: zeichengleich (Abschnitt 8.0).
  - Weitere Vergleiche bei schwierigen Bedingungen (Fading, DDH47 auf LW) sind sinnvoll, aber nicht zwingend.
  - Der Nutzer startet die Commander neu und prüft den Knopf DIGIDEC.
  - SYNOP-Zifferngruppen und ITA2 beim nächsten DWD-Block prüfen, DDH47 (LW) testen.
  - Danach M6 (Vergleich mit fldigi).

---

## 12. Offene Entscheidungen (vom Nutzer zu klären)

1. ~~**App-Name / Ordnername**~~ → **Digidec** (entschieden 30.09.2026).
2. ~~**Virtuelles Audiogerät als Standard**~~ → **VALHost 2ch** (eigener Treiber `Swift_2026/VALDriver`), entschieden 30.09.2026. Andere Geräte bleiben wählbar.
3. ~~**Versionsverwaltung**~~ → **lokales Git-Repository** im Projektordner, **ohne Remote** (kein GitHub o. Ä.), entschieden 30.09.2026. Keine `_Backup_*`-Ordner nötig.
4. **Änderungen an den Commandern** (Button „RTTY decodieren“) erst ab M8. Freigabe des Nutzers nötig, dann gelten deren Regeln.
5. ~~**fldigi-Quellstand**~~ → **v4.2.13** (Commit `e7c3ab37…`), Entscheidung dem Entwickler überlassen, festgelegt 30.09.2026.

---

## 13. Projektregeln (übernommen von den Commandern)

- Versionsschema Alpha: Start `0.1.0 Alpha`; Bugfix → dritte Zahl, neues Feature → zweite Zahl (dritte auf 0); erste Zahl bleibt 0.
- Version bei jeder Änderung in `Sources/App/AppVersion.swift` **und** `build_app.sh` (`CFBundleShortVersionString`, `CFBundleVersion`) erhöhen.
- Nach Änderungen bauen (`build_app.sh`). Versionsstände über **Git** sichern: je abgeschlossener Änderung ein Commit mit der Versionsnummer in der Nachricht; kein Remote, kein Push.
- Nach Änderungen am Decoder-Kern oder Audio: Logiktests ausführen (Exit-Code 0 = bestanden).
- Niemals Befehle an Funkgeräte senden. Der Decoder spricht nur lesend mit rigctld.
- Am Mac hängt ein Transceiver (CP2105, `/dev/cu.usbserial-01A22C9D*`) und der IC-PCR1500: Der Decoder öffnet **keine** seriellen Ports.
- Sprache für UI, Doku und Kommentare: Deutsch (wie Commander).

- **Umbau 01.10.2026:** Die fldigi-Teile sind jetzt **ein** Target `Fldigi` (`Vendor/Fldigi`, Übersicht `Vendor/Fldigi/UPSTREAM.md`), Vorbereitung für NAVTEX/CW/WEFAX.
  fldigis `complex.h` wurde in `fldigi_complex.h` umbenannt, weil es sonst mit `<complex.h>` des Systems kollidiert. Das trat erst auf, als C (GNU-Regex) und C++ im selben Target lagen.
  `Tools/build_fldigi.sh` baut den fldigi-Teil für Logiktests und `decode_file.sh`. Nachweis: 232 Logiktests, Offline-Decodierung der DDK2-Aufnahme unverändert 0,79 %.
- **M9 NAVTEX erledigt (v0.10.0 / 0.10.1, 01.10.2026; Nutzer unterwegs, nur theoretisch und synthetisch geprüft):**
  - Kern: `Vendor/Fldigi/src/navtex/navtex_rx.cpp`, erzeugt von `Vendor/Fldigi/port_navtex.py` aus fldigi `navtex.cxx` (reproduzierbar, bricht bei Abweichung des Originals ab).
    Rahmen `navtex_frame.inc` (Wasserfall-Ersatz `powerDensity`/`powerDensityMaximum`, Klasse `navtex`, Stationssuche, Testkodierung), C-API `fldigi_navtex.h`. Details: `Vendor/Fldigi/UPSTREAM_NAVTEX.md`.
  - `AudioPipeline`: Senken mit eigener Abtastrate (`addSink(rate:)`), ein Resampler je Rate. NAVTEX läuft mit 11 025 Hz, RTTY und Wasserfall mit 8 kHz.
  - Swift: `FldigiNavtexCore` (+ `NavtexMessage`, `NavtexSignalGenerator` mit fldigis FEC-Kodierung), `NavtexSettingsStore` (518/490/4209,5 kHz, REV, AFC, ITA2, Seitenband AUTO/USB/LSB, Locator JN49WS),
    `NavtexDecoder` (Senke 11 025 Hz), `NavtexController` (Text, Nachrichtenliste mit Station und Wiederholungserkennung 24 h, Log `NAVTEX-JJJJ-MM-TT.txt`).
  - App: Modul-Umschaltung RTTY/NAVTEX. Nur das gewählte Modul decodiert. Wasserfall über das Protokoll `TuningTarget`.
    NAVTEX-Karten: Abstimmanzeige (SUCHE/SYNC/EMPFANG, Signal, S/N), Einstellungen, Nachrichten. URL `digidec://decode?mode=navtex&preset=518|490|4209&center=…`.
  - Stationslisten liegen jetzt in `Resources/Stations` (SYNOP + NAVTEX_Stations.csv), weil fldigis Tabellen-Lader nur ein Datenverzeichnis kennt.
  - Synthetisch (S/N in 3 kHz): fehlerfrei bis −5 dB, −8 dB einzelne Fehler, −10 dB kein Empfang.
    Die AFC zieht wegen der 4:3 Mark/Space-Bits des CCIR-476-Codes 5–8 Hz Richtung Mark. Das ist fldigi-Verhalten, die Decodiergrenze ist mit und ohne AFC gleich.
  - Logiktests: 261 Prüfungen, darunter Kopf und Text exakt, Reverse, ITA2, −3 dB, Pinneberg als Station für L/518 kHz bei JN49WS, Pipeline 48 kHz → NAVTEX und abgeschaltetes Modul.
  - **Offen (braucht den Nutzer):**
    - Live-Empfang von 518 kHz (USB, Dial 517,000 kHz) mit dem PCR-1500.
    - Polarität bestätigen: Vermutlich ohne REV wie in fldigi. Bei Zeichensalat REV drücken.
    - Mikrofon-Freigabe nach dem Neustart erteilen (neue Version).
  - Mögliche Ergänzung in den Commandern: NAVTEX-Frequenzen (518/490/4209,5 kHz) im DIGIDEC-Menü erkennen. Das wäre eine Änderung an den Hauptprogrammen und braucht deren Regeln.
- **M10 CW erledigt (v0.11.0, 01.10.2026; Nutzer unterwegs, nur theoretisch und synthetisch geprüft):**
  - Kern: `Vendor/Fldigi/src/cw/cw_rx.cpp`, erzeugt von `Vendor/Fldigi/port_cw.py` aus fldigi `cw.cxx`. Die Empfangsfunktionen sind wörtlich herausgezogen (Klammerzählung), Senden und Tastung entfallen.
    Dazu `morse.cpp` (Tabelle mit Prosigns und Umlauten), `filters.cpp` (`C_FIR_filter`, `Cmovavg`), Umgebung `cw_compat.h`, C-API `fldigi_cw.h`. Details: `Vendor/Fldigi/UPSTREAM_CW.md`.
  - Verarbeitung wie fldigi: 8 kHz, FIR-Bandpass mit 512 Taps und Dezimierung 10, gleitender Mittelwert, Pegelnachführung (Attack/Decay), Hysterese 0,95/1,05.
    Geschwindigkeit aus Punkt-/Strichpaaren nachgeführt (Start ±10 WpM, Grenzen 5…50). Prosigns erscheinen als `<BT>`, `<AR>`, `<SK>` … in Amber. Ä, Ö, Ü sind aktiv (fldigi-Standard).
  - Swift: `FldigiCWCore` (+ `CWSignalGenerator`), `CWModule.swift` mit `CWSettingsStore` (Ton, Filter 50…500 Hz oder Matched Filter, Start-WpM, Nachführung, Attack/Decay, SQL, SOM), `CWDecoder` (8-kHz-Senke) und `CWController` (Text, Log `CW-JJJJ-MM-TT.txt`).
  - App: Modul CW in der Leiste. Karten: Abstimmanzeige (erkannte WpM groß, Hüllkurve mit Schwelle wie fldigis Digiscope, Signal, Filter, Ton), Einstellungen. Wasserfall: Klick setzt den Ton.
    URL `digidec://decode?mode=cw&center=…` (Preset `ham`).
  - Synthetisch (S/N in 3 kHz, 18 WpM): fehlerfrei bis +3 dB, bei 0 dB einzelne Fehler, −3 dB unbrauchbar. Mit Matched Filter (36 Hz) bei −3 dB fehlerfrei.
  - **fldigi-Verhalten, bewusst übernommen:**
    - Das erste Element nach völliger Stille wird oft falsch gelesen (aus „CQ“ wird „FQ“), weil die Pegelnachführung bei `agc_peak = 0` startet (Zeitkonstante ≈ 250 ms). Auf dem Band geht Rauschen voraus. Die Tests senden deshalb „VVV“ vorweg.
    - Signale außerhalb des Nachführbereichs (z. B. 35 WpM bei Start 18 → Bereich 8…28) werden zerhackt. Dann die Startgeschwindigkeit anpassen.
    - Die erkannte Geschwindigkeit liegt 1–2 WpM unter der gesendeten (weiche Flanken verlängern die Punkte).
  - Korrektur gegenüber fldigi: fldigi legt den CW-Empfänger einmal je Programmlauf an. Digidec setzt beim Anlegen die file-static-Variable `first_time` zurück, sonst bliebe das Filter eines zweiten Exemplars auf 1000 Hz.
  - `decode_file.sh <wav> --cw --center <Hz> [--wpm n] [--mf] [--compare text]` decodiert Aufnahmen offline.
  - Logiktests: 289 Prüfungen, darunter 12/18/22/35 WpM, feste Geschwindigkeit, Rauschen 10/3/0 dB, Matched Filter, Filtermitte, Prosign `<BT>` und Umlaute, Pipeline 48 kHz → CW und abgeschaltetes Modul.
  - **Offen (braucht den Nutzer):**
    - Live-Empfang, z. B. DK0WCY auf 10 144 kHz (Bake, Kiel) oder ein Amateurfunk-QSO im CW-Bandsegment. Der Empfänger steht dabei in CW oder USB, der Ton im Wasserfall wird angeklickt.
    - Vergleich mit fldigi auf derselben Aufnahme (wie bei RTTY): Aufnahme in Digidec, dann `decode_file.sh --cw --compare`.
- **M11 WEFAX erledigt (v0.12.0, 01.10.2026; Nutzer unterwegs, nur theoretisch und synthetisch geprüft):**
  - Kern: `Vendor/Fldigi/src/wefax/wefax_rx.cpp`, erzeugt von `port_wefax.py` aus fldigi `wefax.cxx`, mit dem Rahmen `wefax_frame.inc`.
    Der Rahmen enthält Wasserfall-Leistung per FFT wie fldigi, das Bild aus `wefax_map`/`wefax-pic` mit Auto-Zentrierung und Rauschentfernung sowie die Modem-Klasse. C-API `fldigi_wefax.h`. Details: `Vendor/Fldigi/UPSTREAM_WEFAX.md`.
  - **Fehler in fldigi behoben:** Die Zeilenlänge wird auf ganze Samples abgerundet (5512 statt 5512,5). Das gibt 0,166 Pixel Schräglauf je Zeile, rund 200 Pixel auf einem 1200-Zeilen-Bild.
  - **fldigi-Befund übernommen:** Die Leistungsmittel der Zustandserkennung wirken nicht (`decayavg` per Wert). Die Schwellen sind darauf eingestellt.
  - Swift: `FldigiWefaxCore` (+ `WefaxImage`, `WefaxSignalGenerator` nach WMO: APT 300/675 Hz, Phasing, APT-Stopp 450 Hz) und `WefaxModule.swift` mit
    - `WefaxStation`: DWD 3855 / 7880 / 13882,5 kHz, Hub 850 Hz laut fldigi-Kommentar, beim ersten Empfang prüfen
    - `WefaxSettingsStore`: IOC, LPM, Hub, Filter, AFC, Zentrierung, Entstörung, Schräglauf
    - `WefaxDecoder`: 11 025-Hz-Senke, Bildkopie für die Anzeige zweimal je Zeile
    - `WefaxController`: PNG nach `~/Documents/Digidec/WEFAX/` mit fldigis Dateinamen und Kommentaren, Galerie der letzten 30 Bilder
  - App: Modul WEFAX. Karten:
    - **Wetterfax:** Live-Bild, scrollt mit; AUTO-Speichern, Jetzt speichern, Ordner
    - **Abstimmanzeige:** Zustand, Korrelation, S/N, Mitte, Hub, LSB-Warnung; Knöpfe wie fldigi: APT überspringen, Phasing überspringen, Abbruch, Non-Stop
    - **Einstellungen**
    - **Bilder**

    URL `digidec://decode?mode=wefax&preset=dwd-7880|dwd-3855|dwd-13882|custom&center=…`.
  - WEFAX braucht **USB**. fldigis Empfänger kennt keine Umkehr, in LSB wäre das Bild negativ. Digidec warnt, wenn rigctld LSB meldet. USB-Dial = Frequenz − 1,9 kHz (7880 → 7878,1 kHz).
  - Synthetisch (S/N in 3 kHz):
    - ohne Rauschen: Abweichung 3,8 Graustufen, Zeilen gerade, Zeilenanfang 6 px Filterlaufzeit
    - +4 dB: sauber
    - −2 dB: Bild ohne Phasing-Ausrichtung
    - −6 dB: kein Bild
  - Logiktests: 316 Prüfungen. Darunter:
    - 240-Zeilen-Bild Ende zu Ende mit Schräglauf-Prüfung
    - Hub 850, IOC 288, +4 dB
    - Non-Stop, Speichern, Abbruch
    - PNG mit Kommentar
    - Pipeline 48 kHz → WEFAX
  - `decode_file.sh <wav> --wefax [--lpm 120] [--shift 850] [--center 1900] [--nonstop]` schreibt die Bilder als PNG neben die Aufnahme.
  - **Offen (braucht den Nutzer):**
    - Live-Empfang DWD, z. B. 7880 kHz (USB-Dial 7878,1 kHz) tagsüber oder 3855 kHz nachts. Sendeplan: dwd.de → Seefahrt → Funkfax.
    - Hub 850 Hz bestätigen: Bei Hub 800 Hz wirkt das Bild nur etwas kontrastreicher, falsch ist es nicht.
    - Vergleich mit fldigi auf derselben Aufnahme.
- **M12 FT8 erledigt (v0.13.0, 01.10.2026; Nutzer unterwegs, gegen WSJT-X-Referenzaufnahmen und synthetisch geprüft):**
  - **Quellenwahl nach Messung:** Gegen 353 WSJT-X-Decodes aus den Testaufnahmen von ft8_lib erreicht
    - ft8_lib 73,4 %, mit bestmöglichen Parametern 75,9 %,
    - **ft8mon** (Robert Morris AB1HL, MIT) 90,9 %, dank Mehrfachdurchgängen mit Subtraktion, OSD und CQ-Hinweisen.

    Übernommen ist deshalb ft8mon. FFTW ist durch pocketfft ersetzt (`compat/fftw3.h`), der Encoder aus ft8_lib dient nur für Testsignale. Digidec sendet nie.
    Eigenes Target `FT8` (`Vendor/FT8`, `port_ft8mon.py`, C-API `ft8_digidec.h`). Details: `Vendor/FT8/UPSTREAM_FT8.md`.
  - **Nachweis:** `Tools/FT8Reference/run_reference.sh` → **320 von 353 = 90,7 %** bei 3 s Rechenzeit. Von 67 Zusatzdecodes sind 10 als unsicher markiert, der Rest sind überwiegend echte Stationen.
  - **Unsichere Decodes** (unter 140/174 Bits oder unplausibles Rufzeichen) zeigt Digidec wie WSJT-X mit „?“ und abgedimmt; abschaltbar. `i3=…` wird verworfen.
  - Swift:
    - `FT8Core`: Decodieren, Testsignal, `FT8Message` als Parser (CQ/Antwort, Rufzeichen, Locator), `Maidenhead` mit Entfernung und Richtung
    - `FT8Module.swift`:
      - `FT8Band`: Dial-Frequenzen wie WSJT-X
      - `FT8SettingsStore`: Band, eigenes Rufzeichen, Locator, Rechenzeit, Zeitkorrektur, Rx-Frequenz
      - `FT8Decoder`: 12-kHz-Senke mit Zeitstempeln, decodiert nach UTC-Raster bei 14,6 s im Hintergrund; ist der vorige Zyklus noch nicht fertig, wird der neue ausgelassen
      - `FT8Controller`: Liste, Entfernungen von JN49WS, Log im ALL.TXT-Format `FT8-JJJJ-MM-TT.txt`
  - App: Modul FT8.
    - **Bandaktivität** wie WSJT-X: UTC, dB, DT, Freq, Meldung, km. CQ grün, Meldungen an das eigene Rufzeichen rot, unsichere grau. Filter „nur CQ“.
    - **Zyklus**: Sekundenanzeige, Fortschritt, Rx-Frequenz-Liste (Klick in den Wasserfall)
    - **Einstellungen**: Bänder 160–6 m mit Dial-Hinweis; zeigt bei Kopplung die Frequenz des Funkgeräts
    - URL `digidec://decode?mode=ft8&preset=20m|40m|…`
  - Synthetisch:
    - drei Stationen (0/−10/−16 dB) exakt, Frequenz ±3 Hz, DT ±0,12 s
    - −19 dB decodiert
    - überlappende Signale (15 Hz Abstand, 12 dB Unterschied) beide decodiert
    - Zyklus über die Pipeline mit simulierter Uhr: DT < 0,25 s
  - Logiktests: 363 Prüfungen.
  - **Offen (braucht den Nutzer):**
    - Live-Empfang, z. B. 20 m (Dial 14,074 MHz USB) oder 40 m (7,074 MHz).
    - Rechneruhr prüfen (automatische Zeit). Den mittleren DT der Stationen beobachten und die „Zeitkorrektur“ so einstellen, dass er bei 0 liegt (Startwert 0,2 s).
    - Optional mit WSJT-X auf demselben Signal vergleichen. Eine Aufnahme ab Zyklusbeginn lässt sich mit `decode_file.sh --ft8 --wsjtx` auswerten.
- **0.13.1 (01.10.2026): Layout-Prüfung ohne App-Start.** `Tools/UIPreview/render.sh <ordner>` rendert die Karten von CW, WEFAX und FT8 offscreen als PNG (ImageRenderer).
  Stepper und Textfelder erscheinen dort als Platzhalter, ScrollView-Inhalte fehlen; das ist eine Grenze von ImageRenderer.
  Gefunden und behoben:
  - WEFAX: LPM-Knöpfe brachen senkrecht um; neue Zeilen LPM / IOC+Hub / Filter.
  - WEFAX: Knöpfe „APT/PHASING überspringen“ jetzt mit Symbol; Abbruch als ✕.
  - CW: Attack/Decay waren zu schmal; jetzt je eine Zeile mit LANGSAM/MITTEL/SCHNELL.
  - Frequenzen erschienen mit deutschem Tausenderpunkt („1.234“): FT8-Tabelle, WEFAX-Hinweis und die Wasserfall-Skala (seit M3). Jetzt `Text(verbatim:)`.
- **0.13.2 (01.10.2026): Direkter Start per `digidec://open` & Entkopplung der Commander.**
  - `DecodeRequest`: Erkennt neben `decode` nun auch `open` als Aktion (`actionOpen = "open"`). Bei `open` ist `mode` optional (`module: DecoderModuleInfo?`, `presetID: String?`).
  - `DigidecState.handle(url:)`: Ist `request.module` nil, bleibt das aktuell aktive Modul unverändert. Quelle (`source`), Codec-UID (`deviceUID`) und rigctld-Port (`rigctlPort`) werden übernommen und die App in den Vordergrund geholt.
  - In beiden Commandern (FT-991A Commander 0.6.1 & PCR-1500 Commander 0.22.1) wurde das verschachtelte RTTY-Menü im Knopf **DIGIDEC** durch einen direkten Klick-Button ersetzt, der `DigidecLauncher.openURL(...)` aufruft. Die Wahl des Decoders (RTTY, NAVTEX, CW, WEFAX, FT8) erfolgt direkt in Digidec.
- **0.14.0 (01.10.2026): M13 DCF77 Atomzeit-Decoder.**
  - **Modulation & DSP-Kern:** 77,5 kHz AM-Impulsbreitenmodulation (Sender Mainflingen). Empfang über NF-Ton (Standard: 1.000 Hz, Empfänger z. B. auf 76,500 kHz USB). Quadraturmischer mit 2-stufigem IIR-Tiefpass (20 Hz Bandbreite) bei 8 kHz Abtastrate, automatische Pegelnachführung, Impulsdiskriminator (100 ms = Bit 0, 200 ms = Bit 1, Sekunde 59 = unmodulierte Synclücke).
  - **Telegramm-Parser & Validierung:** Paritätsprüfungen (P1 für Minute, P2 für Stunde, P3 für Datum), BCD-Decodierung, Sommerzeit-/Normalzeit-Erkennung (MESZ/MEZ), Ankündigung von Zeitwechsel und Schaltsekunde, Reserveantennen-Status, Wochentags-Plausibilisierung und Berechnung der Gangabweichung $\Delta t$ in Millisekunden gegen die Mac-Systemzeit.
  - **UI-Panels (`DCF77Panels.swift`):**
    - VFD-Atomzeitanzeige mit großen Leuchtziffern, Datum, Wochentag, MESZ/MEZ-Status
    - 60-Sekunden-Bit-Matrix mit Live-Sekundentakt und Farbcodierung (Bit 0/1/Sync/Invalid)
    - Live-Oszilloskop der AM-Hüllkurve mit gestrichelter Entscheidungsschwelle und SNR in dB
    - Abstimmanzeige mit Trägerpegel und SNR
    - Einstellungsfeld mit Frequenzführung (Prüfung gegen rigctld: 76,500 kHz USB) und manueller Tonwahl
    - Historie der empfangenen Minutentelegramme und automatisches Tageslog (`~/Documents/Digidec/Logs/DCF77-JJJJ-MM-TT.txt`)
  - **Signalgenerator & Tests:** `DCF77SignalGenerator` erzeugt vollständige synthetische 8-kHz-Audiosignale. 404 Logiktests fehlerfrei bestanden.
  - URL-Schema: `digidec://decode?mode=dcf77&preset=mainflingen&center=1000`.
- **0.15.0 (01.10.2026): M14 EFR Funkrundsteuer-Decoder (Langwelle 129,1 / 139,0 kHz).**
  - **Modulation & DSP-Kern:** 200 Baud FSK (Hub ±170 Hz / Shift 340 Hz, Zeichenrahmen 8E1). Quadraturmischer mit I/Q-Tiefpässen auf Mark (1.670 Hz) und Space (1.330 Hz), DPLL-Bit-Takt-Rückgewinnung bei 8 kHz Abtastrate, automatische Pegelnachführung, FSK-Diskriminator und UART-8E1-Slicing mit Paritätsprüfung.
  - **DIN 19244 / FT1.2-Parser:**
    - Variable Telegramme (`0x68 ... 0x16`) und feste Telegramme (`0x10 ... 0x16`) mit Prüfsummenvalidierung (Summe modulo 256).
    - CP56Time2a Zeitstempel-Parser (Sekunden, Minuten, Stunden, Tag, Monat, Jahr, Sommerzeit) mit $\Delta t$-Vergleich gegen die Mac-Systemuhr.
    - Versacom / Semagyr Schalttelegramm-Auswertung: Relaisbefehle, Laststufen und EEG-Einspeisemanagement (100 %, 60 %, 30 %, 0 % Abregelung).
  - **UI-Panels (`EFRPanels.swift`):**
    - Telegramm-Feed mit Titeln, Details, Zeitstempeln und zuschaltbarem Hex-Dump
    - Filter für Telegramme: „Alle“, „Nur Zeit“, „Nur Schaltung“
    - Live FSK-Diskriminator Oszilloskop (Mark/Space Signalverlauf)
    - Abstimmanzeige mit Mark/Space/Mitte-Frequenzen, SNR und Signalbalken
    - Sender-Presets: DCF49 Mainflingen (129,1 kHz), DCF39 Burg (139,0 kHz), HGA22 Lakihegy (135,6 kHz)
    - Frequenz-Leitfaden (Prüfung gegen rigctld: Dial 1,5 kHz unter Sollfrequenz in USB)
    - Tageslog (`~/Documents/Digidec/Logs/EFR-JJJJ-MM-TT.txt`).
  - **Signalgenerator & Tests:** `EFRSignalGenerator` erzeugt DIN-19244-Telegramme und FSK-Audiosignale. 433 Logiktests fehlerfrei bestanden.
  - URL-Schema: `digidec://decode?mode=efr&preset=dcf49|dcf39|hga22&center=1500`.
- **0.16.0 (01.10.2026): M15 FT4-Decoder (Fast FT8 für Contests, 7,5 s Slot).**
  - **Modulation & DSP-Kern:** 4-GFSK mit 20,8333 Baud (Symbolperiode 48 ms, Tonabstand 20,8333 Hz, Bandbreite ~83,3 Hz). STFT-Spektrogramm via kiss_fft (1152 Punkte), 4×4 Costas-Synchronisation, Kandidaten-Sucher im 7,5-s-Raster (Zeit- und Frequenz-OSR = 2), Beliefe-Propagation LDPC(174,91) Decoder und CRC-14 Prüfung aus `ft8_lib` (Kārlis Goba YL3JG, MIT).
  - **C-Schnittstelle (`ft4_digidec.c`, `ft8_digidec.h`):** Reentrante Zyklus-Decodierung (`ft4dd_decode_cycle`), threadsichere Rufzeichen-Hashtabelle für 10-/12-/22-Bit-Hashes, GFSK-Signalsynthesizer (`ft4dd_synthesize`), SNR-Berechnung normiert auf 2500 Hz WSJT-X-Referenzbandbreite.
  - **Swift-Module (`FT4Core.swift`, `FT4Module.swift`):**
    - `FT4Band`: Standard-Dial-Frequenzen wie WSJT-X (80m: 3,575 MHz, 40m: 7,0475 MHz, 30m: 10,140 MHz, 20m: 14,080 MHz, 17m: 18,104 MHz, 15m: 21,140 MHz, 12m: 24,919 MHz, 10m: 28,180 MHz, 6m: 50,318 MHz, 2m: 144,170 MHz, 70cm: 432,170 MHz).
    - `FT4SettingsStore`: Band, Rufzeichen, Locator, Zeitkorrektur, Rx-Frequenz, Conformance zu `TuningTarget`.
    - `FT4Decoder`: 12-kHz-Audiopipeline-Senke, 7,5-s-Cadence nach UTC-Raster, Decodierung bei 7,1 s nach Slotstart.
    - `FT4Controller`: Bandaktivität, Distanz-/Peilungsberechnung, ALL.TXT-Tageslog (`~/Documents/Digidec/Logs/FT4-JJJJ-MM-TT.txt`).
  - **UI-Panels (`FT4Panels.swift`):**
    - Bandaktivitäts-Tabelle (UTC, dB, DT, Freq, Meldung, km) mit Filtern (Nur CQ, ?, Log, Papierkorb)
    - 7,5-s-Zyklus-Timeline mit Live-Fortschrittsbalken und Empfangsstatus
    - Einstellungen-Panel mit Band-Buttons, eigenem Rufzeichen, Locator und Zeitkorrektur.
  - **Tests & Nachweis:** 452 Logiktests fehlerfrei bestanden (Synthese, Mehrstationen-Zyklus, Zeit- und Frequenzabweichungen, Pipeline-Resampling 48 kHz → 12 kHz, URL-Schema `digidec://decode?mode=ft4&preset=20m`).
- **0.17.0 (01.10.2026): M16 DXCC-Länder- und Zonenauflösung (AD1C cty.dat).**
  - **DXCC-Datenbank (`Resources/cty.dat` & `Sources/Models/DXCC.swift`):**
    - Standard AD1C Country File (357 KB, 346 DXCC-Gebiete, 21.800 Sonderrufzeichen mit `=`, 7.500 Präfixe).
    - Schneller In-Memory-Parser (< 20 ms), threadsicher (`@unchecked Sendable`, unveränderliche Dictionaries nach Init).
    - Zuordnung von Stationsrufzeichen über:
      1. Exakte Sonderrufzeichen (`=DP0GVN` für Neumayer III / Antarktis mit CQ 38 / ITU 67 Override)
      2. Portabel- und Betriebsarten-Modifikatoren (`/P`, `/M`, `/MM`, `/AM`, `/QRP`, `/R`, `/0`...`/9` etc.)
      3. Gastland-Präfixe (`SV9/DL1ABC` -> Kreta, `VE3/DL1ABC` -> Kanada)
      4. Gastland-Suffixe (`W1AW/KH6` -> Hawaii, `DL1ABC/VE3` -> Kanada)
      5. FCC-Sonderfall Guantanamo Bay (KG4): 2x3- und 2x1-Rufzeichen werden als US-Festland (K4) erkannt, nur 2x2-Rufzeichen als Guantanamo
      6. Längstes passendes Präfix (Longest Prefix Match)
      7. CQ- und ITU-Zonenüberschreibungen je Präfix/Rufzeichen
  - **Flaggen & Metadaten:**
    - Vollständiges Flaggenverzeichnis: Jedes der 346 DXCC-Gebiete verfügt über eine passende Flagge (z. B. 🇩🇪, 🇺🇸, 🇯🇵, 🇦🇶, 🌺 für Hawaii, 🏴󠁧󠁢󠁥󠁮󠁧󠁿/🏴󠁧󠁢󠁳󠁣󠁴󠁿/🏴󠁧󠁢󠁷󠁬󠁳󠁿 für UK-Nationen).
    - Ausgabe von Kontinent (EU, AS, AF, NA, SA, OC, AN), UTC-Zeitzonenabweichung und WGS84-Koordinaten.
  - **Integration in FT8 & FT4:**
    - `FT8Entry` / `FT4Entry` erweitert um `dxcc: DXCCEntity?`.
    - `FT8Controller.poll()` / `FT4Controller.poll()` lösen den Absender (`m.sender`) automatisch auf.
    - Bandaktivitäts-Tabellen (`FT8Table` / `FT4Table`): Neue Spalte `DX` mit Flaggen-Emoji.
    - Tooltips: Anzeige von Flagge, Land, Kontinent, CQ-Zone und ITU-Zone beim Überfahren der Tabellenzeile.
  - **Tests & Nachweis:**
    - 502 Logiktests fehlerfrei bestanden (+50 Tests für DXCC-Auflösung, DL-, US-, JA-, Antarktis-, Kreta-, Hawaii-, Portabel- und Guantanamo-Sonderfälle).
    - Release-Bundle `Digidec.app` (0.17.0 Alpha) gebaut, signiert und mit `cty.dat` paketiert.
- **0.18.0 (01.10.2026): M17 SSTV-Decoder (Slow-Scan-Television).**
  - **Betriebsarten:** Martin 1/2, Scottie 1/2/DX, Robot 36/72, PD 90 (320×256), PD 120/180 (640×496), Wraase SC2-180. Zeitdaten aus den Originalspezifikationen; jede Zeile wird als Liste von Abschnitten relativ zum **Ende des 1200-Hz-Sync** beschrieben (bei Scottie liegen Grün und Blau *vor* dem Sync).
  - **Demodulator:** Quadratur-FM-Diskriminator bei 12 kHz, Tiefpass 4. Ordnung (Restwelligkeit < 3 Hz), Gleitmittel mit Zustand über Blockgrenzen. VIS-Detektor mit 2-ms-Vorglättung, Paritäts- und Stoppbitprüfung.
  - **Engine (`SSTVCore.swift`):** Sync-Impuls = geglättete Frequenz < 1350 Hz mit Längenprüfung; Erwartungsfenster ±10 % einer Zeile (max. ±25 ms), darin gewinnt der zur Erwartung nächste Impuls; Flywheel bei Ausfall, Zeilennummer an die Zeit gebunden. Erfassung ohne VIS braucht zwei gleichabständige Impulse, nach 4 verpassten Zeilen rastet sie mit zwei Impulsen wieder ein. Nach VIS-Start Abbruch erst nach einem Viertel der Bildlänge ohne Sync, im manuellen Modus nie. Robot 36 führt R-Y/B-Y über das Zeilenpaar zusammen (Zeilenparität aus dem Trennimpuls).
  - **Module/UI:** `SSTVSettingsStore` (Kanäle 20/40/80/10 m, ISS 145,800 MHz, 2 m, Slant, Zeilensync nachführen, Signalmitte als Frequenzversatz), `SSTVDecoder`/`SSTVController` (Konfiguration nur bei echter Änderung), `SSTVPanels.swift` (Live-Bild, Fortschritt, Galerie, PNG-Ablage `~/Documents/Digidec/SSTV`). URL: `digidec://decode?mode=sstv&preset=20m|40m|80m|10m|iss|2m|custom&center=…`.
  - **Nachweis:** Pixel-Roundtrip aller 11 Modi (Ø-Kanalfehler ≤ 0,3/255), dazu Taktfehler +300 ppm, Rauschen ≈ 15 dB S/N in 3 kHz, 1,5 s Ausfall, Signalabbruch, VIS mit falscher Parität. **Echtes Signal:** `SSTV_Scottie_1_LSB` (sigidwiki, I/Q 32 kHz, selbst nach LSB-Audio gewandelt) wird als Bild „CQ DX / SLOW SCAN TV / EA2AFL“ lesbar dekodiert; Abstand der Syncimpulse 5138–5141 Samples = 0,4282 s wie spezifiziert. Der Mitschnitt hat Fading und Zeitsprünge (Zeilenversätze unten). Offen: Robot und PD ohne echte Gegenprobe.
- **0.18.1 (01.10.2026): Nacharbeiten FT4, EFR, DCF77 (Prüfung gegen Messung und echte Aufnahmen).**
  - **FT4:** DT hatte einen Bias von +0,55 s: jetzt wie bei FT8 relativ zum Sendebeginn 0,5 s nach Zyklusbeginn (gemessen +0,004 s). SNR-Schätzung neu: gesendeter Ton gegen Rauschbins neben der Tonspanne, auf 2500 Hz kalibriert (über 34 dB linear, Streuung ±0,5 dB; vorher bei 0 dB um 5 dB daneben), nach unten auf −30 dB begrenzt. `correct_bits` aus dem LDPC-Ergebnis statt fest 174. **Echte Aufnahmen** (sigidwiki, `FT4_wsjtx.ogg`, `FT4_on_10m.ogg`): `CQ AB1CDE JO01` und 20 verschiedene Meldungen mit plausiblen Rufzeichen. **Grenze:** Empfindlichkeit etwa −14 dB (50 %), WSJT-X −17,5 dB; liegt am LDPC-Decoder von ft8_lib, Parameter (Oversampling, Kandidaten, Iterationen) ändern nichts. Abhilfe nur über ft8mon-Decodierstufe (OSD, Mehrfachdurchgang) für FT4.
  - **DCF77:** Schmitt-Trigger statt einer Schwelle, Flankenflattern zählte Sekunden falsch hoch; Sekundenfortschaltung bei verpassten Impulsen war falsch gerundet; Schwellen aus dem Trägermittelwert statt dem Spitzenwert (Rauschspitzen hoben die Schwelle an). SNR-Anzeige war bedeutungslos (Dip-Tracker konnte nur sinken): jetzt Träger gegen Rauschkanal bei +120 Hz (30 dB → 30,3 dB, 20 dB → 20,4 dB). BCD-Ziffern > 9 und unmögliche Daten (31. April) werden abgewiesen. Nach einem gültigen Telegramm wird die Folgeminute vorhergesagt; ein gestörtes Telegramm mit ≤ 2 abweichenden Bits gilt als bestätigt (`confirmedByPrediction`): bei 15 dB S/N in 20 Hz 6 von 8 Minuten statt 0. Δt zur Systemzeit um die Ansprechverzögerung (≈ 13 ms) korrigiert; die Audiopuffer-Latenz bleibt unbekannt. **Offen:** keine Frequenznachführung (Mitte muss auf ≈ ±10 Hz stimmen).
  - **EFR:** Die in 0.15.0 beschriebene Deutung von Nutzdaten („Leistungsstufe 100 %“ bei Byte 0x64 usw.) war geraten und ist **entfernt**; Nutzdaten erscheinen als Hex, Versacom/Semagyr sind herstellerspezifisch und nicht entschlüsselt. Ein Zeitfeld (CP56Time2a) zählt nur noch innerhalb ±36 h um die Systemzeit (zufällige 7 Byte sahen in ≈ 40 % der Fälle wie ein Datum aus). Rauschkanal abseits der Töne, Squelch (kein Byte-Müll im Rauschen: 1 statt 99 Bytes in 60 s), echte SNR-Anzeige. Parameter laut sigidwiki bestätigt (FSK, 340 Hz, 200 Bd, USB); **unbelegt:** Rahmenformat DIN 19244 und Zeitfeldformat im EFR-Telegramm, keine echte Aufnahme.
  - **Tests:** 696 Logiktests (neu: FT4 DT/SNR/Empfindlichkeit mit synthetischem Weißrauschen, DCF77 BCD/Datum/Vorhersage/Rauschen, EFR Rauschen/Squelch/Zeitfenster).
- **Nächste Schritte:**
  - Live-Tests aller Module durch den Nutzer (RTTY, NAVTEX, CW, WEFAX, FT8, FT4, DCF77, EFR, SSTV).
  - PSK31 / PSK63 (BPSK-Amateurfunk-Textübertragung auf Kurzwelle).

