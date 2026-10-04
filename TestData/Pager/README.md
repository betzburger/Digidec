# Echte DAPNET-Aufnahme mit verbogenem Audio

`dapnet_verbogen_48k.wav` – 22 s, 48 kHz mono, 16 Bit. Ausschnitt (30 … 52 s) einer Digidec-Aufnahme (REC im Funkruf-Modul)
vom 04.10.2026, 06:34 UTC, DAPNET 439,9875 MHz, POCSAG 1200 Baud, PCR-1500 (FM).

Das Signal ist sauber (voller Träger), aber der Audioweg wirkt wie ein Bandpass: steiler Hochpass bei etwa 290 Hz, flach bis etwa 1 kHz,
darüber fallend. Lange gleiche Bitfolgen sinken in Millisekunden auf null, die Pulse überschwingen. Der einfache Bit-Entscheider
(`PagerBitSlicer`) findet darin kein Synchronwort; der Entzerrer (`POCSAGEqualizer`) liest zwei Aussendungen (bei etwa 2 … 6 s und
13 … 20 s der Datei) mit Stapeln, die fast alle Codewörter gültig haben.

Gelesene Meldungen (Rufnummer, Text): 1005 „432314.0 DK2OY“, 4520 (Skyper-Zeichensatz, Zeichen +1: „# 432314.0 DK2OY …“),
1004 „3634.0 ON3RUM“, 2000 „#ZEIT=0635041026…“ (DAPNET-Zeitmeldung), 1061 „Quelle: www.pe…“.

Verwendet im Logiktest „Entzerrer: echte DAPNET-Aufnahme“.
