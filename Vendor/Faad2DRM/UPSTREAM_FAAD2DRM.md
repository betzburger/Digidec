# FAAD2 mit DRM-Unterstützung

- **Quelle:** dieselben Dateien wie `Vendor/Faad2` (Verknüpfung `src` → `../Faad2/src`, unverändert), `include/neaacdec.h` ist eine Kopie.
- **Verwendung:** Modul DRM: Audio-Rahmen von DRM30 (AAC-LC mit SBR und parametrischem Stereo im DRM-Format, `NeAACDecInitDRM`). Der DRM-Modus von FAAD2 erlaubt kein PNS und keine Erweiterungsnutzlast; deshalb ist er ein eigenes Ziel und nicht in `Faad2` für DAB+ eingeschaltet.
- **Übersetzung:** `Package.swift`, Ziel `Faad2DRM` mit `DRM_SUPPORT`; alle 111 globalen Namen werden mit `-D` zu `faaddrm_…` umbenannt (Liste `symbols.txt`, erzeugt aus den Objektdateien), damit das Programm beide Fassungen binden kann. Änderungen am Quelltext: keine.
- **Lizenz:** GNU General Public License, Version 2 oder (nach Wahl) jede spätere (`COPYING`).
