# FAAD2 (AAC-Decoder)

- **Quelle:** https://github.com/knik0/faad2, Version 2.11.4 (Commit 521d105, 01.10.2026), Ordner `libfaad` unverändert nach `src/`, `include/neaacdec.h` nach `include/`.
- **Lizenz:** GNU General Public License, Version 2 oder (nach Wahl) jede spätere (`COPYING`); „Code from FAAD2 is copyright (c) Nero AG, www.nero.com“.
- **Verwendung:** DAB+ (Modul DAB): Audio-Zugriffseinheiten mit AAC-LC, HE-AAC (SBR) und HE-AAC v2 (PS) bei einer Rahmenlänge von 960 Werten. Der AudioToolbox von macOS nimmt die 960er-Transformation nicht an (geprüft: der Magic Cookie mit `frameLengthFlag` wird abgelehnt).
- **Übersetzung:** `Package.swift`, Ziel `Faad2`: SBR und PS sind in `common.h` standardmäßig eingeschaltet; `APPLY_DRC`, sonst die üblichen `HAVE_*`-Angaben der CMake-Vorgabe. Änderungen am Quelltext: keine.
