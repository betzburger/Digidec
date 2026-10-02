# PSK – Herkunft und Abweichungen

Empfänger für **BPSK31/63/125/250**, **QPSK31/63/125/250**, **PSKR 125/250/500/1000** und **8PSK** (125, 125FL, 125F, 250, 250FL, 250F, 500, 500F, 1000, 1000F, 1200F) aus fldigi 4.2.13 (`src/psk/psk.cxx`, `src/include/psk.h`).
Erzeugt von `port_psk.py`: die Funktionen werden wörtlich herausgezogen (Klammerzählung); das Skript bricht ab,
wenn das Original nicht mehr wie erwartet aussieht. Lizenz GPLv3 wie fldigi.

| Datei | Herkunft |
|---|---|
| `src/psk/psk_rx.cpp` | `psk.cxx`: Konstanten und Tabellen, `psk()` (alle Betriebsarten), `~psk`, `init`, `rx_init`, `restart`, `viewer_mode`, `rx_symbol`, `rx_bit`, `rx_bit2`, `rx_qpsk`, `rx_pskr`, `findsignal`, `phaseafc`, `afc`, `vestigial_afc`, `signalquality`, `update_syncscope`, `rx_process`, `initSN_IMD`, `resetSN_IMD`, `calcSN_IMD` |
| `src/psk/psk_rx.h` | `include/psk.h` |
| `src/psk/pskcoeff.*`, `pskvaricode.*` | `psk/pskcoeff.cxx` (Raised-Cosine- und Sinc-Filter, PSKcore-Filter), `psk/pskvaricode.cxx` (PSK-Varicode) – unverändert |
| `src/psk/viterbi.*` | `filters/viterbi.cxx` (K=5-Viterbi-Decoder für QPSK) – nur `misc.h` → `misc_min.h` |
| `src/psk/interleave.*`, `mfskvaricode.*` | `mfsk/interleave.cxx`, `mfsk/mfskvaricode.cxx` – unverändert (vom Konstruktor und `rx_bit` gebraucht) |
| `src/psk/psk_modes.inc` | `trx_mode`-Aufzählung aus `globals.h` (Reihenfolge wie im Original, von `port_psk.py` erzeugt) |
| `src/psk/psk_compat.h` | Ersatz für Modem-Basisklasse, `progdefaults`, `progStatus`, Wasserfall, Statusanzeigen |
| `src/psk/fldigi_psk.cpp`, `include/fldigi_psk.h` | C-Schnittstelle für Swift; Testsignal-Generator |
| `src/common/misc_min.h` | `hweight32`, `parity` aus `misc.cxx` ergänzt |

## Abweichungen (`// ABWEICHUNG fldigi (Digidec)` im Code)

1. **Nur Empfang:** Senden (`tx_*`, `transmit`, `tx_process`), die Mehrkanal-Ansicht (`viewpsk`), die Signalsuche über den Wasserfall (`pskeval`) und PSKmail (Mailserver) entfallen. `viewpsk` und `pskeval` sind leere Ersatzklassen.
2. **Je Instanz statt file-static:** `averageamp`, `counter` und `dcdOFFcounter` in `rx_symbol` sind Elemente der Klasse (`averageamp_`, `counter_`, `dcdOFFcounter_`). Übrige file-static-Variablen (`waitcount`, `reset_filters`, `e0…e3`, 8PSK-Zustand) bleiben: **nur ein PSK-Decoder gleichzeitig**; `psk_rx_reset_statics()` setzt sie beim Anlegen zurück.
3. **Umgebung:** Standardwerte aus fldigi (Squelch an, Pegel 5, AFC an). `StartAtSweetSpot` aus: Digidec setzt die Trägerfrequenz selbst (`init()` übernimmt sie aus dem Wasserfall-Träger).
4. **Ausgabe:** `put_rx_char` ruft einen Rückruf (Byte). Digidec setzt daraus Text (CR fällt weg, LF bleibt, 8-Bit-Zeichen als Latin-1).
5. **Im Konstruktor bleiben alle Betriebsarten** (auch Mehrträger-PSKR, 16PSK, OFDM) erhalten, damit der Code wörtlich bleibt; die C-Schnittstelle bietet BPSK, QPSK, PSKR 125 … 1000 (ein Träger) und 8PSK an. Mehrträger-PSKR (z. B. 4X_PSK63R), 16PSK und OFDM sind nicht angebunden und nicht geprüft.
6. **Sendefunktionen für das Testsignal:** `tx_init`, `tx_carriers`, `tx_symbol`, `tx_bit`, `tx_xpsk`, `tx_char`, `tx_flush`, `clearbits` sind wörtlich übernommen (ohne IMD-Testfenster; die function-static Zähler von `tx_bit` und `tx_xpsk` sind je Instanz); der Vorspann entspricht dem von `tx_process`. BPSK und QPSK nutzen weiterhin den eigenen Generator in `fldigi_psk.cpp`, PSKR und 8PSK die übernommene Sendeseite.
7. **Abtastrate:** 8PSK arbeitet mit 16000 Hz (wie fldigi), alle anderen mit 8000 Hz; Digidec hängt dafür zwei Senken an die Pipeline.

## Prüfen

- Logiktests: alle acht BPSK-/QPSK-Betriebsarten (Text, Mitte), PSKR und 8PSK im Rundlauf mit der übernommenen Sendeseite (alle 15 Arten), Pipeline 48 kHz → 16 kHz, AFC (± 6 Hz Versatz), Rauschen (BPSK31 bis −4 dB, BPSK63 3 dB, BPSK125 8 dB, QPSK31 5 dB, QPSK63 8 dB), Squelch, Status (DCD, S/N), Pipeline 48 kHz → 8 kHz.
- Das Testsignal (`fldigi_psk_synthesize`) folgt der Sendeseite von fldigi (Vorspann aus Phasenumkehr, Varicode, Hüllkurve `tx_shape`, `sym_vec_pos`). **Nicht** mit dem Original-fldigi gegengeprüft und **nicht** an echtem Funkverkehr.
- `Tools/DecodeFile/decode_file.sh <aufnahme.wav> --psk bpsk31 --center 1000` decodiert Aufnahmen offline.
