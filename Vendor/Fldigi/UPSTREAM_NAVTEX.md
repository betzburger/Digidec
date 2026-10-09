# NAVTEX – Herkunft und Abweichungen

NAVTEX/SITOR-B-Empfänger aus fldigi **4.2.13** (`src/navtex/navtex.cxx`, F4ECW und AB1KW, nach JNX von Paul Lutus), GPLv3.
SITOR-B: 100 Bd, ±85 Hz, CCIR-476-Code (7 Bit, je 4 Einsen), Zeitdiversität (rep 5 Zeichen vor alpha), Nachrichten „ZCZC B1B2B3B4 … NNNN“.

## Erzeugung

`src/navtex/navtex_rx.cpp` wird **nicht von Hand bearbeitet**, sondern mit `python3 Vendor/Fldigi/port_navtex.py` aus dem Original erzeugt
(`Vendor/_upstream/fldigi-4.2.13/src/navtex/navtex.cxx`). Das Skript ersetzt gezielt Stellen und bricht ab, wenn eine Stelle nicht genau einmal vorkommt.
Am Ende hängt es `Vendor/Fldigi/navtex_frame.inc` an (Rahmen: Wasserfall-Ersatz, Klasse `navtex`, Stationssuche, Testkodierung).
Alle Eingriffe sind mit `ABWEICHUNG fldigi (Digidec)` markiert.

## Abweichungen

1. **Header:** fldigi-, FLTK- und Wasserfall-Header durch Digidec-Ersatz ersetzt. `navtex_filter_mutex` und `guard_lock` entfallen, weil es nur einen Thread je Decoder gibt.
2. **ITA2:** `CCIR476` bekommt den Ziffernsatz als Parameter statt `progdefaults.ITA2`.
3. **ccir_message::display():** ADIF-Logbuch und KML entfallen. Die Kopf-Kennungen (`origin`, `subject`, `number`) sind lesbar gemacht.
4. **Wasserfall:** `wf->powerDensity` und `wf->powerDensityMaximum` stammen aus dem Ersatz `NavtexWaterfall`:
   Goertzel auf den 1-Hz-Pixeln über die letzten 8192 Samples, Blackman-Fenster, sonst Code 1:1 aus `waterfall.cxx`.
   `wf->Reverse()` liefert die fertige Umkehr (mit Seitenband-Korrektur), `wf->USB()` immer true.
5. **Modem-Klasse `navtex`:** ersetzt durch einen Rahmen mit Einstellungen, Rückrufen, Metrik, S/N und Mittenfrequenz. `set_freq` begrenzt wie `modem::set_freq` auf das Band.
6. **Ausgabe:** `put_rx_char` und `put_received_message` laufen als Rückrufe. Die Nachricht wird mit Kopf-Kennungen und fldigis Beschreibung der Art übergeben. Die XML-RPC-Warteschlange entfällt.
   `put_status` merkt sich nur den Zustand, `put_Status2` wird zum S/N-Wert.
7. **static-Variablen** in `process_char`, `compute_metric`, `process_afc` und `process_fft_output` sind Objektvariablen, damit mehrere Decoder möglich sind.
8. **Senden entfällt.** `encode()` und `create_fec()` sind öffentlich für den Testsignal-Generator.
9. **Blockgröße:** Die C-Schnittstelle ruft wie fldigi in 512er-Blöcken auf, bei **11 025 Hz** (fldigi `modem::samplerate`).

## Befunde

- **AFC-Versatz:** fldigis AFC (`process_afc`) mittelt die Frequenzen von Mark und Space, gewichtet nach Leistung. Der CCIR-476-Code hat 4 Mark- und 3 Space-Bits je Zeichen.
  Deshalb wandert die Mitte bei sauberem Signal um +5…8 Hz Richtung Mark (rechnerisch bis +12 Hz). Die Decodiergrenze ist mit und ohne AFC gleich (≈ −8 dB, S/N in 3 kHz).
- Synthetisch gemessen (Smoke-Test 01.10.2026): fehlerfrei bis −5 dB, −8 dB ein Zeichenfehler und Kopf verloren, −10 dB kein Empfang.
- **Stationssuche** wie `NavtexCatalog::FindStation`: Sie braucht den eigenen Locator. Kennung und Frequenz bestimmen die nächstgelegene Station.
  Die fldigi-Liste (`NAVTEX_Stations.csv`) führt Pinneberg als **L** (490 und 518 kHz).
