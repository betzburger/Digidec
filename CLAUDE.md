# Digidec – Richtlinien für KIs und Entwickler

Diese Datei wird von KI-Assistenten (Claude Code, Antigravity, OpenCode, Pi, Hermes etc.) beim Start automatisch gelesen.

## 1. Zentrale Übergabe & Dokumentation (Pflicht!)

- **Start jeder Sitzung:** Zuerst **[`PLAN.md`](PLAN.md)** lesen. Dort steht, was gebaut wurde, warum, woraus und wo das Projekt aktuell steht.
- **Ende jeder Sitzung:** Vor dem Abschluss **Abschnitt 11 („Aktueller Stand“)** in [`PLAN.md`](PLAN.md) fortschreiben:
  - Datum und Version.
  - Was wurde geändert, hinzugefügt oder behoben?
  - Nachweise, Tests und Grenzen festhalten.
  - Gegebenenfalls [`README.md`](README.md) und [`THIRD_PARTY.md`](THIRD_PARTY.md) synchron halten.

## 2. Versionsschema (Alpha-Phase: `0.x.y Alpha`)

- **Kleine Änderungen / Bugfixes / Refactorings:** Inkrementieren die dritte Stelle `y` (z. B. `0.80.0` -> `0.80.1`).
- **Neue Module / größere Features:** Inkrementieren die zweite Stelle `x`, die dritte Stelle wird auf `0` zurückgesetzt (z. B. `0.80.x` -> `0.81.0`).
- **Wichtig bei Versionssprüngen:** Die Versionsnummer muss immer synchron an zwei Stellen gepflegt werden:
  1. [`Sources/App/AppVersion.swift`](Sources/App/AppVersion.swift) (`AppVersion.current`)
  2. [`build_app.sh`](build_app.sh) (`CFBundleShortVersionString` und `CFBundleVersion`)

## 3. Bauen und Testen

- **Logiktests ausführen:**
  ```bash
  Tools/LogicTests/run_logic_tests.sh
  ```
  (Exit-Code 0 = bestanden. Schneller Lauf einzelner Gruppen: z. B. `--only sdr,dab` oder `--parallel`).
- **App bauen:**
  ```bash
  ./build_app.sh
  ```

## 4. Architektur & Konventionen

- **Plattform:** macOS 14+, Swift 6, SwiftUI, Swift Package.
- **Design:** `RadioTheme` (einheitliches Erscheinungsbild wie FT-991A Commander und PCR-1500 Commander).
- **Audio & SDR:**
  - `AUDIO`: Empfang über CoreAudio (USB-Codec des Funkgeräts, Mikrofone, virtuelle Kabel wie VALHost/BlackHole).
  - `DATEI`: Offline-Dateien (WAV, AIFF, CAF).
  - `SDR`: Direkter I/Q-Empfang von Hardware (HackRF, RTL-SDR, SDRplay) mit eigener Software-Demodulation.
- **Funkgerätesteuerung:** Ausschließlich über `rigctld` (Hamlib-Protokoll, TCP) oder WebSocket (SDRconnect). Digidec öffnet keine seriellen Ports.
