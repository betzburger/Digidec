# ALE (Automatic Link Establishment, 2G) – Herkunft

Kein Fremdcode im Projekt: `Sources/Decoders/ALE/ALECore.swift` ist eine eigene Swift-Umsetzung von **MIL-STD-188-141A/B Anhang A** nach der MIT-lizenzierten Referenz **openALE** (DL3HC, github.com/dl3hc/openALE, Commit `1f0fb89`, selbst auf PC-ALE 2.0 von Alex Pennington aufbauend). Gelesen und nachgebaut wurden `ale_waveform.h` (Töne und Symbolzuordnung), `word_interleaver.cpp`, `ale_fec_codec.cpp`, `ale_decoder.cpp`/`ale_encoder.cpp` (Dreifach-Wiederholung, Mehrheit), `ale_word.cpp` (Zeichensätze), `address_encoder.h` (DATA/REP-Fortsetzungen) und `ale2g_modem.h` (Erfassungskriterien).

| Quelle | Verwendung |
|---|---|
| openALE (MIT) | Wortaufbau (3 Bit Präambel + 3 × 7 Bit), Golay-(24,12) mit invertierten Prüfbits in Coder B, Verschachtelung A/B (+ Stuffbit), 49 Symbole = 3 × 49 Bit, 8-FSK-Töne 750 … 2500 Hz mit Gray-Zuordnung, Raster 392 ms, Zeichensätze Basic 38 / Expanded 64, Adressbildung |
| Golay-Prüfbits | Die zwölf Basisvektoren (`0x5C7 … 0xAE3`) sind die Erzeugermatrix des erweiterten Golay-Codes (aus der Referenz); die Tests prüfen Mindestgewicht 8 und die Korrektur aller Dreifachfehler. Dass sie der ALE-Code sind, bestätigt die echte Aufnahme (s. u.) |
| sigidwiki „2G ALE“ (`https://www.sigidwiki.com/images/a/ab/2G_ALEaudio.mp3`, 478 kB, 30 s, 44,1 kHz mono) | **Echte Gegenprobe**: 3 Aussendungen, 38 Wörter, Kennung „SHAEENQ2“, Anruf an „USMANQ7“ mit Klartext. Die Datei liegt nur lokal unter `Vendor/_upstream/ale_sigid.mp3` (nicht im Git; Herkunft und Lizenz unklar) |

## Aufbau

- **Demodulator** (`ALEDemodulator`): Die Symbolgrenze ist unbekannt: **16 Taktlagen** (4 Abtastwerte Versatz) laufen parallel, jede entscheidet je 64 Abtastwerte den stärksten der acht Töne (Goertzel, bei diesen Frequenzen orthogonal) und versucht bei jedem neuen Symbol, die letzten 49 als Wort zu lesen: 2-von-3-Mehrheit je Bit (einstimmige Bit werden gezählt, 48 = fehlerfrei), Golay beider Hälften (korrigiert bis 3 Fehler je Hälfte), Zeichenprüfung (Basic 38 für TO/TIS/TWAS/FROM/THRU, Expanded 64 für DATA/REP, CMD ohne Prüfung).
- **Raster** (`ALEGridTracker`): Wichtig, weil der Datenstrom periodisch ist: ein um einige Symbole verschobenes Fenster ergibt oft auch ein „gültiges“ Wort. Das **erste** Wort einer Aussendung muss sauber sein (≥ 44 einstimmige Bit, ≤ 3 Golay-Fehler, Präambel TO/TWAS/TIS/FROM/THRU); **weitere** Wörter müssen im Abstand eines Vielfachen (1 … 3) von 3136 Abtastwerten (± 48) folgen und genügen mit ≥ 36 Stimmen.
- **Sammler** (`ALEWordCollector`): dasselbe Wort aus mehreren Taktlagen → das mit den meisten einstimmigen Bit.
- **Aussendung** (`ALEMessageBuilder`, `ALEMessage`): Wörter im Raster bilden eine Aussendung (Pause > 1 Rasterschritt = Ende). Adressen aus mehreren Wörtern (TO, DATA, REP, DATA …, „@“ füllt), weitere Empfänger per REP, Klartext aus DATA/REP nach CMD; Art: ANRUF, SOUNDING, ABSCHLUSS, KENNUNG, NACHRICHT, BEFEHL.
- **Frequenznachführung** (`ALEFrequencyError`): entscheidungsgestützt: von einem angenommenen Wort sind alle 49 Töne bekannt; die Energien 15 Hz über und unter dem Ton ergeben (über eine Kalibrierkurve) den Fehler in Hz; Verstimmung wird mit Faktor 0,6 nachgeführt.

## Grenzen

- Nur ALE 2G (8-FSK, 125 Bd). 3G-ALE, ALE-4G (MIL-STD-188-141D) und AQC-ALE werden nicht erkannt.
- CMD-Wörter (Funktionscodes, LQA, AMD-Steuerung) werden roh angezeigt; Frequenzen/Nachrichtenköpfe werden nicht zerlegt. Die Rufzeichen-/Adresszuordnung (Netze, Stationsnamen) fehlt.
- Weder Sende- noch Antwortlogik: Digidec hört nur zu. Inhalt und Adressen sind nicht verschlüsselt, der Klartext (AMD) ist aber nicht für die Allgemeinheit bestimmt: siehe Hinweis zum Fernmeldegeheimnis in PLAN.md.
