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
- **Standardmäßig nur lesend.** Nie Befehle senden, die das Gerät umstimmen, außer der Nutzer schaltet das ausdrücklich frei.
  **Freigabe seit 0.19.0 (Entscheidung des Nutzers, 01.10.2026):** Schalter **QSY AUTO** in der Kopfzeile (Standard aus, gespeichert). Dann sendet Digidec beim Moduswechsel und beim Wechsel von Band/Kanal/Sender genau zwei Stellbefehle an den rigctld des Commanders: `F <Dial-Hz>` und `M <Mode> <Bandbreite>`. Die Commander setzen das in ihren eigenen Zustand um (`onSetFrequency` → `tuneTo`, `onSetModeAndFilter`), ihre Anzeige folgt. Nie gesendet wird PTT (`T`), Leistung, Lautstärke u. a.; `RigCommand` lässt nur `F` und `M` mit geprüften Werten zu. Nach einem Auftrag per URL stimmt Digidec 2 s lang nicht nach (der Commander hat das Gerät dann selbst eingestellt).

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
| CW-Skimmer, PSK-Skimmer (alle Signale im Audio zugleich) | eigene Umsetzung (Anregung: KZ4AP Skimmer, GPL-3.0, nur gelesen; Gegenprobe fldigi) | Swift | erledigt (0.45.0) |
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
| Radiosonden | zilog80/radiosonde | C | RS41 erledigt (0.46.0, eigene Umsetzung); M10/M20, DFM u. a. offen |
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
| M18 | QSY | ✅ 01.10.2026 (v0.19.0): Funkgerät folgt dem Modul über den rigctld des Commanders (nur `F` und `M`), Schalter in der Kopfzeile |
| M19 | WEFAX-Sendeplan | ✅ 01.10.2026 (v0.20.0): DWD-Radiofax-Sendeplan aus dem Netz (Knopf „Aktualisieren“), Plan-Fenster, Auswahl von Sendungen zur automatischen Aufnahme |
| M20 | Sendepläne RTTY und NAVTEX | ✅ 01.10.2026 (v0.23.0): gemeinsames Plan-Fenster (WEFAX, RTTY, NAVTEX), RTTY-Plan aus den DWD-PDFs mit „Aktualisieren“, NAVTEX nach IMO-Raster, gemeinsame automatische Aufnahme |
| M21 | WSPR | ✅ 01.10.2026 (v0.24.0): wsprd aus WSJT-X (`Vendor/Wspr`, pocketfft statt FFTW), 2-Minuten-Zyklus, 16 Bänder, Spotliste mit Entfernung/DXCC/Leistung, Typ 1/2/3 mit Hashtabelle, ALL_WSPR-Log; auf dem WSJT-X-Beispiel dieselben 8 Meldungen wie das Original; Live-Empfang durch den Nutzer offen |
| M22 | PSK | ✅ 01.10.2026 (v0.25.0): fldigi-PSK-Empfänger (`Vendor/Fldigi/src/psk`): BPSK31/63/125/250 und QPSK31/63/125/250, AFC, Squelch, DCD, S/N und IMD, Phasenvektor, Bänder für QSY, Log, `decode_file.sh --psk`; synthetisch geprüft, Live-Empfang offen |
| M23 | Olivia, Contestia, MT63 | ✅ 01.10.2026 (v0.26.0): Jalocha-Bibliotheken aus fldigi (`src/olivia`, `src/mt63`) mit Empfangsrahmen; Olivia/Contestia 4–64 Töne × 125–2000 Hz, MT63 500/1000/2000 Hz kurz/lang; Wasserfall-Klick setzt die Mitte; synthetisch geprüft, Live-Empfang offen |
| M24 | DSC | ✅ 01.10.2026 (v0.27.0): Digitaler Selektivruf MF/HF (ITU-R M.493, 100 Bd / 170 Hz) in Swift; an echter 8414,5-kHz-Aufnahme (5 Küstenfunk-Testrufe, alle ECC OK) und an aufgezeichneten Symbolfolgen geprüft; Meldungsliste, Seenot hervorgehoben, Mittennachführung, Kanäle für QSY |
| M25 | ALE | ✅ 01.10.2026 (v0.28.0): ALE 2G (MIL-STD-188-141, 8-FSK 125 Bd) in Swift nach der MIT-Referenz openALE; Golay, 16 Taktlagen, Raster-Prüfung, Adressen und Klartext, Frequenznachführung; an einer echten 30-s-Aufnahme geprüft (3 Aussendungen, 38 Wörter, lesbarer Klartext) |
| M26 | APRS | ✅ 02.10.2026 (v0.29.0): AFSK 1200 Bd / AX.25 in Swift (Herkunft, Aufbau, Zahlen: `Vendor/Aprs/UPSTREAM_APRS.md`); auf der WA8LMF-TNC-Test-CD so gut wie Dire Wolf (1006 gegen 1005 Pakete auf 40 min Verkehr, 996 gegen 982 auf de-emphasiertem Audio); Parser für Position (unkomprimiert, komprimiert), Mic-E, Objekte, Nachrichten, Wetter, Telemetrie, NMEA; Stationsliste, Protokoll, Nachrichten; Kanäle EU/NA/ISS/AU/JP mit FM-Abstimmung |
| M27 | Kartenanzeige | ✅ 02.10.2026 (v0.29.0): gemeinsame MapKit-Karte (`Sources/UI/MapPanel.swift`) mit Punkten, Wegen, Großkreislinien, Reichweitenkreisen, Standort (ein Locator für alle Module), Auswahl, Kartenstil; Umschalter **LISTE · KARTE · BEIDE** in der Kopfzeile (BEIDE: Liste bzw. Wetterfax-Bild oben, Karte darunter; je Modul gemerkt); für APRS, FT8, FT4, WSPR, DSC, NAVTEX, RTTY (SYNOP, Rufzeichen), CW/PSK/Olivia/MT63 (Rufzeichen im Text), WEFAX/DCF77/EFR (Sender); ohne Ortsdaten: SSTV, ALE |
| M28 | Funkruf POCSAG und FLEX | ✅ 02.10.2026 (v0.30.0): POCSAG 512/1200/2400 und FLEX 1600/3200 (2 und 4 Pegel) in Swift (`Vendor/Pager/UPSTREAM_PAGER.md`); an den echten multimon-ng-Aufnahmen (POCSAG ×3, P2000-FLEX mit 44 Meldungen samt Gruppenrufen) gleiche Ergebnisse wie multimon-ng, bei Rauschen und wechselstromgekoppeltem Audio besser; Rufnummernliste mit Hervorhebung, Log |
| M29 | Töne (DTMF, Selektivruf) | ✅ 02.10.2026 (v0.30.0): DTMF, ZVEI 1/2/3, DZVEI, PZVEI, CCIR, EEA, EIA gleichzeitig, Goertzel-Erkennung, Tonfolgenliste, Log |
| M30 | ACARS | ✅ 02.10.2026 (v0.31.0): AM-Audio, MSK 2400 Bd (`Vendor/Acars/UPSTREAM_ACARS.md`); an der echten acarsdec-Aufnahme alle 7 Meldungen wie dort; Flugzeugliste, OOOI-Berichte, Karte mit Start- und Zielflughäfen (OurAirports, gemeinfrei), Bitfehlerkorrektur über Prüfsumme |
| M31 | UKW-DSC Kanal 70 | ✅ 02.10.2026 (v0.32.0): Teil des DSC-Moduls (Kanal „K70“, 156,525 MHz, FM): 1200 Bd, Y 1300 Hz / B 2100 Hz; gleiche Zeichen-, Phasing- und ECC-Logik wie MF/HF; AFSK-Demodulator im Rohbit-Betrieb |
| M32 | MFSK, DominoEX, Thor | ✅ 02.10.2026 (v0.33.0): ein Modul „MFSK“ mit 35 Betriebsarten aus fldigi 4.2.13 (`Vendor/Fldigi/UPSTREAM_MFSK.md`); Text, Rufzeichenkarte, Abtastraten 8000/11025/16000 Hz |
| M33 | SELCAL | ✅ 02.10.2026 (v0.34.0): im Modul TÖNE als weitere Norm (ARINC 714, 16 Töne 313–1479 Hz, zwei Impulse mit je zwei Tönen); Hann-Fenster 80 ms, Anzeige „AB-CD“ |
| M34 | Throb, IFKP, FSQ | ✅ 02.10.2026 (v0.35.0): drei weitere Familien im Modul „MFSK“ (14 Betriebsarten, jetzt 49); 12- und 16-kHz-Senken |
| M35 | Hell | ✅ 02.10.2026 (v0.36.0): Feld Hell, Slow Hell, X5, X9, FSK Hell 245/105, Hell 80 aus fldigi; Bildanzeige (Raster) mit PNG-Export |
| M36 | PSKR und 8PSK | ✅ 02.10.2026 (v0.37.0): im Modul PSK 4 PSKR- und 11 8PSK-Betriebsarten (mit FEC, 16 kHz); Sendeseite von fldigi für das Testsignal |
| M37 | RTTY: DWD-Frequenzwahl | ✅ 02.10.2026 (v0.38.0): Knöpfe für die DWD-Sendefrequenzen unter den Presets DWD KW und DWD LW; stellt bei QSY AUTO das Funkgerät (USB-Dial = Frequenz − NF-Mitte) |
| M38 | App-Icon | ✅ 02.10.2026 (v0.39.0) |
| M39 | RTTY-Karte: SYNOP ohne Kopfzeile, Wertansicht | ✅ 02.10.2026 (v0.40.0): SYNOP-Meldungen werden auch mitten im Block erkannt; Karte zeigt Temperatur, Luftdruck, Wind und Sicht als Zahl an der Station |
| M40 | RTTY-Karte: Seegebiete, Wetterlage, Warnungen, Schiffe | ✅ 02.10.2026 (v0.41.0): Ansicht „SEE“ mit Seewetterbericht je Gebiet (deutsch), Hochs, Tiefs, Fronten, Sturmwarnungen, Positionen aus Warnnachrichten; Schiffs- und Bojenmeldungen mit Weg |
| M41 | RTTY-Mitte gegen AFC-Drift, DWD-Punktvorhersagen | ✅ 03.10.2026 (v0.42.0/0.42.1): Mittenfrequenz wird nicht mehr durch die AFC gespeichert; 5-Tage-Punktvorhersagen mit Wassertemperatur (FQEN75–79) auf der Karte; Audioquellen-Auswahl |
| M42 | Wege auf der Karte: APRS und ACARS | ✅ 03.10.2026 (v0.43.0): ACARS liest Positionen aus den Meldungen (29 Formate nach airframes.io), zeichnet Flugzeuge mit Weg; APRS-Wege kräftiger, ohne GPS-Rauschen, mit Zoom auf den Weg und Schalter SPUR |
| M43 | Funkruf: Prüfung, Diagnose, Aufnahme | ✅ 03.10.2026 (v0.44.0): POCSAG unter nachgebildeten Funkbedingungen gemessen (Prüfstand `Tools/PagerBench`, Gegenprobe multimon-ng): Empfänger fehlerfrei, liest wechselstromgekoppeltes und Sprachband-Audio, wo multimon-ng nichts liest; Diagnose im Panel (Pegel, Vorspann, Synchronwörter, Stapel), REC, Umlaute |
| M44 | CW- und PSK-Skimmer | ✅ 03.10.2026 (v0.45.0, v0.45.1): neues Modul SKIMMER liest alle CW-, BPSK31- und BPSK63-Signale im Audio zugleich (Spektrum, Spuren, ein Kanal je Signal); Rufzeichen, Land, Rauschabstand in 500 Hz, Tempo, Spots wie im Reverse Beacon Network, Karte, Markierungen im Wasserfall; Prüfstand `Tools/SkimBench`; synthetisch 9 CW-Signale und je 6 PSK-Signale fehlerfrei gefunden, echte Aufnahmen nur teilweise lesbar (`Vendor/Skimmer/UPSTREAM_SKIMMER.md`) |
| M45 | Radiosonden (RS41) | ✅ 03.10.2026 (v0.46.0): neues Modul SONDE decodiert Vaisala RS41 aus FM-Diskriminator-Audio (Reed-Solomon, Rahmenblöcke, Kalibrierung); echte Aufnahme: alle Rahmen, Werte identisch mit rs41mod; robust gegen Rauschen, De-Emphase, Hochpass, Sprachband, Ablage, Taktabweichung (Entzerrer); Liste, Karte mit Weg, Landeprognose, Höhenverlauf, Log, REC; `Vendor/Sonde/UPSTREAM_SONDE.md` |
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
- Befehle an Funkgeräte: standardmäßig keine, der Decoder liest nur. Nur wenn der Nutzer den Schalter **QSY AUTO** einschaltet, sendet Digidec ausschließlich `F` (Frequenz) und `M` (Mode) an den rigctld des Commanders (Abschnitt 3.2), niemals PTT oder anderes.
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
    - ~~Versacom / Semagyr Schalttelegramm-Auswertung: Relaisbefehle, Laststufen und EEG-Einspeisemanagement~~ (Korrektur 0.18.1: geraten und entfernt, Nutzdaten werden als Hex gezeigt).
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
- **0.18.2 (01.10.2026): Prüfung an echten Aufnahmen aus dem Internet (SSTV, DCF77, EFR) – EFR-Polarität und Zeitformat korrigiert.**
  - **Quellen der Testsignale (nur lokal, nicht im Repo, außer der EFR-Datei):** SSTV: `SSTV_Scottie_1_LSB.7z` (sigidwiki, I/Q 32 kHz, selbst nach LSB-Audio gewandelt); ISS-Aufnahmen von Space Comms KG4AKV (5× PD180 2015/16, 2× PD120 2017, `spacecomms.wordpress.com`, mp3); Fram2Ham-Testdateien `Slide01/02.wav` (Robot 36, `ariss-usa.org/ARISS_SSTV/Fram2Test`). DCF77: `dcf_77_1.wav` (7119 Hz) und `dcf_77_2.wav` (12 kHz) aus `artyomsoft/time-signals-decoder`. EFR: `sample*.wav`, `c_sample*.wav` aus `mryndzionek/dcf39_decoder` (MIT, WebSDR Twente). FT4: sigidwiki (siehe 0.18.1). Die kleinste EFR-Datei liegt umgerechnet auf 8 kHz in `TestData/EFR` (mit Lizenz) und ist Teil der Logiktests.
  - **EFR (Fehler, den Synthetiktests nicht finden konnten):** Mark/Space waren vertauscht. Laut DK8KW und dem Fremddecoder liegt **Mark bei der unteren** Frequenz (DCF39: Mark 138,830 kHz, Space 139,170 kHz; in USB ist Mark der tiefere NF-Ton). Zusätzlich laufen jetzt zwei Empfangszweige (normale und invertierte Polarität), der richtige liefert Telegramme (Seitenbandfehler LSB/USB werden abgefangen, `polarityInverted`). Das Zeitfeld ist **kein** CP56Time2a, sondern: Adressen A1 = A2 = 0, Nutzdaten `00, Sekunde<<2, Minute, Stunde | Sommerzeit<<7, Wochentag<<5 | Tag, Monat, Jahr` (Wochentag 0 = Sonntag), geprüft mit Wochentag und Kalender. Telegramme zeigen Nummer (oberes Nibble des Steuerbytes), A1, A2 und Nutzdaten. Ergebnis an echten Aufnahmen: Telegramme Byte für Byte wie im Fremddecoder (`68 08 08 68 27 A3 A3 60 10 F2 9D CF 3B 16`), Zeittelegramme `Mi 16.04.2025 20:23:12 MESZ` identisch. Hinweis aus Wavecom: Telegramme werden zweimal gesendet; Versacom/Semagyr bleiben ungedeutet.
  - **SSTV:** Echte ISS-Aufnahmen: alle 7 (PD180 und PD120) werden per VIS erkannt und mit 496 Zeilen komplett dekodiert, Bilder farbrichtig. Robot 36 (Fram2Ham): VIS erkannt, Bild korrekt; die letzte Zeile fehlt nur, weil die Datei direkt nach dem Bild endet. Dabei fiel ein grüner Rand rechts bei Robot 36 auf (Übergang zum Sync ist ±6 Samples breit): Abtastpunkte halten jetzt 6 Samples Abstand zu den Rändern eines Abschnitts. Scottie 1: siehe 0.18.0.
  - **DCF77:** Echte Aufnahmen (193 s und 313 s): 7 aufeinanderfolgende Minutentelegramme richtig dekodiert (Sonntag 25.06.2023 22:29–22:42 MESZ), 0 ungültige Bits, SNR 28/37 dB.
  - **Tests:** 708 Logiktests (neu: echte EFR-Aufnahme, Zeittelegramm-Format, Polarität, Testtelegramm mit Sendername). Nicht im Repo, weil Lizenz unklar: SSTV-, DCF77-, FT4-Aufnahmen.
- **0.18.3 (01.10.2026): DCF77 und EFR: Frequenznachführung, optimaler EFR-Detektor, robustere Minutensynchronisation.**
  - **DCF77:** Frequenznachführung (AFC, Fangbereich ±100 Hz): ein breiter Kanal (≈ 100 Hz) misst die Phasendrehung des Trägers über 16 Samples und führt die Mischfrequenz nach (anfangs gesperrt, nur bei vollem Träger). Echte Aufnahmen bei absichtlich falscher Mitte (±45 Hz): dieselben Telegramme; im Rauschen (20 dB in 20 Hz) bei Träger +30 Hz mit AFC ≥ 4 von 6 Minuten, ohne AFC ≤ 2. Minutensynchronisation: eine 2-s-Lücke gilt nur als Minutenmarke, wenn die Sekundenzählung bei 55…59 steht oder sie genau eine Minute nach der letzten Marke kommt; ein einzelner ausgefallener Impuls verwirft die Minute nicht mehr (sie wird über die Vorhersage bestätigt). Träger länger als 5 s weg: Synchronisation wird verworfen. Impulsbreiten der echten Aufnahmen: 0-Bits 95–99 ms, 1-Bits 189–198 ms (Schwellen bei 145/155 ms mit großer Reserve). Anzeige: AFC-Versatz und nachgeführter Ton.
  - **EFR:** Bitentscheidung jetzt mit angepasstem Filter (Integrate-and-Dump über genau eine Bitdauer, Energie Mark − Energie Space = optimaler nichtkohärenter FSK-Detektor) statt Hüllkurvendifferenz am Bitmittelpunkt. Frequenznachführung (±80 Hz) aus der Phasendrehung des jeweils aktiven Tons, anfangs schnell. Vergleich mit dem Fremddecoder an drei echten Aufnahmen: Telegrammlisten identisch (vorher fehlte in `sample2` je nach Mitte ein Telegramm). Alle fünf echten Aufnahmen bei verschiedenen Startmitten (±150 Hz): 112 von 112 Telegrammen. Mit zusätzlichem Rauschen deutlich besser als das einstufige Hüllkurvenfilter (z. B. 21/21 statt 18/21 bei 10 % Rauschamplitude, 18 statt 1 bei 28 %). Wiederholungen (EFR sendet doppelt) werden am ersten Eintrag mitgezählt (`×2`) und nicht erneut geloggt. Anzeige korrigiert: MARK links (untere Frequenz), SPACE rechts, nachgeführte Töne, AFC, Hinweis „Polarität invertiert (LSB?)“.
  - **Tests:** 729 Logiktests (neu: AFC bei beiden Modulen, echte EFR-Aufnahme bei falscher Mitte, ausgefallener DCF77-Impuls, Wiederholungszusammenfassung).
  - **Weiterhin offen:** DCF77: die Δt-Anzeige kennt die Audiopuffer-Latenz nicht; Meteotime-Wetterbits werden nicht gedeutet. EFR: Versacom/Semagyr ungedeutet; Zeittelegramm ohne zusätzliche Referenz zur Sendezeit (Δt nur live sinnvoll).
- **0.19.0 (01.10.2026): M18 Funkgerät abstimmen (QSY AUTO).**
  - **Verhalten:** Mit dem Schalter **QSY AUTO** in der Kopfzeile (Standard aus) stimmt Digidec das Funkgerät auf die **Dial-Frequenz** des Moduls ab, wenn Modul, Band, Kanal oder Sender gewechselt wird: FT8/FT4 (Band, USB), SSTV (Kanal, USB/LSB/FM, ISS FM), EFR (Sendefrequenz − NF-Mitte, USB), DCF77 (77,5 kHz − Ton, USB), WEFAX (Frequenz − Mitte), NAVTEX (518/490/4209,5 kHz − Mitte). RTTY und CW haben keine feste Frequenz und stimmen nichts ab.
  - **Sicherheit:** `RigCommand` erzeugt nur `F <Hz>` (10 kHz … 10 GHz) und `M <Mode> <Bandbreite>` (erlaubte Modes, Zeilenumbruch/Einschleusen wird abgewiesen). Der Ende-zu-Ende-Test gegen einen nachgebauten rigctld prüft, dass nur `f`, `m`, `F`, `M` über die Leitung gehen. Ohne Verbindung wird nichts gesendet; nach einem URL-Auftrag stimmt Digidec 2 s lang nicht gegenläufig nach.
  - **Commander:** Beide haben einen eingebauten rigctld-Server (PCR-1500: `HamlibRigctldServer`, FT-991A ebenso), dessen `F`/`M` an den eigenen Zustand gebunden sind (`tuneTo(frequency:)`, `onSetModeAndFilter`). Die Commander stellen sich dabei selbst um und ihre Anzeige folgt; an den Commandern war keine Änderung nötig. Der rigctld-Server muss im Commander eingeschaltet sein.
  - **Tests:** 755 Logiktests (neu: Zielfrequenzen aller Module, Befehlsprüfung, Ende-zu-Ende gegen nachgebauten rigctld).
- **0.20.0 (01.10.2026): M19 WEFAX-Sendeplan mit automatischer Aufnahme.**
  - **Quelle:** Der DWD veröffentlicht den Faksimile-Sendeplan nur als PDF (`…/schifffahrt/funkausstrahlung/sendeplan_fax_MMJJJJ.pdf`, derzeit `092023`), ohne maschinenlesbare Form. Der Dateiname ändert sich mit dem Stand, deshalb sucht **Aktualisieren** den Link auf `…/funkausstrahlung/_node.html` (`jsessionid` wird entfernt), lädt das PDF (nur auf Knopfdruck, 20 s Zeitlimit, höchstens 3 MB, Kopf `%PDF` geprüft), liest den Text mit PDFKit und überführt ihn mit einem strengen Parser (`WefaxSchedule.parse`: ≥ 25 aufsteigende Ausstrahlungen, 60–240 UpM, Modul 576, sonst Ablehnung). Gelingt etwas nicht, bleibt der bisherige Plan, und eine Meldung nennt den Grund. Der letzte Plan liegt in `~/Library/Application Support/Digidec/WefaxSchedule`; ohne Abruf gilt der in der App eingebaute Stand (`Resources/Wefax/sendeplan_fax_092023.txt`).
  - **Plan:** 48 Ausstrahlungen täglich (04:30 … 22:00 UTC, 11–20 min, 120 UpM, Modul 576), 4 Sendepausen für Sprachsendungen, Frequenzen 3855 / 7880 / 13882,5 kHz (alle drei senden denselben Plan). Folgezeilen des PDFs gehören zum Kartentitel.
  - **Oberfläche:** Knopf **SENDEPLAN** im WEFAX-Bildpanel öffnet das Plan-Fenster: Zeit in UTC und lokal, Dauer, Kartentermin, Inhalt; laufende Sendung und „Nächste“ markiert; Häkchen je Sendung; Hauptschalter, Frequenzwahl (Automatisch: 18–07 UTC 3855, 07–18 UTC 7880 kHz; seit 0.22.0), WAV-Mitschnitt, Rückkehr zum vorigen Modul. Die Abstimmanzeige zeigt nächste Sendung bzw. nächste Aufnahme und Restzeit.
  - **Automatische Aufnahme (`WefaxAutoRecorder`):** 90 s vor Beginn schaltet Digidec auf WEFAX, wählt die Station und die Zeilenzahl (mit QSY AUTO stimmt es auch das Funkgerät ab), hält den Mac wach, lässt den Empfang das Bild per APT-Start ablegen (PNG, Dateiname und Beschreibung mit Kartentitel aus dem Plan) und beendet nach dem Ende (+90 s), sichert ein unfertiges Bild und kehrt zum vorigen Modul zurück. Jede Sendung wird pro Tag nur einmal gestartet; Einstieg höchstens 2 min nach Beginn (sonst nur Restbild); keine Aufnahme bei Dateiwiedergabe; Moduswechsel von Hand beendet die Aufnahme. Digidec muss laufen und der Mac wach sein.
  - **Tests:** 784 Logiktests (neu: Plan lesen, nächste/laufende Sendung, Zeitfenster der automatischen Aufnahme, Frequenz nach Tageszeit, Link-Erkennung, Dateiname). Der Netzabruf wurde gegen dwd.de geprüft (Link gefunden, PDF gelesen, Cache beim Neustart geladen).
  - **Offen:** Der Plan unterscheidet nicht nach Jahreszeit (z. B. Wirbelsturmkarten nur „während der Saison“, Eiskarten nur bei Bedarf); solche Sendungen können ausfallen und liefern dann kein Bild.
- **0.21.0 (01.10.2026): WEFAX-Bilder verschieben (zyklischer Versatz des Zeilenanfangs).**
  - **Anlass:** Ein echt empfangenes DWD-Bodenanalyse-Fax (01.10.2026, 12 UTC, 1809 × 1156) war gerade, aber in sich verschoben: der Zeilenanfang lag mitten in der Karte, der weiße Rand in der Bildmitte. Ursache ist meist ein verpasstes oder falsch getroffenes Phasing; die Zeilen selbst sind in Ordnung.
  - **Funktion:** `WefaxImageTools.shifted` schiebt jede Zeile mit Umlauf; `autoShift` legt den breitesten hellen senkrechten Streifen (den weißen Rand der Karte) an den Bildrand. Beim echten Bild: Verschiebung −607 px, danach steht die Karte vollständig im Rahmen. Textseiten ohne hellen Streifen werden nicht angefasst (0).
  - **Oberfläche:** In der WEFAX-Galerie pro Bild ein Knopf „Verschieben“, dazu **BILD ÖFFNEN** für bereits gespeicherte PNG-Dateien. Der Editor zeigt die Vorschau, einen Schieberegler (±Bildbreite/2), Feinschritte ±1/±10/±100, AUTO und ZURÜCK; er schlägt beim Öffnen die erkannte Verschiebung vor. **NEU SPEICHERN** legt `…_korr.png` daneben, **ORIGINAL ERSETZEN** ersetzt die Datei (das Original bleibt einmalig als `…_original.png`). Die Beschreibung im PNG nennt die Verschiebung.
  - **Tests:** 795 Logiktests (neu: Umlauf, Naht-Erkennung an einer synthetischen Karte, bereits richtig liegende Bilder, Bilder ohne hellen Streifen).
  - **Offen:** Die Ursache im Empfang (Phasing) ist nicht behoben; der Editor korrigiert nur im Nachhinein. Schräglauf (Slant) lässt sich im Editor nicht korrigieren (im Empfang gibt es den Schrägregler).
- **0.22.0 (01.10.2026): WEFAX: Frequenz je Sendung, Lernen aus Umstellen von Hand, automatische Nahtkorrektur.**
  - **Anlass:** Eine geplante Aufnahme lief auf der Tagesfrequenz; der Nutzer stellte während des Empfangs von Hand auf die Nachtfrequenz um, weil sie zu dieser Zeit (Oktober, 12 UTC) deutlich besser ging. Der Frequenzwechsel mitten im Empfang ließ den Zeilenanfang verrutschen (siehe 0.21.0).
  - **Frequenz:** Die Automatik wählte mittags 13882,5 kHz, was für Entfernungen bis etwa 1000 km oft in der toten Zone liegt. Jetzt wählt sie nur noch 3855 (18–07 UTC) oder 7880 kHz (07–18 UTC); 13882,5 kHz nie automatisch. Im Plan-Fenster hat jede Sendung eine Frequenzspalte (Menü: Standard / 3855 / 7880 / 13882,5, fest gewählte Frequenzen in Orange).
  - **Lernen:** Stellt der Nutzer während einer geplanten Aufnahme die WEFAX-Frequenz in Digidec um, merkt Digidec sie für diese Sendung (`frequencyOverrides`, bleibt erhalten) und nennt es in der Statuszeile. Eine von Hand am Funkgerät geänderte Frequenz erkennt Digidec nicht als Auswahl.
  - **Warnung:** Steht das Funkgerät (laut rigctld) während der Aufnahme mehr als 2 kHz neben der Dial-Frequenz der Station (etwa bei QSY AUS), zeigt die Statuszeile „Achtung: Funkgerät steht auf …“.
  - **Nahtkorrektur:** Schalter **AUTO-NAHT** in der Galerie (Standard an): Eine fertige Karte, deren weißer Rand um mindestens 20 px aus der Bildmitte liegt, wird zusätzlich korrigiert als `…_korr.png` abgelegt; das Original bleibt. Richtig liegende Karten und Textseiten ohne Randstreifen werden nicht angefasst.
  - **Tests:** 810 Logiktests (neu: Frequenzautomatik ohne 13882,5, Wahl je Sendung inkl. Neustart, Nahtkorrektur-Kopie, Original ersetzen mit Sicherung).
  - **Empfehlung:** Frequenz vor Beginn der Sendung einstellen (Digidec bereitet 90 s vorher vor); ein Wechsel mitten im Empfang kostet das Phasing.
- **0.23.0 (01.10.2026): M20 Sendepläne für RTTY und NAVTEX, gemeinsames Plan-Fenster und gemeinsame automatische Aufnahme.**
  - **Fenster:** Knopf **SENDEPLAN** in der Kopfzeile (öffnet den Reiter des aktuellen Moduls; im WEFAX-Panel weiterhin dort) mit den Reitern **WEFAX**, **RTTY**, **NAVTEX**. Oben die laufende bzw. nächste Aufnahme. Pro Dienst: Auswahl, Hauptschalter „automatisch aufnehmen“, Rückkehr zum vorigen Modul.
  - **RTTY:** Quelle sind die zwei DWD-PDFs (`sendeplan_rtty_01_…pdf`, `sendeplan_rtty_02_…pdf` auf `…/funkausstrahlung/_node.html`). **Aktualisieren** holt beide, liest sie mit `RttySchedule.parse` (Uhrzeit, Inhalt, WMO-Kopfzeile; Silbentrennung und Umbrüche des PDFs werden bereinigt, zweite Meldung ohne eigene Uhrzeit hängt an der vorigen, „bei Bedarf“-Hinweise sind keine Sendezeiten) und verwirft bei unplausiblem Format alles; eingebauter Stand und Cache wie beim Fax. 152 Sendungen (Programm 1: 66 auf 4583 / 7646 / 10100,8 kHz, Programm 2: 86 auf 147,3 / 11039 / 14467,3 kHz); Hub ±225 Hz (LW ±42,5 Hz), Voreinstellung DWD KW bzw. LW. Frequenz: Standard je Programm (Automatik: Programm 2 Langwelle 147,3 kHz, Programm 1 nachts 4583 / tags 7646 kHz) und je Sendung wählbar; Dial = Frequenz − NF-Mitte (USB). Zur Sendezeit: RTTY-Modul, Voreinstellung, Log an (danach wieder wie vorher), Vermerk „Sendeplan: …“ im Log. **Hinweis:** Das neue PDF (09/2023) nennt für Programm 2 durchgehend 00–24 UTC, `PLAN.md` 5.3 nannte 05–22 UTC (älterer Stand); maßgeblich ist das PDF.
  - **NAVTEX:** Der Plan wird nach dem IMO-Raster aus der Stationsliste berechnet (6 Blöcke zu 4 h, 24 Fenster zu 10 min, Station A–X sendet im Fenster A = +0 … X = +230 min), 204 Stationen. Bestätigt: Pinneberg 518 kHz **S** 03:00 / 07:00 / … laut DWD, 490 kHz **L** 01:50 / … (auch Wikipedia). **Fehler in der Stationsliste behoben:** Pinneberg auf 518 kHz stand als „L“ (jetzt „S“). Auswahl der Stationen (Voreinstellung Pinneberg S und L), Liste mit Filter, „nächste Fenster“. **Kein Abruf aus dem Netz:** Die Zeiten sind international festgelegt; die Wikipedia-Liste (mit explizit genannten Zeiten) ist je NAVAREA unterschiedlich aufgebaut, teils ohne Zeitspalte, und enthält Tippfehler (z. B. „12:20“ statt „12:40“) – für einen automatischen Import nicht verlässlich genug. Einzelne Stationen weichen vom Raster ab (z. B. Serapeum auf 4209,5 kHz); eine Station sendet nur, wenn Meldungen vorliegen.
  - **Aufnahmesteuerung (`ScheduleAutoRecorder`, ersetzt `WefaxAutoRecorder`):** Ein Dienst zugleich. Die Entscheidung je Takt ist eine reine Funktion (`ScheduleCalc.decide`): Folgesendungen warten, bis die laufende zu Ende ist (kein Abschneiden) und folgen dann nahtlos (Rückkehr zum vorigen Modul erst nach der letzten, Ruhezustand-Schutz bleibt); beginnt eine Sendung vor dem Ende der laufenden, wird sie mit Hinweis übersprungen; Moduswechsel von Hand beendet die Aufnahme. Je Dienst: WEFAX wie bisher (Station, Zeilenzahl, Bildablage mit Kartentitel, optional WAV, Lernen aus Umstellen von Hand), RTTY (Voreinstellung, Log, Dial), NAVTEX (518/490/4209,5 kHz, Log). Stimmt das Funkgerät (rigctld) mehr als 2 kHz nicht mit dem Ziel überein, warnt die Statuszeile.
  - **Tests:** 875 Logiktests (neu: RTTY-Parser an beiden Plänen, Links, Speicher und Frequenzwahl, NAVTEX-Plan und Raster, Zeitrechnung über alle Dienste, Entscheidungen der Aufnahmesteuerung). Netzabruf RTTY gegen dwd.de geprüft (beide PDFs gefunden, gelesen, Cache beim Neustart geladen).
  - **Offen:** Keine Audioaufnahme (WAV) für RTTY und NAVTEX (sie schreiben ihr Log). Nicht live mit Funkgerät geprüft.
- **Live-Tests durch den Nutzer (01.10.2026, nach 0.23.0):** CW, FT4 und FT8 erfolgreich getestet, NAVTEX geht ebenfalls. **CW-Erkennung ist verbesserungswürdig** (noch nicht näher beschrieben: Fehlerbild und Aufnahme stehen aus; Ansatzpunkte: Filterbandbreite, Tonnachführung, Geschwindigkeitsnachführung, Schwellen).
- **0.24.0 (01.10.2026): M21 WSPR (Weak Signal Propagation Reporter).**
  - **Kern:** `Vendor/Wspr`: wsprd aus WSJT-X (Commit `b4f9a43`), `port_wspr.py` kopiert und erzeugt `wspr_rx.c` aus `wsprd.c` (alle Funktionen wortgleich, `main()` ersetzt durch `inc/wspr_decode.inc` mit der C-Schnittstelle `wspr_digidec.h`). FFTW → pocketfft (`wspr_fftw.h`, `wspr_fft.cc`). Herkunft und alle Abweichungen: `Vendor/Wspr/UPSTREAM_WSPR.md`. Eigenes SwiftPM-Target `Wspr`, auch in `Tools/build_fldigi.sh` (Logiktests, UIPreview).
  - **Nachweis gegen das Original:** WSJT-X-Beispiel `150426_0918.wav`: Digidec und das mit FFTW gebaute Original-wsprd liefern dieselben 8 Meldungen mit gleichem S/N und DT (ND6P, W5BIT, WD4LHT, NM7J, KI7CI, DJ6OL, W3HH, W3BI). Rechenzeit ≈ 1,8 s je Zyklus.
  - **Swift:** `WSPRCore` (Decode, Meldung zerlegen, Leistung in W/mW, Testsignal, Hashtabelle), `WSPRModule` (16 Bänder 2200 m … 70 cm mit WSJT-X-Dial-Frequenzen, `WSPRSettingsStore` mit Rufzeichen/Locator/±150 Hz/TIEF/Zeitkorrektur, `WSPRDecoder` 12-kHz-Senke, decodiert bei 1:54 nach dem geraden UTC-Minutenbeginn, `WSPRController`). Hashtabelle für Typ-3-Meldungen unter `~/Library/Application Support/Digidec/WSPR/hashtable.txt`.
  - **Oberfläche:** Spotliste (UTC, dB, DT, MHz, Drift, Flagge, Rufzeichen, Locator, Leistung, km), Zyklus-Anzeige (Minute:Sekunde, Sende-/Decodierfenster), weitester Empfang, Einstellungen. Wasserfall zeigt das 200-Hz-Fenster bei 1500 Hz. Log `~/Documents/Digidec/Logs/WSPR-JJJJ-MM-TT.txt` im Format von ALL_WSPR.TXT. URL: `digidec://decode?mode=wspr&preset=20m|40m|…`; QSY AUTO stimmt auf den Dial (USB) ab.
  - **Swift-Nachbearbeitung:** Sehr starke Signale hinterlassen einen Rest, den wsprd als dieselbe Meldung mit kleinem S/N wenige Hz daneben noch einmal findet; `removeResiduals` behält das stärkere.
  - **Tests:** 923 Logiktests (neu: Bänder/URL/QSY, Meldungen, Log-Zeile, sauberes Signal, Frequenz-/Zeitversatz, ±110/±150 Hz, drei Stationen, Weißrauschen bis −24 dB, Typ 2 und 3, Hashtabelle, echte WSJT-X-Aufnahme (nur wenn `Vendor/_upstream/wsjtx` vorhanden), Zyklus über die Pipeline mit simulierter Uhr).
  - **Grenzen:** Keine OSD-Stufe (Fortran, in wsprd optional). Typ-3-Meldungen zeigen `<...>`, bis das Rufzeichen einmal als Typ 1/2 gehört wurde. Nur WSPR-2 (kein WSPR-15). Digidec sendet nie.
  - **Offen (braucht den Nutzer):** Live-Empfang, z. B. 20 m (Dial 14,0956 MHz USB) oder 40 m (7,0386 MHz). Rechneruhr auf ±1 s (WSPR verträgt ± 2 s); DT der Stationen beobachten, sonst Zeitkorrektur.
- **0.25.0 (01.10.2026): M22 PSK31/63 (und 125/250, QPSK).**
  - **Kern:** `Vendor/Fldigi/src/psk`, erzeugt von `port_psk.py` aus fldigi 4.2.13 `psk.cxx`/`psk.h` (Funktionen wörtlich, Klammerzählung wie bei CW). Dazu `pskcoeff`, `pskvaricode`, `viterbi`, `interleave`, `mfskvaricode` unverändert, Umgebung `psk_compat.h`, C-Schnittstelle `fldigi_psk.h`. Nur Empfang; Senden, Mehrkanal-Ansicht (`viewpsk`), `pskeval` und PSKmail entfallen. Im Konstruktor bleiben alle fldigi-Betriebsarten, die C-Schnittstelle bietet BPSK/QPSK 31–250 an. Herkunft und Abweichungen: `Vendor/Fldigi/UPSTREAM_PSK.md`. Nur ein PSK-Decoder gleichzeitig (file-static-Zustand wie bei CW).
  - **Swift:** `FldigiPSKCore` (Optionen, Status, Phasenvektor, Testsignal), `PSKModule` (`PSKSettingsStore` mit Modus, Mitte, AFC, Squelch, REV, Band; `PSKDecoder` 8-kHz-Senke, `PSKController` mit Text, Log `PSK-JJJJ-MM-TT.txt`, AFC-Mitte folgt dem Wasserfall-Marker), Panels: Empfangstext, Abstimmanzeige (DCD, Phasenvektor, Signal, S/N, IMD), Einstellungen. URL `digidec://decode?mode=psk&preset=bpsk31|bpsk63|bpsk125|bpsk250|qpsk31|…&center=…`. Bandwahl (160 … 10 m, PSK31-Anruffrequenz, USB) stimmt mit QSY AUTO das Funkgerät ab; „frei“ stimmt nichts ab.
  - **Nachweis (synthetisch, Sendeseite nach fldigi):** alle acht Betriebsarten fehlerfrei; AFC holt ± 6 Hz Versatz heran (ohne AFC bei +16 Hz gestört); BPSK31 hält bis −4 dB S/N (2500 Hz) alle Zeichen, BPSK63 bei 3 dB, BPSK125 bei 8 dB, QPSK31 bei 5 dB, QPSK63 bei 8 dB; Squelch unterdrückt Rauschen; Pipeline 48 kHz → 8 kHz.
  - **Werkzeuge:** `Tools/DecodeFile/decode_file.sh <wav> --psk bpsk31 --center 1000 [--noafc] [--rev] [--compare fldigi.txt]`. `decode_file.sh` baut jetzt alle App-Quellen (außer `DigidecApp.swift`) statt einer festen Liste; der Aufruf war seit 0.19.0 (`RigCommand`) nicht mehr übersetzbar.
  - **Tests:** 962 Logiktests.
  - **Offen (braucht den Nutzer):** Live-Empfang, z. B. 20 m (Dial 14,070 MHz USB, Signale bei 1000 Hz ± ; PSK31 liegt meist 14,070 … 14,073). Klick auf das Signal im Wasserfall, AFC an. Vergleich mit fldigi auf derselben Aufnahme steht aus (Werkzeug `--compare` ist da). Keine WAV-Aufnahme (REC) im PSK-Modul.
- **0.26.0 (01.10.2026): M23 Olivia, Contestia und MT63.**
  - **Kern:** `Vendor/Fldigi/src/olivia` (Jalocha-Header, wortgleich) und `src/mt63` (`dsp.cpp`, `mt63base.cpp`, wortgleich, Tabellen in `mt63data/`), dazu die Rahmen `olivia_rx.cpp` (Olivia und Contestia) und `mt63_rx.cpp` nach den fldigi-Modems. Mehrere Exemplare gleichzeitig möglich. Herkunft, Abweichungen, Fundstück zu `MT63tx::Preset()`: `Vendor/Fldigi/UPSTREAM_MT63_OLIVIA.md`.
  - **Swift:** `FldigiOliviaCore` / `FldigiMT63Core` (Optionen, Status, Testsignal), `OliviaModule` / `MT63Module` (Einstellungen, 8-kHz-Decoder, Controller mit Text und Log), gemeinsame Textansicht `TextModeReceivePanel` (auch PSK kann sie nutzen), Panels mit Abstimmanzeige (Signal, S/N, Abweichung, MT63: SYNC) und Einstellungen (Töne, Bandbreite, REV, 8 BIT, Squelch). URL `digidec://decode?mode=olivia&preset=olivia-8-500|contestia-16-1000|…&center=…` und `mode=mt63&preset=1000s|1000l|500s|…`. Kein QSY (keine feste Frequenz).
  - **Nachweis (synthetisch, Sendeseite nach fldigi):** Olivia 6 Betriebsarten, REV, −10 dB S/N; Contestia 4 Betriebsarten, −8 dB; MT63 alle 6 Varianten, 6 dB; Squelch unterdrückt Rauschen; Pipeline 48 kHz → 8 kHz; falsche Tonzahl liefert keinen Text.
  - **Werkzeuge:** `decode_file.sh <wav> --olivia olivia-8-500 [--center Hz]`, `--mt63 1000s`.
  - **Tests:** 1036 Logiktests.
  - **Offen (braucht den Nutzer):** Live-Empfang (Olivia 8/500 und 16/500 auf 14,0730 / 7,0400 MHz, Contestia 8/250, MT63 auf 14,1090 MHz USB), Vergleich mit fldigi auf derselben Aufnahme. MT63 braucht einige Sekunden, bis Text erscheint; am Anfang erscheinen einige Zufallszeichen, bis der Synchronisierer einrastet.
- **0.27.0 (01.10.2026): M24 DSC (Digital Selective Calling) auf MF/HF.**
  - **Quellen:** Eigene Umsetzung nach ITU-R M.493-9 (PDF liegt lokal unter `Vendor/_upstream/itu_m493.pdf`), Gegenprobe an der MIT-lizenzierten .NET-Referenz TAOSW.DSC_Decoder (echte aufgezeichnete Rufe, Aufnahme `test.wav`). Kein Fremdcode im Projekt; Herkunft, Aufbau, Grenzen: `Vendor/Dsc/UPSTREAM_DSC.md`.
  - **Kern (`Sources/Decoders/DSC/DSCCore.swift`):** `DSCDemodulator` (zwei Töne ± 85 Hz, gleitende Bitintegration, **acht Taktlagen** parallel), `DSCFramer` (Phasing-Suche, 10-Bit-Symbole mit Prüfbits, DX/RX-Zusammenführung, ECC), `DSCCallCollector` (bester Ruf je Aussendung), `DSCAutoTuner` (Tonpaar im Abstand 170 Hz, parabolisch interpoliert), `DSCMessage.parse` (Notruf, Alle Schiffe, Gruppe, Einzelruf, Gebiet, Automatik), `DSCSignalGenerator` (Testsignal).
  - **Modul/Oberfläche:** `DSCModule` (Einstellungen: Kanal, Mitte, AUTO, REV; Decoder als 8-kHz-Senke; Controller mit Doppelungsschutz und Log), Panels: Meldungsliste (UTC, Ruf, Kategorie, Von, An, Inhalt, ECC; **Seenot rot**, unsichere grau), Abstimmanzeige (SYNC, Mitte, gemessene Mitte, Dial, letzter Notruf), Einstellungen. Kanäle 2187,5 · 4207,5 · 6312 · 8414,5 · 12577 · 16804,5 kHz; QSY AUTO stimmt auf USB-Dial = Kanal − Mitte (Mitte 1700 Hz → z. B. 8412,8 kHz). URL `digidec://decode?mode=dsc&preset=8414|2187|…&center=1700`. Log `DSC-JJJJ-MM-TT.txt` mit Symbolen.
  - **Nachweis:** Echte Aufnahme (SDRuno, 88,2 kHz, Mitte 505 Hz, 65 s): alle **5 Rufe** (Testrufe der Küstenfunkstelle 002371000 an 538010255, 477832400, 249855000, 511100954, 636024307) mit ECC OK; die Mitte wird aus Startwerten zwischen 400 und 700 Hz auf 505 Hz nachgeführt. Alle 9 aufgezeichneten Symbolfolgen der Referenz ergeben dieselben Felder und gültigen ECC. Rundlauf Generator → Demodulator: Notruf, Einzelruf, Mitte 1500/1700 Hz, kurzes Punktmuster (20 Bit), REV, ± 15 Hz Versatz, 3 dB S/N, zwei Rufe unmittelbar nacheinander; Rauschen ergibt keinen Ruf; Pipeline 48 kHz → 8 kHz.
  - **Werkzeug:** `decode_file.sh <wav> --dsc --center <Hz> [--noauto] [--rev]`.
  - **Tests:** 1083 Logiktests.
  - **Grenzen:** UKW-DSC Kanal 70 ab 0.32.0; Notruf-Quittungen werden nicht in ihre Nutzdaten zerlegt; keine Küstenfunkstellen-Namen/Länder (MID).
  - **Offen:** Live-Empfang (z. B. 8414,5 kHz: Küstenfunkstellen senden dort regelmäßig Testrufe), Notruf-Quittungen auswerten.
- **0.28.0 (01.10.2026): M25 ALE (Automatic Link Establishment, 2G).**
  - **Quellen:** Eigene Swift-Umsetzung nach MIL-STD-188-141A/B Anhang A anhand der MIT-lizenzierten Referenz **openALE** (Vendor/_upstream/openale, lokal); Herkunft, Aufbau, Grenzen: `Vendor/Ale/UPSTREAM_ALE.md`. Kein Fremdcode im Projekt.
  - **Kern (`Sources/Decoders/ALE/ALECore.swift`):** `ALEGolay` ((24,12), 3 Fehler korrigierbar, Mindestgewicht 8 geprüft), `ALECodec` (Wort ↔ 49 Symbole, 2-von-3-Mehrheit mit Zählung einstimmiger Bit, Zeichensätze), `ALEDemodulator` (acht Töne 750 … 2500 Hz, **16 Taktlagen** parallel), `ALEWordCollector`, `ALEGridTracker` (Raster 392 ms gegen Fehlalarme durch verschobene Fenster), `ALEMessageBuilder`/`ALEMessage` (Adressen aus mehreren Wörtern, Klartext, Art), `ALEFrequencyError` (Verstimmung am bekannten Wort messen), `ALESignalGenerator`.
  - **Modul/Oberfläche:** `ALEModule` (Verstimmung von Hand oder AUTO, Zuverlässigkeit streng/normal/empfindlich, Decoder als 8-kHz-Senke mit Nachführung, Controller mit Log `ALE-JJJJ-MM-TT.txt`), Panels: Aussendungsliste (UTC, Art, Q, Inhalt), Abstimmanzeige (SYNC, Reinheit, Verstimmung, Wörter), Einstellungen. Wasserfall: Tonblock 750 … 2500 Hz mit Klick auf die Mitte. URL `digidec://decode?mode=ale&center=1625`. Kein QSY (keine feste Frequenz; ALE-Netze arbeiten auf vielen Kanälen im Wechsel).
  - **Nachweis:** Echte Aufnahme (sigidwiki 2G ALE, 30 s): 3 Aussendungen, 38 Wörter: Kennung „SHAEENQ2“ (zweimal), Anruf an „USMANQ7“ mit Klartext „WE ALSO PAWCED MSG TO OUR SECTION ALREDY TODAY MORNING ABOUT HOLIDAY HER“. Rundlauf: genau die gesendeten Wörter und Wortende auf 8 Abtastwerte genau, Adressen mit 9 und 6 Zeichen, Sounding, Nachricht, Verstimmung 12 Hz, beliebige Taktlage, 12 dB und 6 dB S/N, Rauschen und Dauerton ergeben nichts; Raster lehnt verschobene Fenster ab; Frequenzfehler −25 … +30 Hz auf ±3 Hz gemessen; Pipeline 48 kHz → 8 kHz mit Nachführung von 22 Hz Verstimmung.
  - **Werkzeug:** `decode_file.sh <wav|mp3> --ale [--offset Hz] [--minvotes n]`.
  - **Tests:** 1134 Logiktests.
  - **Grenzen/Offen:** nur ALE 2G (kein 3G/4G/AQC); CMD-Wörter roh; keine Netz-/Stationsnamen; Live-Empfang offen (ALE-Kanäle liegen u. a. bei 3,596 / 7,102 / 10,145 / 14,109 MHz USB; Hinweis: nicht alle Netze senden jederzeit).
  - **Rechtlicher Hinweis (keine Rechtsberatung):** Inhalt und Adressen von ALE-Verkehr, der nicht für die Allgemeinheit bestimmt ist (Behörden, Militär, kommerzielle Netze), unterliegen in Deutschland dem Fernmeldegeheimnis; Aufzeichnen und Weitergeben ist heikel. Erkennen von Sounding und Signalanalyse sind unkritisch. Das Log von Digidec schreibt auf Wunsch alles mit; es lässt sich mit LOG ausschalten.
- **0.29.0 (02.10.2026): M26 APRS und M27 Kartenanzeige.**
  - **APRS:** Dateien `Sources/Decoders/APRS/{AFSKModem,APRSPacket,APRSModule}.swift`, Oberfläche `Sources/UI/APRSPanels.swift`. Eigene Umsetzung, Gegenprobe mit Dire Wolf (`Vendor/_upstream/direwolf`, gebaut in den Scratchpad; Tabelle in `Vendor/Aprs/UPSTREAM_APRS.md`). 12-kHz-Senke, 7 Entscheider, zwei Demodulatoren parallel (flach und de-emphasiert), Ein-Bit-Reparatur (nie auf der Karte). Stationsliste mit Weg (bis 300 Punkte), Objekte unter ihrem Namen, Protokoll im TNC2-Format (Log `APRS-JJJJ-MM-TT.txt`), Nachrichtenliste. URL `digidec://decode?mode=aprs&preset=eu|na|iss|au|jp|free`. QSY AUTO stimmt in FM auf die Kanalfrequenz.
  - **Testmaterial:** WA8LMF TNC Test CD 2.0 (`Vendor/_upstream/wa8lmf`, nicht im Git; ISO von wa8lmf.net, Spuren als WAV) und gr-APRS (`Vendor/_upstream/gr-APRS`). `decode_file.sh <wav> --aprs [--pre auto|off|on] [--nofix] [--home JN49WS]` gibt je Paket TNC2-Zeile, Ort und Entfernung aus.
  - **Karte:** `Geo.swift` (Entfernung, Richtung, Locator, Kartenmodell `MapContent`/`MapMarker`/`MapLine`, `HomeLocation`), `ModuleMaps.swift` (Aufbereitung je Modul, reine Logik, getestet), `MapPanel.swift` (MapKit-Ansicht), `MapViews.swift` (Zuordnung Modul → Karte). Kartenkacheln kommen von Apple Maps aus dem Netz; ohne Netz bleibt die Karte leer, die Punkte bleiben. Der Standort (Locator, Standard JN49WS) gilt für alle Karten und wird auf die Locator von FT8, FT4, WSPR und NAVTEX übertragen.
  - **Rufzeichen im Text** (`CallsignLog`): in CW, PSK, Olivia, MT63, RTTY werden Rufzeichen mit gültigem Muster und DXCC-Gebiet gesammelt; sicher gelten sie nach CQ/DE/QRZ davor oder bei mehrfachem Empfang. Der Ort ist der Mittelpunkt des Landes (kein Locator im Text). **SYNOP** (`SynopLog`): Klartext des fldigi-Decoders wird zerlegt, der Ort kommt aus dem Text (Schiffe) oder aus der WMO-Liste (`Resources/Stations/nsd_bbsss.txt`, Land).
  - **Entwicklungshilfen (Umgebungsvariablen, nur zum Prüfen):** `DIGIDEC_PLAY_FILE=<wav>` spielt eine Datei statt des Eingangs; `DIGIDEC_SNAPSHOT=<png>` (+ `DIGIDEC_SNAPSHOT_DELAY`, `DIGIDEC_SNAPSHOT_STEPS="aprs:karte,ft8:liste"`) speichert das Hauptfenster samt Karte als PNG und beendet die App. Damit lässt sich die Oberfläche ohne Bildschirmaufnahme-Freigabe prüfen.
  - **Prüfung der Oberfläche** mit der WA8LMF-Aufnahme: Stationsliste mit Symbolen und Entfernungen, Karte mit den Stationen im Raum Los Angeles, Weg-Karte WEFAX (Pinneberg, Linie zum Standort).
  - **Tests:** 1243 Logiktests (+109: Geo, AX.25/CRC, Parser mit Vektoren aus der Spezifikation, Mic-E-Rundlauf aus unabhängigem Kodierer, Demodulator mit Takt-, Ton-, Pegel- und De-Emphasis-Abweichung, Empfänger, Stationsliste, alle Kartenaufbereitungen). `run_logic_tests.sh` nimmt `LT_FLAGS="-Onone -g"` für eine Debug-Version.
  - **Grenzen/Offen:** nur 1200 Bd (kein 9600, kein FX.25/IL2P); keine Digipeater-Pfad-Karte; die Karte nutzt Apple-Kacheln (Netz nötig); Mic-E-Gerätekennungen nur für Kenwood und Yaesu; DSC-Gebiete (Rechtecke) nicht gezeichnet; SSTV und ALE ohne Karte. Live-Empfang von 144,800 MHz offen (PCR-1500: FM-N; Audio vor Pegelanpassung prüfen).
- **0.29.1 (02.10.2026): Darstellung LISTE · KARTE · BEIDE.** Anlass: Bei eingeblendeter Karte war das laufend empfangene Wetterfax-Bild unsichtbar. Jetzt gibt es je Modul drei Stellungen (Kopfzeile, `MapLayout` in `DigidecState`); in BEIDE bleibt der Hauptbereich (Bild, Liste, Text) oben und die Karte (42 % der Höhe, mindestens 190 pt) darunter. Module ohne Ortsdaten (SSTV, ALE) zeigen immer die Liste. Die früher gemerkte Einstellung „Karte“ (`mapModules`) wird übernommen. Schnappschuss-Hilfe: Schritte `modul:liste|karte|beide`.
- **0.29.2 (02.10.2026):** Der Umschalter nennt die gewohnte Ansicht je Modul richtig: **BILD** (WEFAX, SSTV), **TEXT** (RTTY, NAVTEX, CW, PSK, Olivia, MT63), **ANZEIGE** (DCF77, EFR), **LISTE** (APRS, FT8, FT4, WSPR, DSC, ALE); `DecoderModuleInfo.mainViewName` in `MapViews.swift`.
- **0.30.0 (02.10.2026): M28 Funkruf (POCSAG, FLEX) und M29 Töne (DTMF, Selektivruf).**
  - **Dateien:** `Sources/Decoders/Pager/{POCSAGCore,FLEXCore,ToneCore,PagerModule,TonesModule}.swift`, Oberfläche `Sources/UI/PagerPanels.swift`. Module `PAGER` und `TÖNE` (URL `digidec://decode?mode=pager&preset=dapnet|free`, `mode=tones`). QSY AUTO stimmt PAGER in FM auf 439,9875 MHz (DAPNET). Ohne Karte (keine Ortsdaten).
  - **Referenz:** multimon-ng (`Vendor/_upstream/multimon-ng`, nicht im Git), gebaut in den Scratchpad. Echte Gegenproben: `test/samples` (POCSAG 512/1200/2400, FLEX P2000).
  - **Demodulator:** 24-kHz-Senke. Der Bit-Entscheider arbeitet auf dem Pegel mit Hysterese; bei wechselstromgekoppeltem Audio (Pegel sinkt nach langen gleichen Bitfolgen gegen Null) entscheiden die Sprünge. Dadurch fehlerfrei bei 30 und 150 Hz Kopplung, bei Rauschen, invertiert und ±1 % Takt. Schutz gegen Zufallsmeldungen in Abschnitt 11-Eintrag und `UPSTREAM_PAGER.md`.
  - **FLEX:** Sync, FIW, Phasen A–D, Alphanumerik, Ziffern, Tonrufe, Gruppenrufe. Das Wasserfall-Protokoll `TuningTarget` hat dafür `markerStyle` (Band statt Mark/Space-Marker, bei Tönen ohne Marker).
  - **Tools:** `decode_file.sh <wav> --pager [--rates 512,1200]` und `--tones [dtmf,zvei1,…]`.
  - **Tests:** 1339 Logiktests (+96: BCH mit Doppelfehlern, echte POCSAG-Codewörter, POCSAG-Rundlauf je Baudrate mit Ziffern, langen Meldungen, Inversion, Kopplung, Takt, Rauschen, Stille; FLEX-Rundlauf mit Testsignal; Tonfolgen aller Normen, DTMF mit 16 Tasten, Rauschen und Akkord; Controller und Listen).
  - **Grenzen/Offen:** FLEX-Phasen B/D und 3200 Baud sind nur über die Modustabelle und das Entschachteln abgedeckt, nicht an einer echten Aufnahme; keine Meldungsfolgen (Fragmente F/C werden einzeln angezeigt, wie bei multimon-ng); keine Skyper-Zeichensatzumsetzung; die Normen ZVEI/CCIR/EEA überlappen in den Frequenzen (bei mehreren eingeschalteten Normen gewinnt die längere Folge). Live-Empfang offen: DAPNET 439,9875 MHz, FM-Audio ohne Rauschsperre.
- **0.31.0 (02.10.2026): M30 ACARS.**
  - **Dateien:** `Sources/Decoders/ACARS/{ACARSCore,ACARSModule}.swift`, `Sources/UI/ACARSPanels.swift`, `Resources/Airports/airports.txt`. URL `digidec://decode?mode=acars&preset=f131550|f131725|f131525|f130025|f136900|free`. QSY AUTO stimmt in AM ab. 12-kHz-Senke.
  - **Referenz:** acarsdec (`Vendor/_upstream/acarsdec`, mit `test.wav`), im Scratchpad gebaut (`-DHOST_NAME_MAX=255`). Die 7 echten Meldungen (PH-BXR, LN-DYY, F-GTAE, G-DBCK …) stimmen überein.
  - **Anzeige:** Meldungsliste (Uhrzeit, Kennzeichen, Flug, Richtung, Label, Text oder Bezeichnung), Filter UPLINK und LEERE AUS, Tooltip mit Labelbedeutung und OOOI-Auswertung (Flughafen mit Ort). Karte (KARTE/BEIDE): Flughäfen aus den OOOI-Labels, Großkreislinien Start → Ziel, nur Flüge der letzten 6 Stunden.
  - **Tests:** 1373 Logiktests (+34: CRC-Prüfwert, Rundlauf Demodulator/Generator, Rauschen, Inversion, leise, Reparatur von Ein- und Doppelbitfehlern, OOOI, Flughäfen, Controller, Karte, Filter, Kanäle).
  - **Prüfung der Oberfläche:** Tabellen, Abstimmanzeige und Einstellungen offscreen (`Tools/UIPreview`, `acars_*.png`); die Karte selbst nicht gesehen (der Bildschirm war bei der letzten Prüfung gesperrt).
  - **Grenzen/Offen:** Positionen aus dem Text (z. B. Label H1) werden nicht ausgewertet; Labelnamen nur für die häufigsten; keine Zusammenführung mehrteiliger Meldungen (ETB). Live-Empfang offen: 131,550 oder 131,725 MHz in AM, Rauschsperre offen. UIPreview rendert jetzt auch Funkruf und ACARS.
- **0.32.0 (02.10.2026): M31 UKW-DSC Kanal 70.**
  - **Dateien:** `Sources/Decoders/DSC/DSCVHF.swift` (`DSCVHFReceiver`, Testsignal `DSCSignalGenerator.audioVHF`), `AFSKDemodulator` (Baudrate und Töne als Parameter, Rohbit-Ausgang `onRawBit`), `DSCModule.swift` (Kanal `vhf70`, URL `digidec://decode?mode=dsc&preset=70`, zweite 12-kHz-Senke), `RigTuneTarget.dsc` (FM auf 156,525 MHz). `decode_file.sh --dsc --vhf`.
  - **Aufbau:** ITU-R M.493: UKW-DSC hat dieselben 10-Bit-Zeichen, Phasing, DX/RX-Verschachtelung und ECC wie MF/HF, nur 1200 Bd und die Töne 1300 Hz (Y, Bit 1) / 2100 Hz (B, Bit 0). Je zwei Demodulatoren (flach, mit Vorverzerrung) mit je fünf Entscheidern speisen zehn `DSCFramer`; der `DSCCallCollector` behält den besten Ruf. Kein Warnton (vom Nutzer nicht gewünscht).
  - **Tests:** Rundlauf Ruf und Notruf, Blockgrößen, Baudrate ±0,5 %, 12 und 6 dB S/N, zwei Rufe hintereinander, Rauschen, Kanal und Funkgerät FM.
  - **Grenzen/Offen:** nur mit Testsignal geprüft, keine echte Aufnahme von Kanal 70; Live-Empfang offen (156,525 MHz, FM-Audio, Rauschsperre offen).
- **0.33.0 (02.10.2026): M32 MFSK, DominoEX, Thor.**
  - **Dateien:** `Vendor/Fldigi/src/mfsk/*` (erzeugt von `port_mfsk.py` aus fldigi `mfsk.cxx`, `dominoex.cxx`, `thor.cxx`), `Vendor/Fldigi/include/fldigi_mfsk.h`, `Sources/Decoders/MFSK/{FldigiMFSKCore,MFSKModule}.swift`, Panels in `Sources/UI/TextModePanels.swift`. URL `digidec://decode?mode=mfsk&preset=mfsk16|mfsk32|…|dominoex11|…|thor16|…&center=1500`. Kein QSY (keine feste Frequenz). `decode_file.sh <wav> --mfsk mfsk16 --center 1500`.
  - **Betriebsarten:** MFSK 4, 8, 11, 16, 22, 31, 32, 64, 128, 64L, 128L; DominoEX Micro, 4, 5, 8, 11, 16, 22, 44, 88; Thor Micro, 4, 5, 8, 11, 16, 22, 25, 32, 44, 56, 100, 25x4, 50x1, 50x2. Drei Senken (8000, 11025, 16000 Hz), es arbeitet die passende. MFSK mit AFC, DominoEX mit optionalem MultiPsk-FEC.
  - **Abweichungen:** Bilder (MFSK „Pic:“, Thor „pic%“) werden aus dem Signal genommen, aber nicht angezeigt; Squelch-Voreinstellung 30 (fldigi 5 liefert bei Rauschen Zeichen); `slowcpu` aus (alle Pfade); DominoEX/Thor nur ein Decoder gleichzeitig.
  - **Tests:** 1444+ Logiktests (+60: alle Betriebsarten im Rundlauf außer den drei sehr langsamen, Mitten, AFC, Umstellen, Rauschen, Squelch, Pipeline 48 kHz → 8000/11025 Hz).
  - **Grenzen/Offen:** nur gegen das eigene fldigi-Testsignal geprüft, **nicht** gegen echte Aussendungen oder das Original-fldigi (Sende- und Empfangsseite stammen beide aus fldigi); keine Bildanzeige; keine Sekundärtext-Ausgabe. Live-Empfang offen (z. B. MFSK16 auf 14,0795 / 7,0775 MHz USB, DominoEX auf 14,0705 MHz, Thor 14,0775 MHz).
- **0.34.0 (02.10.2026): M33 SELCAL.**
  - **Dateien:** `Sources/Decoders/Pager/ToneCore.swift` (Norm `.selcal`, `ToneDecoder` mit SELCAL-Zweig, `ToneSignalGenerator.selcal`), Texte in `TonesModule.swift`/`PagerPanels.swift`. `decode_file.sh <wav> --tones selcal`.
  - **Aufbau:** Goertzel auf den 16 Tönen A B C D E F G H J K L M P Q R S (312,6 … 1479,1 Hz), Hann-Fenster 80 ms, Schritt 25 ms; je Schritt die zwei stärksten Töne (dritter mindestens 9 dB schwächer, beide mindestens 35 % der Leistung). Ein Impuls zählt nach 0,35 s Stabilität; der zweite muss binnen 0,6 s Pause beginnen. Ausgabe in aufsteigender Buchstabenfolge je Paar („DAMR“ → „AD-MR“).
  - **Tests:** Codes, benachbarte Töne, kurze Impulse, zwei Rufe, leise mit Rauschen, zu lange Pause, einzelner Impuls, ZVEI-Folge und Akkord ergeben nichts, 4–5 Hz Frequenzfehler.
  - **Grenzen/Offen:** nur Testsignale; kein Abgleich mit dem Flugplan oder Flugzeugkennung; 10 Hz und mehr Abstimmfehler (SSB) können Töne verfehlen. Live-Empfang offen (HF-Flugfunk, z. B. Shanwick, USB).
- **0.35.0 (02.10.2026): M34 Throb, IFKP, FSQ.**
  - **Dateien:** `Vendor/Fldigi/src/mfsk/{throb,ifkp,fsq}_rx.*` (erzeugt von `port_mfsk.py`), Erweiterungen in `fldigi_mfsk.*`, `FldigiMFSKCore.swift`, `MFSKModule.swift` (vier Senken: 8000, 11025, 12000, 16000 Hz), Panels. Kennungen `throb1|throb2|throb4|throbx1|throbx2|throbx4`, `ifkp05|ifkp10|ifkp20`, `fsq15|fsq2|fsq3|fsq45|fsq6`.
  - **Abweichungen:** siehe `Vendor/Fldigi/UPSTREAM_MFSK.md` (Nr. 8 bis 10): Throb-Squelch skaliert, IFKP ohne Bild/Avatar/Protokolle/1500-Hz-Bindung, FSQ ohne gerichtete Befehle (Zeichen wie im Monitor).
  - **Tests:** 1479 Logiktests (+20): Rundlauf aller Betriebsarten außer IFKP 0,5 und FSQ 1,5 (sehr langsam), Rauschen, Squelch, Pipeline.
  - **Grenzen/Offen:** nur gegen das eigene fldigi-Testsignal geprüft; kein Bildempfang (MFSK, Thor, IFKP, FSQ); FSQ-Rufzeichen und CRC werden nicht ausgewertet.
- **0.36.0 (02.10.2026): M35 Hell.**
  - **Dateien:** `Vendor/Fldigi/src/mfsk/feld_rx.*` (erzeugt von `port_mfsk.py`), `fldigi_hell.*` (C-Schnittstelle), `Sources/Decoders/Hell/{FldigiHellCore,HellModule}.swift` (Kern, Einstellungen, Decoder, Controller, `HellRasterModel`), `Sources/UI/HellPanels.swift`. URL `digidec://decode?mode=hell&preset=feld|slow|x5|x9|fskh245|fskh105|hell80&center=1500`. Kein QSY, keine Karte.
  - **Anzeige:** Hell-Bild (Schrift als Raster, wie das Raster-Fenster von fldigi), Umschalter-Name BILD; Einstellungen: Betriebsart, Spaltenhöhe 14 … 42, Spaltenbreite 1× … 3×, AGC, REV (FSK), Tafeldarstellung, Squelch; Bild als PNG speichern.
  - **Abweichungen:** siehe `UPSTREAM_MFSK.md` Nr. 11 (keine Zeichenerkennung; Schrift „hell 12“ nur im Testsignal).
  - **Tests:** 1509 Logiktests (+30): URL, Kennungen, Rundlauf aller Betriebsarten (Spalten, Tinte), Spaltenlänge, Wiederholung, Mitte, Rauschen, Tafel, Squelch (Stille), Raster-Bild und PNG.
  - **Beobachtung:** Der MT63-Logiktest „1000S Text“ schlug in einem von rund zehn Läufen mit leerer Ausgabe fehl (danach in acht weiteren Läufen nicht mehr); vermutlich unbestimmter Speicher in der MT63-Bibliothek; noch nicht untersucht.
  - **Grenzen/Offen:** nur gegen das eigene fldigi-Testsignal geprüft; keine Zeilensynchronisation des Bildes (wie fldigi); FSK-Hell zeigt ohne Signal schwarze Spalten, solange der Pegel über dem Squelch liegt.
- **0.37.0 (02.10.2026): M36 PSKR und 8PSK.**
  - **Dateien:** `Vendor/Fldigi/src/psk/psk_rx.cpp` (erzeugt von `port_psk.py`, jetzt mit den Sendefunktionen), `psk_compat.h`, `fldigi_psk.*` (Modi, Abtastrate, Testsignal mit fldigis Sendeseite), `FldigiPSKCore.swift` (`PSKMode` mit Familien BPSK, QPSK, PSKR, 8PSK), `PSKModule.swift` (zweite Senke 16 kHz), `PSKPanels.swift` (Moduswahl nach Familien). Kennungen `psk125r|psk250r|psk500r|psk1000r|8psk125|8psk125fl|8psk125f|8psk250|8psk250fl|8psk250f|8psk500|8psk500f|8psk1000|8psk1000f|8psk1200f`.
  - **Tests:** alle 15 neuen Betriebsarten im Rundlauf, Pipeline 48 kHz → 16 kHz.
  - **Grenzen/Offen:** Mehrträger-PSKR (z. B. 4X_PSK63R), 16PSK und OFDM nicht angebunden; nur gegen das eigene fldigi-Testsignal geprüft; 8PSK-Bandbreiten bis über 1 kHz (Marker nur Symbolrate).
- **0.38.0 (02.10.2026): M37 RTTY: Frequenzknöpfe für DWD KW und DWD LW.**
  - **Dateien:** `Sources/App/RTTYSettingsStore.swift` (`dwdFrequencyHz` je Preset, `selectDWDFrequency`, gespeichert), `Sources/Rig/RigTuning.swift` (`RigTuneTarget.rtty(frequencyHz:centerHz:)`), `Sources/App/DigidecState.swift` (`rttyDWDTarget`, Abstimmung bei Wechsel von Preset und Frequenz), `Sources/UI/MainWindowView.swift` (`PresetPanel` mit Frequenzreihe), `ScheduleAutoRecorder.swift` (nutzt dasselbe Ziel und merkt die Frequenz).
  - **Verhalten:** Unter dem gewählten Preset DWD KW erscheinen die fünf Frequenzen aus dem Sendeplan (4583 DDK 2, 7646 DDH 7, 10100,8 DDK 9 – Programm 1; 11039 DDH 9, 14467,3 DDH 8 – Programm 2), unter DWD LW die 147,3 kHz (DDH 47). Ein Klick wählt die Frequenz und stellt mit QSY AUTO das Funkgerät auf USB-Dial = Frequenz − NF-Mitte. Ohne Wahl gilt die Automatik des Sendeplans (Tageszeit; LW: 147,3). Die Wahl gilt je Preset und bleibt erhalten. Das Preset „Amateur“ und „Eigene“ stimmen nichts ab.
  - **Korrektur:** Die Senderliste der RTTY-Karte nannte falsche Rufzeichen (7646 kHz = DDH 7, 10100,8 kHz = DDK 9) und kannte nur drei der fünf Frequenzen; jetzt wie im Plan.
  - **Tests:** 1551 Logiktests (+9: Wahl je Preset, andere Presets ohne Wahl, Abstimmziele 4583 / 147,3 / 10100,8 kHz, Frequenzen aus dem Plan).
- **0.39.0 (02.10.2026): M38 macOS App Icon.**
  - **Dateien:** `Resources/AppIcon-1024.png` (Master 1024x1024 PNG), `Resources/AppIcon.icns` (vollständiger macOS-Iconset 16–1024 px), `Tools/generate_app_icon.py` (Generator-Skript via `iconutil`).
  - **Design & Metapher:** Reduzierter Apple-Stil, passend zur Design-Familie von FT-991A Commander und PCR-1500 Commander. Dunkler, schiefergrauer Squircle mit feiner gebürsteter Metallstruktur, Apple HIG-konformer Geometrie und sanftem Schlagschatten. Im Zentrum die funktionale Metapher der digitalen Decodierung: Eine analoge NF/HF-Sinusschwingung (VFD Cyan) geht nahtlos über in diskrete digitale Rechteck-Impulse / Baud-Bits (VFD Amber und Cyan).
  - **Build-Integration:** `build_app.sh` bettet `AppIcon.icns` in `Digidec.app/Contents/Resources/` ein und registriert es über `CFBundleIconFile` in der `Info.plist`.
- **0.40.0 (02.10.2026): M39 RTTY-Karte: SYNOP ohne Kopfzeile und Zeilenumbrüche, Wertansicht.**
  - **Anlass:** In der Aufnahme vom 02.10. 18:37 UTC (DDK2, 4583 kHz) stand echter SYNOP-Text, aber die Karte blieb leer. Zwei Ursachen im fldigi-SYNOP-Decoder: (1) Er springt nur bei einer Kopfzeile `AAXX`/`BBXX`/`OOXX` an; wer mitten im Block einschaltet, bekommt keinen Klartext. (2) Er verwirft bei jedem Zeilenwechsel (CR) die angefangene Meldung; der DWD bricht die Zeilen nach etwa 60 Zeichen (oft vor Abschnitt 333) und setzt die Kopfzeile in eine eigene Zeile: Station, Windeinheit und Zeit gingen verloren.
  - **Dateien:** `Vendor/Fldigi/src/synop/fldigi_synop.cpp` (CR beendet die Meldung nicht mehr; Ende: „=“, NUL), `Sources/Decoders/RTTY/SynopDecoder.swift` (`SynopHeaderRecovery`), `Sources/Models/ModuleMaps.swift` (`SynopLog.Layer`, Zahlenwerte, Windeinheit), `Sources/Models/Geo.swift` (`MapMarker.valueText/valueLevel`), `Sources/UI/MapPanel.swift` (Messwert-Punkte, `accessory`), `Sources/UI/MapViews.swift` (Ansichtswahl SYMBOL/TEMP/DRUCK/WIND/SICHT).
  - **Kopfzeile ergänzen:** Beginnt eine Folge mit einer bekannten WMO-Stationsnummer, dann `iR iX h VV` (`0–4`, `1–7`), dann `N dd ff` und eine Gruppe `1sTTT` oder `00fff`, ergänzt Digidec `AAXX TTGG4` (Tag und letzte Dreistundenzeit von jetzt, Knoten) vor der Meldung. Fängt die Folge mit einem Bruchstück an (hier `02181`), wird dieses verworfen und ab dem nächsten Wort neu geprüft. Der Klartext trägt den Hinweis „Note=Header missing“, die Karte nennt ihn im Popup.
  - **Windeinheit:** fldigi kennt sie nur in der ersten Meldung nach der Kopfzeile; spätere Meldungen desselben Blocks übernehmen die zuletzt gesehene (sonst Knoten) und sind als „angenommen“ markiert.
  - **Wertansicht:** Temperatur (−20 … +35 °C, blau bis rot), Luftdruck (Meereshöhe, sonst Station; 985 … 1040 hPa), Wind (Knoten, Pfeil in Windrichtung, Farbe nach Beaufort), Sicht (km, rot = schlecht). Stationen ohne den Wert fehlen in der jeweiligen Ansicht.
  - **Ergebnis an der echten Aufnahme:** 2 Stationen auf der Karte (Leba 12,6 °C, 1031 hPa, Wind 195° 2 kn, Sicht 13 km; Poznan 14,3 °C, 1031 hPa).
  - **Tests:** 1579 Logiktests (+28): mehrzeilige Meldung mit Kopfzeile, ohne Kopfzeile mit Bruchstück, Rohtext unverändert, gewöhnlicher Text und Fünfergruppen ohne Meldungsform unberührt, Werte, Einheiten, Beaufort, Ansichten, Windpfeil, Popup-Hinweis.
  - **Beobachtung:** Der MT63-Pipelinetest scheiterte in einem Lauf, während nebenbei gebaut wurde (Echtzeit-Pipeline, CPU-Last); in einem Lauf ohne Last und in allen übrigen besteht er.
- **0.41.0 (02.10.2026): M40 RTTY-Karte: Seegebiete, Wetterlage, Warnungen, Schiffe.**
  - **Anlass:** Die DWD-Funkfernschreiben nennen ständig Gebietsnamen (Deutsche Bucht, Fischer, Skagerrak …), und der Nutzer wusste nicht, wo das ist. Der Text ist öffentlich (`https://opendata.dwd.de/weather/maritime/forecast/english/`, FQEN70, FQEN71, WODL45); drei Berichte vom 02.10.2026 liegen als Testdaten in `Tools/LogicTests/Samples`.
  - **Dateien:** `Sources/Models/SeaWeather.swift` (neu: `SeaArea`, `Gazetteer`, `SeaBulletinParser`, `SynopsisParser`, `SeaPhrase`, `SeaLog`, `NauticalPositions`), `Sources/Decoders/RTTY/RTTYController.swift` (`ReceiveTextModel.sea`), `Sources/Models/ModuleMaps.swift` (Schiffe, Boten, Weg; Ansicht `.sea`), `Sources/UI/MapViews.swift` (Ansichtswahl um SEE erweitert).
  - **Ansicht SEE:** (1) Seegebiete und Küstenabschnitte als Kreis mit Windstärke (Zahl, Farbe nach Beaufort, Pfeil in Windrichtung); Klick zeigt Wind, Sicht/Wetter und Seegang je Tag auf Deutsch (Wort-für-Wort-Übersetzung der formelhaften Berichtssprache, Unbekanntes bleibt englisch). (2) Sturmwarnungen (WODL45) rot über dem Gebiet, Stärke aus dem Text oder nach dem Wort (Sturm 10, Orkan 12). (3) Hochs und Tiefs der Wetterlage („A high 1037 Belarus moves to Romania“) als H/T mit Druck und Linie zur Zugrichtung; Fronten als Linie („cold front extends from southern Sweden to eastern Germany“); Ortsnamen über eine eingebaute Liste von Ländern, Meeren und Regionen mit Richtungsangaben („northeastern part of the Irminger Sea“, „close to the southwest of Iceland“). (4) Positionen im Text (`54-12.5N 007-30.2E`, `5430N 01015E`, `54°12′N 007°30′E`) als Warnpunkt mit dem Absatz.
  - **Gebiete:** 9 Seegebiete (FQEN70) und 8 Küstenabschnitte (FQEN71) mit **Näherungen** für Mittelpunkt und Radius (Kreise, keine amtlichen Grenzen).
  - **Robust gegen Funkfernschreiben:** Großbuchstaben, CR/LF, Steuerzeichen (ETX, NNNN), ein Zeichenfehler im Gebietsnamen, Empfang mitten im Bericht (ohne Tagesüberschrift: „Vorhersage“); das RYRY-Testbild ergibt nichts.
  - **Schiffe und Bojen:** Die Karte kannte nur Meldungen mit WMO-Stationsnummer; Schiffe (BBXX mit Rufzeichen) und Bojen fielen weg. Jetzt Schlüssel = Rufzeichen, Ort aus der Meldung, bei erneuter Meldung von einem anderen Ort der bisherige Weg (bis 40 Punkte) als Linie.
  - **Tests:** 1641 Logiktests (+62: alle drei Berichte, Gebiete, Wetterlage mit Ziel, Fronten, Übersetzung, Robustheit, Karte, Schiffe mit Weg, Positionen). Dabei fiel auf: ein Steuerzeichen (ETX) am Zeilenanfang verdeckte die Überschrift der Sturmwarnung; der Parser entfernt Steuerzeichen jetzt.
  - **Grenzen/Offen:** Format der Nautischen Warnnachrichten (WWXX60) und der Zeitreihenberichte (FQEN75 bis 79) unbekannt, nur Positionen werden gefunden; Warntexte der Küstenwarnungen („NR. 479 …“) werden nicht ausgewertet; keine Aufnahme eines echten Sturmwarnungsberichts vorhanden (nur „no warning“); Hoch/Tief-Lage nur so genau wie die Ortsliste.
- **0.41.1 (02.10.2026): Fehlerbehebung RTTY-Karte: SYNOP-Werte fehlten.**
  - **Anlass:** Aufnahme `RTTY_2026-10-02_193704Z`: Stationen standen als Symbol auf der Karte, Temperatur, Druck und Wind fehlten, obwohl der Decoder sie im Klartext lieferte.
  - **Ursache:** fldigi gibt den Klartext einer Meldung in mehreren Stücken aus, getrennt durch den Rohtext (Echo der Fünfergruppen). `SynopLog.flush` wertete jedes Stück einzeln aus; Folgestücke ohne „WMO Station=“ wurden verworfen, nur der Anfang (Station, Ort) kam an.
  - **Behebung:** `SynopLog` hält den Klartext der laufenden Meldung zusammen und setzt sie bei jedem neuen Stück neu zusammen (`parseRun`), bis die nächste Station beginnt; die Art (Land/Schiff/Boje) wird über die abgeschnittene Zeile „… observation“ weitergereicht; Schiffe beginnen auch bei „Ship/Buoy identifier=“; der Weg eines Schiffs bleibt bei Teilständen erhalten.
  - **Hinweis zur Anzeige:** Die Ansicht SYMBOL zeigt Werte nur im Popup; Zahlen auf der Karte gibt es in den Ansichten Temperatur, Druck, Wind und Sicht.
- **0.42.0 (03.10.2026): M41 RTTY-Abstimm-Offset-Korrektur (1000 Hz NF-Mitte) & DWD-Punktvorhersagen mit Wassertemperatur (SST, FQEN75–79).**
  - **RTTY-Abstimmfrequenz (1000 Hz NF-Mitte):**
    - **Ursache:** `RTTYController.poll()` rief `settings.followAFC(s.centerHz)` auf, welches den AFC-Offset dauerhaft in `UserDefaults` als `rttyCenterHz` schrieb. Driftete AFC durch Rauschen oder Störträger auf hohe Frequenzen (~2530 Hz), wurde dies dauerhaft gespeichert. `RigTuneTarget.rtty` stimmte den Transceiver auf `Sendefrequenz - 2530 Hz` ab, wodurch das Signal an die Filterflanke eines typischen 2,7-kHz-SSB-Filters geriet (oberer Ton bei ~2755 Hz) und bedämpft/verzerrt wurde.
    - **Behebung:** `followAFC` überschreibt `UserDefaults` nicht mehr. `RTTYSettingsStore.init()` und Preset-Auswahl prüfen und bereinigen gespeicherte Ausreißer außerhalb von 300...2200 Hz automatisch auf den Standardwert 1000 Hz. Die Mittenfrequenz-Anzeige in `RTTYPanels` besitzt nun einen 1-Klick-Reset-Button (`arrow.counterclockwise`) zum schnellen Zurücksetzen auf 1000 Hz.
  - **DWD 5-Tage-Punktvorhersagen mit Wassertemperatur (SST, FQEN75–79):**
    - Erkennt die im DWD-Sendeplan ausgestrahlten 5-Tage-Punktvorhersagen (z. B. `WN.O.IRELAND (54.0N  13.9W) SST: 14 C`, `ISLE.O.MAN-S (53.5N   5.3W) SST: 16 C`, `SW.O.IRELAND (51.0N  13.0W) SST: 16 C`).
    - Parse-Logik in `SeaWeather.swift` (`SeaPointForecast`, `SeaPointPeriod`, `SeaBulletinParser.parsePointForecasts`): extrahiert Stationsname, Koordinaten, Wassertemperatur (`SST: xx C`), Vorhersage-Intervalle mit Wochentag, Datum, Uhrzeit, Windrichtung, Windstärke (Beaufort), Böen und Wellenhöhe in Metern.
    - Kartenanzeige in `RTTYMapView`:
      - **TEMP:** Zeigt die Punkte mit Wassertemperatur als Gradzahl (`14`, `16`) mit farblicher Temperaturskala.
      - **WIND:** Zeigt Pfeil mit Windrichtung und Beaufort-Stärke der aktuellen Vorhersageperiode.
      - **SEE / SYMBOL:** Zeigt Punkt-Marker mit vollständigem Popup (Wassertemperatur, Vorhersage-Tabelle mit Wellenhöhen und Wind) bzw. Wellensymbol.
  - **Tests:** 1665 Logiktests (+24: DWD-Punktvorhersagen mit Koordinaten, SST, 10 Perioden mit Wind/Böen/Wellenhöhe, Kartenmarker für TEMP und WIND, RTTY-Center-Sanitizing und AFC-Schutz).
- **0.42.1 (03.10.2026): UI-Optimierung Audioquellen-Auswahl (Pop-up-Button & Header).**
  - **Verbesserung:** Der Auswahlschalter für die Audioquelle im Panel „Eingang“ (`InputPanelView.swift`) sah bisher wie ein statisches Statusfeld aus. Er wurde durch eine taktilen Pop-up-Button mit Verlauf, Hover-Effekt, Leuchtrand, deutlichem Dropdown-Pfeil-Container und übergeordnetem Header `AUDIOQUELLE / GERÄT` mit `AUTO-SYNC` / `MANUELL`-Badge ersetzt. Die Menüsektionen wurden zur besseren Orientierung um klare Bezeichnungen erweitert.
- **0.43.0 (03.10.2026): M42 Wege auf der Karte: APRS und ACARS.**
  - **Anlass:** Bewegt sich eine Station, soll eine Linie ihren Weg zeigen. APRS hatte den Weg schon (`APRSStation.track`), er war aber dünn und unter den Symbolen kaum zu sehen; ACARS kannte keine Flugzeugorte (nur Flughäfen aus OOOI-Berichten).
  - **ACARS-Positionen:** `Sources/Decoders/ACARS/ACARSPosition.swift` (`ACARSPositionParser.parse(label:text:)` → `ACARSPositionReport` mit Ort, Höhe, Zeit, Kurs, Start/Ziel). 29 Formate in 18 Labels (H1/ARINC 702, 10, 12, 15, 16, 1L, 20, 21, 22, 24, 2P, 44, 4J, 58, 80, 83, HX, 4T) nach der Referenz acars-decoder-typescript (airframes.io); Abweichungen und Zweifelsfälle: `Vendor/Acars/UPSTREAM_ACARS.md`. `ACARSAircraft` führt Ort, Höhe, Kurs und den Weg (`track`, höchstens 300 Punkte); unmögliche Sprünge werden verworfen (Geschwindigkeit über 1500 km/h), zweimal an derselben neuen Stelle gilt der Ort. Karte: Flugzeug (Symbol, Kurs, Flugnummer, Höhe, Strecke, Weglänge im Auswahlfeld) mit Linie; Start- und Zielflughäfen mit Großkreislinie wie bisher. Positionen aus Abwärtsmeldungen (und HX).
  - **APRS-Wege:** Wegpunkte erst ab 25 m Abstand (GPS-Rauschen ruhender Stationen bildete Knäuel), ungenaue Positionen („4903.  N“) verlängern den Weg nicht, Zeitpunkt je Wegpunkt (die Karte zeigt nur den gewählten Zeitraum 1 h / 6 h / 24 h), Linie erst ab 100 m Wegstrecke, Weglänge im Auswahlfeld.
  - **Karte (`MapPanel`):** Wege mit dunkler Kontur, kräftigem Kopf (letzte vier Abschnitte) als Fahrtrichtung; Auswahl eines Punkts zoomt auf den ganzen Weg und markiert jede empfangene Position (Anfang weiß); Schalter **SPUR** (an/aus, gemerkt); `MapContent.region` schließt die Wege ein.
  - **Werkzeuge:** `Tools/MakeSignal/make_signal.sh acars <skript> <wav>` erzeugt Testsignale (Skript: `Sekunde|Kennzeichen|Flug|Label|Text`), `decode_file.sh --acars` nennt die gelesene Position. Entwicklungshilfen (Umgebungsvariablen): `DIGIDEC_MODULE=aprs|acars|…` (Startmodul), `DIGIDEC_MAP_VIEW="Breite,Länge,Spanne"`, `DIGIDEC_MAP_SELECT=<Punkt-ID>`; zusammen mit `DIGIDEC_PLAY_FILE` und `DIGIDEC_SNAPSHOT` lässt sich die Karte ohne Funkgerät prüfen.
  - **Prüfung an der App:** WA8LMF-Aufnahme (bewegte Stationen im Raum Los Angeles) und synthetische ACARS-Flüge (zwei Flugzeuge mit je neun Positionen, Start/Ziel) im Schnappschuss: Linien, Köpfe, Auswahlfeld, Zoom auf den Weg.
  - **Tests:** 1844+ Logiktests: 65 Positionsmeldungen aus der Referenz (Orte auf 0,001° genau, Höhe, Zeit, Start/Ziel, Kurs; 14 Meldungen ohne Position), Rechenhilfen, Sprungschutz, Weg und Kurs des Flugzeugs, ACARS-Controller und -Karte, APRS-Weg (GPS-Rauschen, ungenaue Position, Zeitraum, Weglänge).
  - **Grenzen/Offen:** nur Formate mit eindeutiger Position (keine Flugplan-, Wetter- und Ereignismeldungen); Label 20 und 80 mit Punktschreibweise sind aus der Referenz übernommen bzw. abweichend gelesen (UPSTREAM_ACARS.md); Live-Empfang offen (131,725 / 131,825 MHz AM; welche Fluggesellschaften Positionen schicken, hängt vom Gebiet ab). DSC-Schiffe und ALE haben noch keinen Weg.
- **0.44.0 (03.10.2026): M43 Funkruf geprüft: Prüfstand, Diagnose, Aufnahme.**
  - **Anlass:** „Auf POCSAG wird möglicherweise nichts entschlüsselt. Nochmal prüfen, ob alles passt.“ Der erste Live-Versuch (DAPNET 439,9875 MHz) hatte nichts angezeigt; ob am Empfänger oder am Signalweg, war nicht zu sehen.
  - **Prüfung:** (1) Code gegen den POCSAG-Aufbau und multimon-ng gelesen (BCH, Adresse und Funktion, Ziffern und Klartext, Stapel und Synchronwort); die vier echten Aufnahmen liefern wie in 0.30.0 dieselben Meldungen. (2) **Prüfstand `Tools/PagerBench`** (neu): Aussendungen durch eine Nachbildung des Funkwegs (FM-Modulator, Rauschen im Zwischenfrequenzfilter, Diskriminator, NF-Kette mit Entzerrung, Hochpass, Sprachband, Rauschsperre, Knackser, Drift, Ablage), Digidec gegen multimon-ng, 20 Aussendungen je Bedingung und Baudrate. Ergebnis: **kein Fehler im Empfänger**; 100 % bis 8 dB Rauschabstand (multimon-ng 85 %), 100 % bei Kopplungs-Hochpass 150 und 300 Hz (multimon-ng 23 und 0 %), 87–98 % im Sprachband 300–3000 Hz (multimon-ng 0 %); Tabelle in `Vendor/Pager/UPSTREAM_PAGER.md`. (3) Ganzer App-Weg (Datei → AudioPipeline → PagerDecoder → Controller → Liste) mit einer Sitzungsaufnahme aus dem Prüfstand (`--session`): alle Meldungen in der Liste.
  - **Folgerung:** Kommt am Funkgerät nichts an, liegt es davor: Rauschsperre zu, Kanal (L/R), Betriebsart (FM, nicht schmal), Frequenz, zu schwach, oder gerade sendet niemand (DAPNET sendet in Zeitschlitzen). Deshalb:
  - **Diagnose im Panel Funkruf:** `POCSAGFramer` zählt je Baudrate Vorspann (≥ 32 Wechsel), Synchronwörter, gute und schlechte Stapel, gültige und ungültige Codewörter, Meldungen, Polarität und Zeitpunkte; `PagerDecoder` meldet zusätzlich den Eingangspegel (dBFS). `PagerDiagnosis.assess` macht daraus „KEIN AUDIO“ (rot), „WARTEN AUF FUNKRUF“ (gelb), „VORSPANN OHNE SYNCHRONWORT“, „SYNCHRON, ABER FEHLERHAFT“, „VIELE FEHLER“ (rot, mit Hinweis) oder „EMPFANG GUT“ (grün); darunter die Zähler. Papierkorb leert Liste und Zähler.
  - **REC im Funkruf-Panel:** nimmt den Eingang als WAV auf (`~/Documents/Digidec/Recordings/PAGER_<UTC>_<Hz>_<Mode>_DAPNET.wav`, `InputRecorder.fileName(prefix:)`); damit lässt sich ein misslungener Empfang mit `decode_file.sh <wav> --pager` und dem Prüfstand untersuchen.
  - **Anzeige:** Knopf `ÄÖÜ` (Standard an): `{ | } ~` → ä ö ü ß (AlphaPoc, DIN 66003), `[ \ ]` → Ä Ö Ü nur im Wortzusammenhang (`PagerText.germanUmlauts`).
  - **Tests:** 11 Funkbedingungen (512/1200/2400 Bd) mit Meldungen und Zählern, Sprachband, Polarität (normales Audio wird invers gelesen, umgekehrtes direkt), 6 dB, Rauschen ohne Meldung, Beurteilung der Diagnose (alle Fälle), Dateiname der Aufnahme, Umlaute. Die zufallsbehaftete MT63-Prüfung „1000S bei 6 dB S/N“ schlug in einem Lauf an der Grenze fehl (bekannt, siehe 0.36.0).
  - **Grenzen/Offen:** Skyper-Zeichensatz (Zeichen +1) und FLEX unter Funkbedingungen nicht nachgebildet; echte DAPNET-Aufnahmen fehlen (alle echten Aufnahmen stammen aus multimon-ng); Live-Empfang offen: bei „KEIN AUDIO“ oder „WARTEN“ die Hinweise im Panel beachten, bei Misserfolg REC drücken und die WAV-Datei bereithalten.
- **0.45.0 (03.10.2026): M44 CW- und PSK-Skimmer: alle Signale im Audio zugleich lesen.**
  - **Anlass:** „CW Skimmer / PSK Skimmer implementieren“. Die Module CW und PSK (fldigi) lesen ein Signal. Der Skimmer sucht im ganzen Audio (0,2 … 3,3 kHz) alle Signale einer Betriebsart, liest jedes in einem eigenen Kanal, nennt Rufzeichen, Land, Rauschabstand und Tempo und meldet Spots wie das Reverse Beacon Network.
  - **Engine** (`Sources/Decoders/Skimmer`, eigene Umsetzung; Verfahren und Parameter in `Vendor/Skimmer/UPSTREAM_SKIMMER.md`): Spektrum (1024-FFT, 7,8 Hz je Bin, 1 s gemittelt) → Rauschen als 20-%-Quantil in ±500 Hz → Spitzen über der Schwelle (Standard 8 dB) → Spuren → je Spur Mischer, Tiefpass und Dezimierung auf 500 Hz → **CW-Kanal** (Hüllkurve, Hysterese, Punktlänge aus den letzten 24 Marken, Morsetabelle) oder **BPSK-Kanal** (Takt aus dem Betragsquadrat nach Oerder-Meyr, differentielle Entscheidung, Varicode, Frequenznachführung). Ein Signal kommt erst in die Liste, wenn es lesbaren Text liefert; Dauerträger, Brummen und Rauschen werden verworfen und 90 s gesperrt. Rauschabstand in 500 Hz wie bei CW Skimmer und im RBN. Rechenaufwand: 40 s Audio mit 9 Kanälen in 0,1 s.
  - **Modul SKIMMER** (Modul-Leiste hinter PSK): Betriebsart CW | BPSK31 | BPSK63. Liste **SIGNALE** (NF Hz, HF kHz, Rufzeichen, Land mit Flagge, S/N, WpM bzw. Baud, Alter, Text; Klick wählt, zeigt den ganzen Text und „IN CW/PSK ÖFFNEN“: wechselt ins Modul CW bzw. PSK auf den Ton, BPSK31/63 passend), Liste **SPOTS** (UTC, Frequenz, Rufzeichen, Land, S/N, Tempo, CQ/DE), **LOG** (`~/Documents/Digidec/Logs/SKIMMER-<UTC-Datum>.txt`, Zeile wie im RBN: `14020.7  DL1ABC  CW  18 WPM  24 dB  CQ  15:24:31Z`). Einstellungen: Band (CW: 160 … 6 m am Anfang des CW-Bereichs, PSK: PSK31-Anruffrequenz; „frei“ stimmt das Funkgerät nicht ab), Schwelle 4 … 16 dB, Mindest-S/N, NUR RUFZ., Haltezeit 1 … 60 min. Karte: gehörte Rufzeichen (Mittelpunkt des DXCC-Gebiets). HF-Frequenz = Dial (vom Funkgerät, sonst vom Band) + NF.
  - **Wasserfall:** neue Markierungsart `WaterfallMarkerStyle.channels`: je Signal eine gestrichelte Linie mit Rufzeichen (aktiv hell, still abgedunkelt, gewählt hervorgehoben); Klick im Wasserfall wählt die nächste Station.
  - **URL und QSY:** `digidec://decode?mode=skimmer&preset=cw|psk31|psk63`; QSY AUTO stellt den Dial des gewählten Bandes in USB (`RigTuneTarget.skimmer`).
  - **Prüfstand `Tools/SkimBench`:** `skim_bench.sh synth <cw|psk31|psk63>` mischt Signale mit bekanntem Text und Rauschen (Rauschabstand in 500 Hz) und misst Fund, Frequenz, S/N, Tempo und Zeichenfehlerrate; `… file <wav> <modus>` liest eine Aufnahme; `--dump` schreibt die Mischung als WAV (für `DIGIDEC_PLAY_FILE`). Ergebnis (40 s): 9 CW-Signale (8 … 30 dB, 12 … 30 WpM) alle gefunden ohne Scheinkanäle; BPSK31 und BPSK63 je 6 Signale (12 … 25 dB) alle gefunden, Zeichenfehlerrate 0 %; Rauschen und ungetasteter Träger ergeben kein Signal.
  - **Echte Aufnahmen** (freesound.org, nur lokal): PSK31 14,071 MHz (Twente): 3 bis 4 von etwa 8 Trägern lesbar („599“, „MARCUS FROM MUNICH“, „de OH8MXJ“), mit Fehlern wie bei fldigi. CW 40 m (viele schwache, flatternde Stationen): fldigi liest auf denselben Tönen ebenfalls nur Bruchstücke; der Skimmer liefert einzelne Rufzeichenteile und einige Scheinkanäle. **Sauberes CW ab etwa 8 dB wird gelesen, flatterndes oder verrauschtes nicht.**
  - **Prüfung an der App:** `DIGIDEC_MODULE=skimmer DIGIDEC_PLAY_FILE=<Mischung.wav> DIGIDEC_SNAPSHOT=<png>`: Liste, Wasserfall-Markierungen und Karte der neun CW- und der sechs PSK-Signale. Entwicklungshilfe: `DIGIDEC_SNAPSHOT_STEPS=skimmer:liste|karte|beide`.
  - **Beim Bau gefunden:** (1) Das Testsignal sendete Wörter mit nur 4 statt 7 Punktlängen Abstand; die Wörter verklebten und der Rufzeichenspeicher fand nichts. Die Wortende-Schwelle des Empfängers (5 Punktlängen) war richtig, das Testsignal falsch. (2) Eine übersteuerte Demo-WAV erzeugte Scheinsignale (Verzerrungsprodukte); der Prüfstand skaliert jetzt auf Spitze 0,9. (3) Der angezeigte Rauschabstand fiel in Sendepausen (Pegel und Spur klingen ab): gemessen wird nur bei gedrückter Taste bzw. erkanntem Träger, sonst bleibt der letzte Wert. (4) Beim Nachführen der Taktlage kamen Symbole doppelt oder gingen verloren: Die Korrektur ist auf einen Abtastwert je Symbol begrenzt.
  - **Tests:** 2033 Logiktests, alle bestanden: Tabellen (Morse, Varicode-Rundlauf), Betriebsarten, URL, Abstimmziel, Einstellungen (Dial: Funkgerät vor Band, Klick im Wasserfall), Engine (4 CW-Signale, je 5 BPSK31/63-Signale, Rauschen, Dauerträger, Kanalende, reset, Rauschabstand), Controller (Liste, Rufzeichen aus Textstücken, Spots mit 10-Minuten-Sperre, Filter, Karte, Auswahl, Haltezeit, Logzeile), Pipeline 48 kHz → 8 kHz.
  - **Grenzen/Offen:** nur CW, BPSK31, BPSK63, immer nur eine Betriebsart zugleich; Spots gehen nirgends hin (kein RBN, kein Cluster); Live-Empfang mit PCR-1500 oder FT-991A offen (USB, breiter Filter, Schwelle nach Bandlage einstellen).
- **0.45.1 (03.10.2026): Skimmer: Schwund, Seitenbänder, Drift.**
  - **Anlass:** Prüfung des Skimmers mit Fällen, die eine echte Aufnahme zeigt, die die Prüfstand-Mischung aber nicht hatte (Schwund, schnelle Telegrafie, wandernde Träger).
  - **CW-Schwund:** Der Zeichenpegel fiel nur mit 2 s Zeitkonstante; bei Einbrüchen von 14 dB in wenigen Sekunden lagen die Zeichen unter der Schwelle (QSB mit Tiefe 0,7 … 0,8: **keine** Sendung gelesen). Jetzt fällt er in Pausen mit mindestens 1 s (bei langsamer Telegrafie 12 Punktlängen) und nach jedem Zeichen zu 90 % auf dessen mittleren Pegel: **alle** Sendungen gelesen (4/4, 4/4, 5/5), schwache (4 dB) und langsame (8 WpM) Signale unverändert. Aufnahme in die Liste ab 6 statt 8 WpM (ein 8-WpM-Signal wurde als 7,8 gemessen und nie aufgenommen).
  - **Seitenbänder:** Ein schnelles CW-Signal (45 WpM, 20 dB) erschien zweimal (Tastklicks 75 Hz daneben); ebenso Verzerrungsprodukte starker PSK-Signale. Ein Kanal neben einem stärkeren, der dasselbe liest (letzte 24 Zeichen, ein Sechstel Fehler erlaubt), kommt nicht in die Liste und wird 90 s gesperrt; gilt für CW (160 Hz), BPSK31 (80 Hz) und BPSK63 (140 Hz).
  - **PSK-Drift:** Die Nachführung durfte nur ±25 Hz von der ersten Entdeckung wandern; Träger mit Drift 0,8 Hz/s blieben nach 30 s stehen und gingen verloren. Jetzt gilt ±25 Hz um die Spur der Engine, die dem Signal folgt (BPSK31 0,8 Hz/s, BPSK63 0,5 Hz/s verfolgt).
  - **Falschmeldungen:** Rauschen mit zwei Dauerträgern und Knacksern: je Betriebsart und Schwelle (6 und 8 dB) 12 × 120 s keine Aufnahme in die Liste.
  - **Oberfläche:** Tabellenköpfe der Signal- und Spotliste stehen fest über den scrollenden Zeilen; Land ausgeschrieben. Entwicklungshilfe: `DIGIDEC_SKIMMER_TAB=spots` öffnet die Spotliste (für Schnappschüsse).
  - **Prüfstand:** `SkimTestSignal.bpsk(…, driftHzPerSecond:)`; die Demo-WAV des Prüfstands (`--dump`) ist auf Spitze 0,9 skaliert.
  - **Tests:** 2045 Logiktests, alle bestanden (+12: Schwund 3 Fälle, langsame und schnelle Telegrafie mit Tempo, Drift beider PSK-Arten, Textvergleich für Seitenbänder).
  - **Grenzen/Offen:** Sehr tiefer und schneller Schwund (Tiefe ≥ 0,9, Periode ≤ 2 s) bleibt unlesbar; echte CW-Aufnahmen aus dichtem Band mit flatternden Signalen weiter nur in Bruchstücken (wie bei fldigi).
- **0.46.0 (03.10.2026): M45 Radiosonden: RS41 decodieren.**
  - **Anlass:** „Könnte man Wettersonden decodieren?“ – nach Prüfung von Audioweg und Beispielaufnahmen: „Wenn Du die Chance hoch genug einschätzt, würde ich den Decoder für RS41 bauen wollen.“ Der Nutzer hatte mit dem PCR-1500 und 50-kHz-Filter bereits NOAA-APT decodiert (breites Diskriminator-Audio).
  - **Vorarbeit:** Bandbreite des Audios vom USB-Codec gemessen (Rauschen bei offener Rauschsperre, kein harter Abfall bis über 12 kHz; ohne Messsignal nur grob). Beispielaufnahmen aus dem Netz: RS41-SGM `brokenrs41.wav` (rfhead.net) und der IQ-Satz `sonde_samples.tar.gz` (611 MB, radiosonde_auto_rx), nur lokal unter `Vendor/_upstream/sonde`. `rs41mod` als Gegenprobe gebaut.
  - **Empfänger** (`Sources/Decoders/Sonde`, Aufbau in `Vendor/Sonde/UPSTREAM_SONDE.md`): Reed-Solomon RS(255,231) mit Berlekamp-Massey, Rahmenblöcke mit CRC-16, ECEF → Breite/Länge/Höhe/Geschwindigkeit, GPS-Zeit → UTC, Kalibrierdaten → Temperatur, Feuchte, Druck, Frequenz, Typ, Abschaltzähler. Demodulator: Kopfsuche mit beiden Polaritäten (breites Plateau → Mitte; mehrere zugleich laufende Aufnahmen, weil die Vorbereitungsfolge dem Kopf ähnelt), Takt aus Nulldurchgängen (Stück für Stück) oder Augenraster, entscheidungsrückgekoppelter Entzerrer (Kleinste Quadrate) für verzerrte Funkketten, Teilauswertung gültiger Blöcke.
  - **Ergebnis:** echte Aufnahme (RS41-SG am Boden, 120 s): 119 von 119 Rahmen, Position/Höhe/Wind/Temperatur/Feuchte **identisch** mit rs41mod (118). Nachgebildeter Funkweg (`Tools/SondeBench`): alle Rahmen bei C/N 8 dB, De-Emphase 75 und 150 µs, Hochpass 300 und 500 Hz, Sprachband, Ablage ±5 kHz, ±300 ppm, 50-kHz-Filter; rs41mod liest bei den meisten dieser Verzerrungen nichts. 120 s Audio in 0,5 s.
  - **Modul SONDE** (Modul-Leiste hinter ACARS): Liste (Sonde, Phase AM BODEN/AUFSTIEG/ABSTIEG/GELANDET, Höhe, Steigen, Entfernung, Peilung, Temperatur, Feuchte, Frequenz, Alter), Einzelheiten (Position, höchste Höhe, Wind, Elevation, Messwerte, Batterie, Satelliten, Landeprognose, Höhenverlauf; Koordinaten kopieren, in Karten öffnen), Karte mit Weg, Landemarke, Fallinie und Linie vom Standort, Abstimmanzeige mit Diagnose (KEIN AUDIO, SUCHE SONDE, SIGNAL ABER NICHTS LESBAR, NUR TEILE, EMPFANG GUT), REC, LOG (CSV je Rahmen). Einstellungen: Frequenz (400 … 406 MHz, Raster 10 kHz, Schritte, gehörte Frequenzen), Filter 15 oder 50 kHz, Haltezeit. QSY AUTO stellt FM mit dem Filter ein (`RigTuneTarget.sonde`).
  - **Werkzeuge:** `decode_file.sh <wav> --sonde`; `make_signal.sh sonde - <wav> …` erzeugt einen RS41-Flug (Aufstieg, Platzen, Sinkflug, Wind) als Audio; `Tools/SondeBench/{sondechan,sweep}.py` (numpy, scipy) bildet den Funkweg nach.
  - **Beim Bau gefunden:** (1) Das Verhältnis der Kopfkorrelation ist 1 auf einem breiten Plateau; der erste Treffer lag am Rand, die Abtastlage um 3 Abtastwerte daneben (Mitte des Plateaus nehmen). (2) Die Vorbereitungsfolge erzeugt falsche Kopftreffer mit Verhältnis bis 0,9, die ein einzelnes Aufnahmefenster blockierten (43 von 119 Rahmen fehlten); mehrere Aufnahmen gleichzeitig. (3) Die Bitdauer der Sonde weicht von der Nennbitdauer ab; die Nulldurchgänge müssen schrittweise ausgewertet werden, sonst rastet ein Taktfehler von 300 ppm falsch ein. (4) Verlaufsspeicher bei 96 kHz zu klein.
  - **Tests:** 2116 Logiktests, alle bestanden.
  - **Grenzen/Offen:** nur RS41; M10/M20, DFM u. a. offen. Das Audio des PCR-1500 wurde nicht mit einer Sonde gemessen (REC bereithalten). Kein Suchlauf über das Band. Der FT-991A empfängt 400 … 406 MHz nicht. Live-Empfang offen: Starts vorher um etwa 23 und 11 UTC (für 00 und 12 UTC); in Flughöhe reicht wohl eine 70-cm-Antenne über mehrere hundert Kilometer.
- **0.47.0 (04.10.2026): Modul-Leiste nach Frequenzbereich und A–Z.**
  - **Anlass:** Die Leiste hatte 23 Module in Entstehungsreihenfolge. Jetzt zwei Rubriken mit farbiger Leiste links und Kürzel: **HF** (Amber; Lang-, Mittel-, Kurzwelle) und **VHF/UHF** (Grün), darin jeweils A–Z (Umlaute wie Grundbuchstabe, also TÖNE bei T). Bei Platzmangel brechen die Schaltflächen in die nächste Zeile um (`ModuleFlowLayout`).
  - **Zuordnung** (`DecoderModuleInfo.band`, je Modul genau eine Rubrik nach Haupteinsatz): VHF/UHF = ACARS, APRS, PAGER, SONDE, TÖNE; alles andere HF. Grenzfälle: SSTV (auch ISS 145,8 MHz), FT4/WSPR (auch UKW-Bänder) und DSC (auch Kanal 70) liegen in HF.
  - Reihenfolge der Enum-Fälle unverändert (Entstehungsreihenfolge); die Leiste sortiert über `DecoderModuleInfo.Band.modules`.
  - **Tests:** Logiktests ergänzt (jedes Modul genau einmal, A–Z, Inhalt VHF/UHF, erstes/letztes HF-Modul). Nicht gebaut und nicht ausgeführt (Sitzung ohne Swift-Toolchain): am Mac `./build_app.sh` und Logiktests laufen lassen.
- **Nächste Schritte:**
  - Live-Tests der neuen Module (APRS, WSPR, PSK, Olivia, MT63, DSC, ALE) und der übrigen (WEFAX, DCF77, EFR, SSTV, geplante Aufnahmen); APRS auf 144,800 MHz mit dem PCR-1500 oder FT-991A.
  - Sonden live: PCR-1500, FM, 15-kHz-Filter (50 kHz geht auch), Frequenz einer Sonde in der Nähe (Starts etwa 23 und 11 UTC); bei Misserfolg REC drücken und die WAV bereithalten. Danach Suchlauf über 400 … 406 MHz, M10/M20 und DFM.
  - Skimmer live: 20 m CW (14,020 MHz) und PSK31 (14,070 MHz) mit breitem USB-Filter; Schwelle, Mindest-S/N und Scheinsignale beurteilen, Fehlerbild abwarten (insbesondere CW bei QSB und QRN).
  - AIS (161,975 / 162,025 MHz, 9600 Bd GMSK): erst die Bandbreite des FM-Audios beider Geräte messen (Aufnahme 30 s), dann Decoder; Karte und Stationsliste sind da.
  - JT65/JT9 (WSJT-X), Mehrträger-PSKR/OFDM; Bildempfang (MFSK, Thor, IFKP, FSQ); FSQ-Rufzeichenauswertung.
  - Parallelbetrieb mehrerer Module (kein Warnton, vom Nutzer nicht gewünscht).
  - CW-Erkennung verbessern (Fehlerbild vom Nutzer abwarten).

