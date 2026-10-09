# WEFAX – Herkunft und Abweichungen

Wetterfax-Empfänger aus fldigi **4.2.13** (`src/wefax/wefax.cxx`, Remi Chateauneu F4ECW, Dave Freese W1HKJ; Kern aus Hamfax, Filter aus ACfax), GPLv3.
Bildlogik aus `wefax-pic.cxx` und `wefax_map.cxx` (Empfangsteil).

## Erzeugung

`src/wefax/wefax_rx.cpp` wird **nicht von Hand bearbeitet**, sondern mit `python3 Vendor/Fldigi/port_wefax.py` erzeugt.
Das Skript übernimmt aus `wefax.cxx` den Block von `PUT_STATUS` bis vor die Sendefunktionen (`init_tx`): Filtertabellen, `fax_implementation`
mit APT-, Phasing-, Korrelations- und AFC-Logik, `decode*`, `save_automatic` und `rx_new_samples`. Gezielte Ersetzungen gibt es je genau einmal, sonst bricht das Skript ab.
Am Ende hängt es `Vendor/Fldigi/wefax_frame.inc` an (Rahmen). Kopf: `src/wefax/wefax_rx.h`, C-API: `include/fldigi_wefax.h`.

## Abweichungen

1. **Globale → Rahmen:** `progdefaults`, `progStatus`, `wf`, `put_Status1/2` sind per Makro an den Decoder gebunden (`m_ptr_wefax->…`), mit fldigis Standardwerten (`WefaxProgdefaults`).
   `REQ(f, …)` ruft direkt auf (kein GUI-Thread). `LOG_*` entfallen.
2. **Bildfenster:** `wefax_pic`/`wefax_map` (FLTK) sind durch `WefaxImage` ersetzt. Pixel setzen, Höhe vergrößern, horizontal verschieben, Auto-Zentrierung (`estimate_rx_image_center`),
   Rauschentfernung und Schräglauf sind aus fldigi übernommen. Scrollen, Zoom und Knöpfe entfallen.
   `save_image` schreibt kein PNG, sondern ruft Swift mit Graustufen und fldigis Kommentaren auf. Swift schreibt das PNG mit den Kommentaren als Beschreibung.
3. **Wasserfall:** `WefaxWaterfall` rechnet wie `WFdisp::processFftBuffer` (8192-Punkt-FFT, Blackman, `vscale = 2/N`, `pwr = norm`), aber bei 11 025 Hz statt nach Umsetzung auf 8000 Hz.
   Das 1-Hz-Pixel *i* liegt im Bin `round(i · 8192 / 11025)`. Die FFT wird nur berechnet, wenn neue Samples da sind und eine Leistung abgefragt wird.
4. **Dateiwarteschlangen** für XML-RPC und Senden (`syncobj`, `send_file`, `transmit_lock_*`) entfallen, ebenso das ADIF-Log (`qso_rec_*`).
5. **static → Objektvariablen (16 Stück):** Korrelationszustand, AFC-Gedächtnis, APT-Frequenzen der letzten Halbsekunden und Phasing-Historie sind per Referenz an Objektvariablen gebunden.
   Der Code bleibt dadurch wortgleich, und ein neuer Decoder startet sauber.
   Die Empfangsfilter (`m_rx_filters`) sind je Objekt statt static. Die AFC-Masken `bw_dual`/`bw_right` sind nicht mehr static, damit ein geänderter Hub gilt.
6. **Zeilenlänge (Fehlerkorrektur):** fldigis `lpm_to_samples()` liefert `int`. Bei 11 025 Hz und 120 LPM ergibt das 5512 statt 5512,5 Samples je Zeile und damit
   **0,166 Pixel Schräglauf je Zeile** (≈ 200 Pixel auf 1200 Zeilen; fldigi gleicht nur bis Zeile 500 per Auto-Zentrierung aus). Digidec rechnet mit `double`.
   Nachweis: synthetisch vorher 39 px Drift auf 235 Zeilen, nachher 1 px.
7. **Probenverlust-Schätzung** über die Uhrzeit in `wefax::rx_process` entfällt. Digidec verliert keine Samples, und bei Dateien wäre die Uhrzeit bedeutungslos.
8. **Knopf Speichern** (`wefax_cb_pic_rx_save`): speichert wie fldigi, ohne den Empfang zu beenden (`save_now`).
9. **Hub `fm_deviation`** bleibt dateiweit wie in fldigi. Deshalb gibt es nur einen WEFAX-Decoder gleichzeitig, und IOC- oder Hubwechsel legt den Decoder neu an.

## Befunde

- **Leistungsmittel ohne Wirkung:** `power_usb_*()` rufen `return decayavg(avg_pwr, pwr, N)` auf. `decayavg` nimmt den Mittelwert per Wert, deshalb bleibt `avg_pwr` immer 0,
  und die Funktionen liefern `pwr/25` (Rauschen) bzw. `pwr/10`. fldigis Schwellen der Zustandserkennung sind gegen genau dieses Verhalten eingestellt. Es ist **unverändert übernommen**.
- **Nach Sendeschluss:** Ein schwarzer Träger gilt als „starkes Phasing-Signal“. Digitale Stille (exakt 0) liest fldigi als Weiß (`CLIP`-Zweig).
- **Phasing:** Das Bild beginnt bei der Mitte des weißen Pulses. Die Filterlaufzeit verschiebt den Inhalt um etwa 6 Pixel nach links.
- **Synthetisch (S/N in 3 kHz):**
  - ohne Rauschen: mittlere Abweichung 3,8 Graustufen
  - +4 dB: Bild sauber
  - −2 dB: Phasing wird nicht mehr erkannt; fldigi startet das Bild nach 20 Testzeilen selbst, mit Phasing-Zeilen oben und Versatz
  - −6 dB: kein Bild
