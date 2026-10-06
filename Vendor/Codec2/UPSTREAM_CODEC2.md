# Codec2 und FreeDV – Herkunft und Abweichungen

## Quelle

| Teil | Herkunft | Lizenz |
|---|---|---|
| Codec2-Bibliothek (Sprachcodec, FreeDV-Modems 1600, 700C, 700D, 700E, LDPC, OFDM, Varicode-Textkanal, Daten-Betriebsarten) | **Codec2** (David Rowe VK5DGR und Mitwirkende), https://github.com/drowe67/codec2, Version 1.2.0, Commit `310777b` (17.03.2026), Ordner `src` | LGPL-2.1 (`COPYING_codec2_LGPL-2.1.txt`) |

Das Original liegt unter `Vendor/_upstream/freedv/codec2` (nicht im Git; neu holen mit
`git clone --depth 1 https://github.com/drowe67/codec2.git Vendor/_upstream/freedv/codec2`).
`python3 Vendor/Codec2/port_codec2.py <Ordner mit den erzeugten codebook*.c>` kopiert alles (Aufruf und Erzeugung der Tabellen siehe Kopf des Skripts) und bricht ab, wenn die Quelle nicht wie erwartet aussieht.

Lizenz: LGPL-2.1 erlaubt das Einbinden in ein Programm unter GPL-3.0 (Abschnitt 3 der LGPL: Umwandlung in die GPL ab Version 2). Die Quelle von Codec2 liegt vollständig bei (Ordner `src`), die Änderungen stehen unten.

## Aufbau

- `src/*.c`, `src/*.h`: die 63 Quelldateien der Bibliothek (Liste aus `src/CMakeLists.txt`, `CODEC2_SRCS`), acht davon (`codebook*.c`) von cmake erzeugt (Hilfsprogramm `generate_codebook` des Originals), dazu alle Header ohne die Testvektoren (`*_test.h`).
- `include/codec2/version.h`: von cmake aus `cmake/version.h.in` erzeugt.
- `include/codec2_digidec.h`: Sammelheader für Swift (`codec2.h`, `freedv_api.h`, `modem_stats.h`).

## Abweichungen

1. **Keine Quelltextänderung.** Alle Dateien sind byteweise die des Originals.
2. **Übersetzung** in `Package.swift` (Ziel `Codec2`): `-O3 -w`, `GIT_HASH` als Definition (cmake setzt es aus Git), ohne LPCNet (die neuronale Betriebsart FreeDV 2020 ist nicht dabei; `__LPCNET__` ist nicht gesetzt) und ohne Prüfprogramme.
3. **Umbenannte Symbole** (per Definition für dieses Ziel, `Package.swift` und `Tools/build_fldigi.sh`): `kiss_fft`, `kiss_fftr`, `kiss_fftri`, `kiss_fft_alloc`, `kiss_fftr_alloc`, `kiss_fft_stride`, `kiss_fft_cleanup`, `kiss_fft_next_fast_size` und `encode` heißen `c2_…`, weil fldigi und FT8 dieselben Namen liefern (sonst doppelte Symbole beim Binden).

## Nutzung

`Sources/Decoders/FreeDV/FreeDVModem.swift` kapselt die Schnittstelle `freedv_api.h` (Öffnen je Betriebsart, `freedv_rx` in Blöcken nach `freedv_nin`, Statistik, Textkanal, `freedv_tx` für Prüfstände). Dasselbe Codec2 liefert später den Sprachcodec für M17.
