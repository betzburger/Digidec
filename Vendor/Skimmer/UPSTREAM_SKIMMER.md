# Skimmer (CW, BPSK31, BPSK63): Herkunft und Aufbau

**Kein Fremdcode im Projekt.** Eigene Swift-Umsetzung mit bekannten Verfahren: FFT-Spitzensuche, Mischen und Dezimieren, Hüllkurve mit Hysterese,
Takt aus dem Betragsquadrat (Oerder-Meyr), differentielle BPSK-Entscheidung. Der Skimmer liest **alle Signale einer Betriebsart im Audio zugleich**
(ein Spektrum für alle, ein kleiner Decoder je Träger), wie CW Skimmer (Afreet Software) und das Reverse Beacon Network es für CW tun.
Als Vergleich für den Aufbau wurde der Entwurf des **KZ4AP Skimmer** (PhysicsCowboy, GPL-3.0, `Vendor/_upstream/kz4ap-skimmer`, lokal, nicht im Git)
gelesen; von dort ist weder Code noch Parametrierung übernommen. Das PSK31-Varicode ist die allgemein bekannte Tabelle von G3PLX; die 256 Einträge
in `SkimmerTables.swift` sind Zeichen für Zeichen mit `varicodetab1` aus fldigi 4.2.13 (`src/psk/pskvaricode.cxx`) verglichen (gleich).
Das Morsealphabet enthält Buchstaben, Ziffern, Satz- und Sonderzeichen (Ä Ö Ü, `<SK>`, `<AR>` als `+` usw.).

Die Module **CW** und **PSK** (fldigi-Empfänger, `Vendor/Fldigi`) bleiben unverändert und lesen ein einzelnes Signal genauer (mit AFC, Matched Filter,
Squelch, Einstellungen). Der Skimmer ist die Übersicht über das ganze Band; „IN CW ÖFFNEN“ bzw. „IN PSK ÖFFNEN“ führt ein Signal dorthin.

## Aufbau (`Sources/Decoders/Skimmer`)

| Datei | Inhalt |
|---|---|
| `SkimmerTables.swift` | Morsetabelle, PSK31-Varicode (Bits je Zeichen, Umkehrtabelle) |
| `SkimmerSpectrum.swift` | `SkimMode` (cw, psk31, psk63 mit Kenngrößen), `SkimSpectrum` (1024-Punkte-FFT, Hann, Schritt 32 ms, 7,8125 Hz je Bin, 1 s gemittelt, vDSP), `SkimDetector` (Rauschen, Spitzen, Spuren) |
| `SkimmerChannels.swift` | `SkimDownconverter` (Mischer, Butterworth 4. Ordnung, Dezimierung 16 auf 500 Abtastwerte/s), `SkimCWChannel`, `SkimPSKChannel` |
| `SkimmerEngine.swift` | `SkimmerEngine` (Spuren → Kanäle, Aufnahme in die Liste, Rauschabstand, Aufräumen), `SkimChannelInfo` |
| `SkimmerSignals.swift` | Testsignale (CW mit Wortabstand, Jitter, Gewichtung; BPSK mit Varicode und Raised-Cosine; Rauschen, Schwund) – nur für Prüfungen |
| `SkimmerModule.swift` | `SkimBand`, `SkimStation`, `SkimSpot`, `SkimmerSettingsStore` (auch `TuningTarget` für den Wasserfall), `SkimmerDecoder` (8-kHz-Senke), `SkimmerController` (Liste, Rufzeichen, Spots, Log) |
| `Sources/UI/SkimmerPanels.swift` | Signalliste, Spots, Abstimmanzeige, Einstellungen |

## Verfahren

**Suche.** Das gemittelte Leistungsspektrum (dB) wird bei PSK über ±2 (31) bzw. ±4 Bins (63) geglättet (ein Hügel je Signal). *Rauschen* je Bin = unteres
Fünftel (20-%-Quantil) in ±64 Bins (±500 Hz), +0,5 dB: In einem dichten Band liegt der Median zu hoch; das Quantil bleibt bei den Lücken zwischen den
Signalen. Spitze = Höchstwert in ±3 (CW), ±5 (31) bzw. ±8 Bins (63), mindestens **Schwelle** (Standard 8 dB, einstellbar 4…16) über dem Rauschen; vier
Auswertungen in Folge (0,5 s) machen aus ihr eine **Spur**; Spuren folgen der Frequenz und sterben nach 12 s (CW) bzw. 20 s (PSK) ohne Spitze.

**Kanal.** Je Spur ein Mischer auf die Spurfrequenz und ein Tiefpass; das Basisband (500 Abtastwerte/s, Grenzfrequenz CW 60 … 130 Hz je nach Tempo, BPSK31 48 Hz, BPSK63 85 Hz)
läuft in einen Decoder:
- **CW:** Hüllkurve (Glättung ¼ Punkt) → Zeichen- und Zwischenraumpegel (schnell hinauf, langsam hinab) → Hysterese (55 % / 40 % der Spanne, Öffnung mindestens 2,2:1)
  → Elemente. Punktlänge aus den letzten 24 Marken (getrennt am größten Längensprung, Verhältnis 3:1 herausgerechnet, 5 … 60 WpM), Zeichenende nach 2, Wortende nach 5 Punktlängen
  Pause → Morsetabelle; unbekannte Muster als „*“.
- **BPSK:** Takt aus der Taktkomponente des Betragsquadrats (Oerder-Meyr, Gedächtnis 8 Symbole, Korrektur höchstens ein Abtastwert je Symbol),
  Symbolwert aus einer Zelle mit sin²-Fenster, differentielle Entscheidung (Phasenumkehr = 0), Varicode (zwei Nullen = Zeichenende), Frequenznachführung aus dem Phasenfehler (±25 Hz).
  Ausgabeschalter (Träger erkannt) aus der schnellen Güte der Entscheidungen mit Hysterese (öffnet über 0,86 nach 24 Symbolen, schließt unter 0,72); ein unmodulierter Träger
  (kaum Nullen) liefert nichts.

**Aufnahme in die Liste.** Eine Spur ist zunächst nur Kandidat. In die Liste kommt sie erst, wenn der Kanal Text liest: CW mindestens 10 Marken, ≥ 70 % bekannte Muster,
8 … 45 WpM, 6 Zeichen, Rauschabstand ≥ 4 dB und Text, der nicht nach Rauschen aussieht (`looksLikeText`: nicht überwiegend E, T, I, S, H, wenige „*“, mindestens 4 verschiedene Zeichen);
BPSK Träger erkannt, 8 lesbare Zeichen, ≥ 60 % lesbar, ≥ 3 dB. Dauerträger, Brummen und Rauschen werden nach 15 s (CW) bzw. 14 s (PSK) verworfen und für 90 s an dieser Frequenz nicht neu angelegt.
Vor der Aufnahme gelesener Text wird nachgeliefert (die ersten Zeichen gehen nicht verloren). Ein Kanal, der nur noch Unsinn liest, fällt nach 20 s (CW) bzw. 30 s (PSK) aus der Liste.

**Rauschabstand.** In 500 Hz Bandbreite, wie bei CW Skimmer und im Reverse Beacon Network: Pegel des Kanals (halbe Trägeramplitude A/2) gegen das Rauschen des Spektrums am Ort:
`SNR = 20·lg(Pegel) − 10·lg 64 − P_Rauschen[dB je Bin]`. Gemessen wird bei CW nur bei gedrückter Taste, bei PSK nur bei erkanntem Träger; in Pausen bleibt der letzte Wert stehen.
In einem sehr dichten Band liegt das ermittelte Rauschen höher (Seitenbänder der Nachbarn); der Wert ist dort um einige dB zu klein.

**Rufzeichen und Spots.** `CallsignLog` (wie in CW, PSK, Olivia, MT63 und RTTY): ein Rufzeichen mit gültigem Muster und DXCC-Gebiet gilt nach „CQ“, „DE“, „DX“, „QRZ“, „TNX“, „TU“ davor oder wenn
es zweimal kam. Je verlässlichem Rufzeichen, das mit einem Textstück wieder kam, entsteht ein **Spot** (Art „CQ“ oder „DE“), je Station und Frequenz (±300 Hz) höchstens alle 10 Minuten.
Zeile im Log (`~/Documents/Digidec/Logs/SKIMMER-<UTC-Datum>.txt`) wie im Reverse Beacon Network: `14020.7  DL1ABC  CW  18 WPM  24 dB  CQ  15:24:31Z`; ohne bekannte HF-Frequenz steht `NF 700 Hz`.
HF-Frequenz = Dial + NF (USB; bei LSB Dial − NF); der Dial kommt vom Funkgerät (rigctld) oder vom gewählten Band.

## Prüfstand `Tools/SkimBench`

`Tools/SkimBench/skim_bench.sh synth <cw|psk31|psk63> [--seconds n] [--snr dB-Versatz] [--thr dB] [--seed n] [--sig Hz:WpM:dB …] [--dump datei.wav] [--verbose]`
mischt Signale mit bekanntem Text und Rauschen (Rauschabstand in 500 Hz) und wertet je Signal Fund, Frequenz, Rauschabstand, Tempo und Zeichenfehlerrate (Bearbeitungsabstand zum besten
Stück des Empfangstexts) aus. `… file <aufnahme.wav> <modus> [--from s] [--to s]` liest eine Aufnahme und listet die Kanäle mit Text. `--dump` schreibt die Mischung als 8-kHz-WAV
(auf Spitze 0,9 skaliert; übersteuerte Dateien erzeugen Scheinsignale), z. B. für `DIGIDEC_PLAY_FILE`.

## Nachweis

- **Synthetisch** (40 s, Rauschen mit festem Startwert): **CW** 9 Signale von 8 bis 30 dB und 12 bis 30 WpM gleichzeitig: alle 9 gefunden, keine zusätzlichen Kanäle, Tempo auf ±0,5 WpM, Rufzeichen
  gelesen (Zeichenfehlerrate 3 … 12 %; Anfang und Ende des Ausschnitts fehlen, das langsamste Signal kommt in 40 s nur einmal dran: 46 %), Rauschabstand 1 … 3 dB unter dem gesetzten Wert (bis 5 dB bei den schwachen im dichten Band).
  **BPSK31** und **BPSK63** 6 Signale von 12 bis 25 dB: alle gefunden, Frequenz auf ±1 Hz, Zeichenfehlerrate 0 %.
  Nur Rauschen (60 s), ungetasteter Träger (40 s), jede Betriebsart: **kein** Signal in der Liste.
  Rechenaufwand: 40 s Audio mit 9 Kanälen in 0,1 s (etwa 0,3 % eines Kerns).
- **Echte Aufnahme PSK31** (14,071 MHz, Twente, 58 s; freesound.org Nr. 242994, nur lokal): 3 bis 4 der etwa 8 Träger werden gelesen („599“, „MARCUS FROM MUNICH“, „de OH8MXJ“, „de EK2AN pse k“), mit
  Fehlern wie bei fldigi; die schwachen Träger bleiben Kandidaten.
- **Echte Aufnahme CW** (40 m, viele Stationen, 140 s; freesound.org Nr. 204968, nur lokal): schwach, flatternd, dichtes Band. fldigi liest auf denselben Tönen ebenfalls nur Bruchstücke;
  der Skimmer liefert einzelne Rufzeichenteile („N5NA“) und etliche Scheinkanäle mit Zeichenmüll. **CW funktioniert für saubere Signale ab etwa 8 dB, nicht für flatternde oder verrauschte Signale.**
- Logiktests (`Tools/LogicTests`): Tabellen, URL, Abstimmziel, Einstellungen, Engine mit 4 CW-, 2 × 5 PSK-Signalen, Rauschen, Träger, Kanalende, Controller (Liste, Rufzeichen, Spots, Filter, Karte, Haltezeit, Zeile), Pipeline 48 kHz → 8 kHz.
- Oberfläche an der App (`DIGIDEC_MODULE=skimmer DIGIDEC_PLAY_FILE=… DIGIDEC_SNAPSHOT=…`): die neun CW- und sechs PSK-Signale der Prüfstand-Mischungen in der Liste, im Wasserfall und auf der Karte.

## Grenzen

- Nur CW, BPSK31 und BPSK63 (kein QPSK, kein PSK125, kein RTTY). Das Audio des Funkgeräts ist höchstens 2,4 … 3 kHz breit: je Band ein Ausschnitt von 0,3 … 2,7 kHz über dem Dial.
- Es läuft immer nur eine Betriebsart zugleich (Schalter CW / BPSK31 / BPSK63); die Engine sucht nur Signale dieser Art.
- Die Karte zeigt den Mittelpunkt des DXCC-Gebiets (kein Locator im Text); Spots gehen nirgends hin (kein Reverse Beacon Network, kein Cluster).
- Live-Empfang mit dem Funkgerät offen.
