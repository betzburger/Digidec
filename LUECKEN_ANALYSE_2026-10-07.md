# Digidec: Was fehlt noch? Prüfung aller Module und der App

Stand: 07.10.2026, Version 0.75.1 Alpha. Frage: „Fehlt dem Decoder noch etwas?“, beantwortet für jedes der 38 Module und für die App als Ganzes.

## Wie diese Liste entstanden ist (bitte vorab lesen)

- **Quelle der Modul-Einträge:** die Abschnitte „Grenzen/Offen“, „Nicht dabei“, „Nicht unterstützt“, „Nicht geprüft“ in `PLAN.md`, die Modulliste in `README.md` und ein Blick in die Quelldateien (`Sources/Decoders`). Ich habe **nicht jedes Modul gestartet**.
- **Selbst gemessen habe ich nur SENSOREN** (HackRF, 433,92 MHz, heute). Alles andere beruht auf den Angaben im Plan. Der Plan kann an einzelnen Stellen veraltet sein. Solche Stellen sind mit **(prüfen)** markiert.
- **Mit „Fachwissen“ gekennzeichnete Punkte** sind meine Vorschläge, was es im Funkbetrieb sonst noch gibt. Sie stehen nicht im Plan und sind keine Mängel, sondern Erweiterungsideen.
- **Gewicht** ist meine Einschätzung für Ihren Gebrauch (HackRF, RTL-SDR, RSPduo, IC-PCR1500, FT-991A, Standort Würzburg): **hoch** = sollte bald geschehen, **mittel** = lohnt sich, **gering** = nur wenn Sie es wollen.
- **Live-Empfang bestätigt** ist nach meinem Wissensstand: AIS (06.10.), ADS-B (HackRF und RSPduo, laut Ihnen „spitzenmäßig“), SENSOREN (heute, HackRF). Für alle anderen Module steht im Plan „Live-Empfang offen“ oder gar nichts.

---

## 1. Das Wichtigste in Kürze

| Rang | Thema | Betrifft | Gewicht |
|---|---|---|---|
| 1 | **Kein eigener SDR-Empfänger für Audio-Module.** AIS, APRS, PACKET, PAGER, TÖNE, SONDE, ACARS, DMR, D-STAR, YSF, DPMR, M17, VOR/ILS brauchen ein SDR-Programm (z. B. GQRX) plus VALHost. GQRX hält den HackRF, Digidec kommt nicht heran. Nur ADS-B, VDL2, TETRA und SENSOREN lesen I/Q selbst. | App | hoch |
| 2 | **Unbekanntes bleibt unsichtbar.** Kein Modul zeigt „da war ein Signal, aber ich kenne es nicht“ (SENSOREN: nur Zähler und Hinweis ab 20 Paketen). Das ist der Grund, warum die zu schwache Verstärkung heute so schwer zu sehen war. | SENSOREN, I/Q-Module, App | hoch |
| 3 | **Viele Module nie am echten Signal gesehen.** Rund 25 Module sind nur mit Aufnahmen und Testsignalen geprüft (Liste in Abschnitt 4). | App | hoch |
| 4 | **Radiosonden nur RS41.** M10, M20, DFM, iMet fehlen; ohne Suchlauf im I/Q-Strom. | SONDE | mittel |
| 5 | **Keine Weitergabe der Daten nach außen** (NMEA/UDP, SBS/Beast, MQTT, SondeHub-Upload). | App | mittel |
| 6 | **Verschlüsselung, Daten und Sonderfälle** bei DMR, YSF, TETRA, M17: nur Sprache und Kennungen. | Digitalsprache | gering bis mittel |
| 7 | **Modi, die der Plan nennt und die fehlen:** JT65/JT9, Q65, MSK144, FST4, JS8, DRM, NOAA APT/Meteor, RDS, DAB, NXDN, P25, FX.25/IL2P, 9600 Bd. | neue Module | gering |

Empfohlene Reihenfolge: 2 → 1 → 3 (Prüfung am Gerät, mit Ihnen) → 4 → 5.

---

## 2. Module HF (21)

| Modul | Was fehlt oder ist offen | Art | Gewicht |
|---|---|---|---|
| **ALE** | Nur ALE 2G; kein 3G, 4G, AQC. CMD-Wörter roh, keine Netz-/Stationsnamen. Live-Empfang offen (3,596 / 7,102 / 10,145 / 14,109 MHz USB). Keine Karte (laut Plan). | Funktion, Prüfung | gering |
| **CW** | Sehr tiefer, schneller Schwund (Tiefe ≥ 0,9, Periode ≤ 2 s) bleibt unlesbar; dichte Bänder nur in Bruchstücken (wie fldigi). | Grenze des Verfahrens | gering |
| **DCF77** | Keine Frequenznachführung (die Mitte muss auf etwa ±10 Hz stimmen). Live offen. | Funktion | gering |
| **DSC** | Notruf-Quittungen werden nicht in ihre Nutzdaten zerlegt; keine Küstenfunkstellen-Namen und Länder (MID). Kanal 70 (UKW) nur mit Testsignal geprüft. Live offen (z. B. 8414,5 kHz). Kein Weg auf die Karte (laut Plan beim ACARS-Eintrag: „DSC-Schiffe und ALE haben noch keinen Weg“) **(prüfen)**. | Funktion, Prüfung | mittel |
| **EFR** | Nutzdaten nur als Hex; Versacom/Semagyr herstellerspezifisch, nicht entschlüsselt (bewusst: frühere Deutung war geraten und wurde entfernt). | Grenze (Herstellerformat) | gering |
| **FREEDV** | FreeDV 2020 fehlt (braucht LPCNet); 2400A/B und 800XA (UKW), Datenbetriebsarten fehlen; kein Senden. Nur mit einer Codec2-Beispielaufnahme geprüft, Live offen. | Funktion, Prüfung | gering |
| **FT4** | Live-Empfang durch den Nutzer offen; Rechneruhr und Zeitkorrektur einstellen. | Prüfung | mittel |
| **FT8** | Wie FT4: Live offen. Nicht dabei laut Plan §9: JT65, JT9, Q65, MSK144, FST4, JS8 (alle „schwer“). Kein Senden (bewusst). | Prüfung, Erweiterung | mittel (Live), gering (neue Modi) |
| **HELL** | Keine Zeilensynchronisation des Bildes (wie fldigi); nur gegen das eigene fldigi-Testsignal geprüft, nicht gegen echte Aussendungen. | Prüfung | gering |
| **HFDL** | Live offen (8942 oder 11384 kHz USB). Nur ein Kanal zugleich, kein Suchlauf über die Kanäle. ADS-C, CPDLC, MIAM, OHMA erscheinen nur als ACARS-Text. Systemtabelle fest (Version 52). Keine Flugzeugdatenbank (Kennzeichen nur aus ACARS). Einen HFDL-Betrieb mit I/Q und mehreren Kanälen (wie VDL2) gibt es nicht. | Funktion, Prüfung | mittel |
| **MFSK** (inkl. DominoEX, Thor, Throb, IFKP, FSQ) | Nur gegen das eigene fldigi-Testsignal geprüft, nicht gegen echte Aussendungen oder das Original-fldigi (Sende- und Empfangsseite stammen beide aus fldigi). Kein Bildempfang; keine Sekundärtext-Ausgabe; FSQ-Rufzeichen und CRC nicht ausgewertet. | Prüfung, Funktion | mittel |
| **MT63** | Live offen. Am Anfang einige Zufallszeichen, bis der Synchronisierer einrastet; braucht einige Sekunden bis zum Text. Die MT63-Prüfung „1000S bei 6 dB“ im Logiktest ist zufallsbehaftet. | Prüfung | gering |
| **NAVTEX** | Nur theoretisch und synthetisch geprüft (Plan: „Nutzer unterwegs“). Laut Plan keine WAV-Aufnahme im Modul **(prüfen, README nennt REC)**. Nicht live mit Funkgerät geprüft. | Prüfung | mittel |
| **NDB** | Neu (0.75.0), kein echtes Funkfeuer am Gerät geprüft. Liste auf ganze kHz gerundet, Toleranz ±1,1 kHz (halbe kHz kommen vor). Funkfeuer mit Dauerton zwischen den Kennungen; Doppelkennungen mit sehr kurzer Pause werden zusammengefasst. | Prüfung | mittel |
| **OLIVIA** (inkl. Contestia) | Live offen (14,0730 / 7,0400 MHz). Vergleich mit fldigi auf derselben Aufnahme steht aus. | Prüfung | gering |
| **PSK** | Mehrträger-PSKR (z. B. 4X_PSK63R), 16PSK und OFDM nicht angebunden. 8PSK-Bandbreiten bis über 1 kHz (Marker zeigt nur Symbolrate). Keine WAV-Aufnahme (REC) im Modul. Live offen. | Funktion, Prüfung | gering |
| **RTTY** | Funktionsumfang wie fldigi RX. Live am Funkgerät offen (laut Plan). Keine ARQ-Betriebsarten (SITOR-A, ARQ-E, ARQ-M2, Autospec; Fachwissen, im Plan nicht genannt, fldigi kennt sie auch nicht). | Prüfung, Erweiterung | gering |
| **SKIMMER** | Nur CW, BPSK31, BPSK63; immer nur eine Betriebsart zugleich; Spots gehen nirgends hin (kein RBN, kein Cluster). Live offen. | Funktion, Prüfung | gering |
| **SSTV** | Robot und PD ohne echte Gegenprobe. Nur eine echte Aufnahme (Scottie 1) gesehen. Live offen (14,230 MHz, ISS 145,800 MHz). | Prüfung | mittel |
| **WEFAX** | Plan unterscheidet nicht nach Jahreszeit (Sendungen können ausfallen). Die Ursache der Phasing-Fehler im Empfang ist nicht behoben, der Editor korrigiert nur im Nachhinein; Schräglauf lässt sich im Editor nicht korrigieren. | Funktion | mittel |
| **WSPR** | Keine OSD-Stufe. Typ-3-Meldungen zeigen `<...>`, bis das Rufzeichen einmal als Typ 1 oder 2 gehört wurde. Nur WSPR-2 (kein WSPR-15). Live offen (14,0956 / 7,0386 MHz). Meldung an wsprnet.org fehlt (Digidec sendet nie, bewusst). | Funktion, Prüfung | gering |

---

## 3. Module VHF/UHF (17)

| Modul | Was fehlt oder ist offen | Art | Gewicht |
|---|---|---|---|
| **ACARS** | Positionen nur aus Formaten mit eindeutiger Position; Labels 20 und 80 teils abweichend gelesen; keine Flugplan-, Wetter-, Ereignismeldungen; keine Zusammenführung mehrteiliger Meldungen (ETB); Positionen aus dem Text (z. B. Label H1) nicht ausgewertet. Live offen (131,725 / 131,825 MHz AM). Läuft über Audio, nicht über I/Q (anders als VDL2). | Funktion, Prüfung | mittel |
| **ADS-B** | Gillham-Höhen (ältere Transponder) und Meter-Angaben bleiben ohne Höhe; Typ 29/31 und Comm-B außer BDS 2,0 nicht ausgewertet; keine Verknüpfung mit ACARS/HFDL (Kennzeichen ↔ ICAO-Adresse fehlt); keine Offline-Flugzeugliste. RSPduo nur im Einzeltuner-Betrieb (kein Dual-Tuner, kein Master/Slave). Kein Ausgang (SBS/Beast) für andere Programme. Ihr Live-Test ist bestätigt, der Planeintrag „nicht an Hardware geprüft“ ist überholt **(prüfen)**. | Funktion | mittel |
| **AIS** | Binäre Nachrichten und Doppelkanal sind nachgeholt (0.55.0); Telegramme der Sondernetze (DAC 316/366), Routen (1/27, 1/28), Umweltdaten (1/26), Liegeplatz, Gezeitenfenster, Gefahrgut und Schleusen-Ankunftszeiten werden nur gezählt. Kein NMEA-Ausgang per UDP/TCP. A+B (Stereo) braucht ein SDR-Programm mit zwei Empfängern. Unter etwa 10 dB C/N sinkt die Ausbeute. Hängt vom SDR-Programm ab (siehe Abschnitt 1, Rang 1). | Funktion, Aufbau | mittel |
| **APRS** | Nur 1200 Bd (kein 9600, kein FX.25/IL2P); keine Digipeater-Pfad-Karte; Mic-E-Gerätekennungen nur Kenwood und Yaesu; DSC-Gebiete nicht gezeichnet; Karte braucht Netz (Apple-Kacheln). Live offen (144,800 MHz). Kein APRS-IS (Weitergabe, bewusst nicht). | Funktion, Prüfung | mittel |
| **D-STAR** | Sprache nur über den AMBE-3000R-Stick (nur lokal, nie auf GitHub). Karte der DPRS-Positionen ist da (0.72.0); Live-Prüfung mit dem Funkgerät offen. | Prüfung | gering |
| **DMR** | Nicht unterstützt: Datenübertragung (SMS, GPS, Pakete), verschlüsselte Gespräche (nur Kennzeichen). Eingebettetes GPS (FLCO 8) nicht ausgewertet. Talker Alias in einer echten Aufnahme nicht geprüft. | Funktion, Prüfung | mittel |
| **DPMR** | Nicht geprüft: Empfang am Funkgerät, Betriebsart 2 und 3 (Daten, Zahlungsverkehr), Kopfrahmen (FS1) und Langsamdaten. Die Sprache der Aufnahme ist stellenweise verrauscht. | Prüfung | gering |
| **M17** | Echte Aufnahme steht aus (keine frei verfügbare gefunden), Funkgerät-Prüfung ebenfalls. Nicht unterstützt: Paketdaten (SMS, APRS), BERT, Prüfung der Signatur, Entschlüsselung. | Prüfung, Funktion | gering |
| **PACKET** | Nur 1200 Bd. Zusammensetzen der Verbindungen unter Funkbedingungen (Wiederholungen, Rauschen) und Winlink-Gateways im Betrieb ungeprüft. Live offen (144,8125 MHz). | Prüfung | mittel |
| **PAGER** | FLEX-Phasen B/D und 3200 Baud nicht an einer echten Aufnahme geprüft; keine Meldungsfolgen (Fragmente einzeln); keine Skyper-Umlaute (Zeichen oberhalb von `z`) und keine Rubriknamen; echte DAPNET-Aufnahmen fehlen. FLEX hat keinen Entzerrer; Aussendungen über 20 s werden abgeschnitten. Live offen (DAPNET 439,9875 MHz). | Funktion, Prüfung | mittel |
| **SENSOREN** | **Heute gefunden und behoben:** zu niedrige HackRF-Verstärkung (PR #29). **Offen:** (1) Keine Ansicht für unbekannte Pakete; (2) nicht dabei: Funkfernbedienungen und Alarmgeber, Stromzähler (Owl, ERT), Reifendrucksensoren, 315/915 MHz, Rohsignal-Analyse; (3) nur 36 Geräte, rtl_433 kennt über 200; nicht übernommen wurden Eurochron-TH, Rosenborg 66796, Klimalogg; (4) Verlauf der Sensoren nur im Speicher (240 Punkte), nicht über Neustarts; (5) kein Ausgang nach außen (MQTT o. Ä.). **Geprüft:** HackRF, 433,92 MHz, Nexus-TH und LaCrosse-TX141THBv2 in der App sichtbar. 868,3 MHz, RTL-SDR, RSPduo nicht am Gerät geprüft. | Funktion, Prüfung | hoch (1), mittel (3, 5) |
| **SONDE** | Nur Vaisala RS41; M10, M20, DFM, iMet u. a. fehlen. Kein Suchlauf über das Band ohne Frequenzeintrag; kein Spektrum, deshalb keine Vorauswahl nach Signalstärke. Suchlauf braucht QSY AUTO und rigctld, am PCR-1500 nicht ausprobiert (Zeiten sind Annahmen). Kein Eintrag in der Sonden-Karte; mehrere Stationen im selben Fenster: es läuft immer die zuerst begonnene. Der FT-991A empfängt 400 bis 406 MHz nicht. Startort ist eine Vermutung. Live offen. Läuft über Audio, nicht über I/Q. | Funktion, Prüfung | mittel bis hoch |
| **TETRA** | Nur unverschlüsselt (Klasse 2 und 3 nur erkannt); Paketdaten, Duplex-Einzelruf, Standortmeldungen (LIP) und Aufwärtsstrecke nicht ausgewertet; Zeitschlitz-Zuordnung aus der Kanalzuweisung nur Anzeige. Nicht am Gerät mit echtem Netz geprüft. | Prüfung, Funktion | mittel |
| **TÖNE** | ZVEI/CCIR/EEA überlappen in den Frequenzen: bei mehreren eingeschalteten Normen gewinnt die längere Folge. Kein Abgleich mit Alarmlisten (z. B. Feuerwehr-Schleifen). | Grenze, Funktion | gering |
| **VDL2** | Empfang am Funkgerät nicht geprüft (136 MHz-Antenne nötig). XID-Inhalte, X.25/ATN-Pakete, CPDLC und ADS-C nur als Text oder Länge. Kein Abgleich mit ADS-B. | Prüfung, Funktion | mittel |
| **VOR/ILS** | ILS an echter Aufnahme nicht geprüft; Doppler-VOR (DVOR) vertauscht Bezug und variablen Ton, hier nicht berücksichtigt; liest nur Audio vom SDR-Programm (keine I/Q-Eingabe). Empfang am eigenen SDR offen. | Prüfung, Funktion | gering |
| **YSF** | Nicht unterstützt: Sprache in den Modi V/D 1 und Vollrate (nur Rufzeichen), Datenübertragung. GPS in YSF nicht ausgewertet. | Funktion | gering |

---

## 4. Die App als Ganzes

### 4.1 Aufbau und Bedienung

| Thema | Befund | Gewicht |
|---|---|---|
| **Eigener Empfänger fehlt** | Nur 4 von 17 VHF/UHF-Modulen lesen I/Q selbst. Die übrigen brauchen ein SDR-Programm und VALHost. Wer HackRF/RTL-SDR/RSPduo nutzt, muss GQRX oder SDRconnect parallel laufen lassen. Ein eingebauter schmalbandiger FM-/AM-/USB-Empfänger aus der I/Q-Quelle (mit Kanalwahl) würde AIS, APRS, PACKET, PAGER, TÖNE, SONDE, ACARS und die Digitalsprache ohne zweite Software bedienbar machen. Die Quellen (HackRF, RTL-SDR, SDRplay-API, SDRconnect, Datei) sind schon da. | hoch |
| **Eine Quelle zugleich** | Das Gerät gehört dem Modul, solange es offen ist; beim Wechsel wird es freigegeben. Kein Parallelbetrieb zweier Module auf einem Gerät (z. B. ADS-B und SENSOREN) und kein Mehrkanalempfang über die vorhandenen Fälle hinaus (VDL2 mit mehreren Kanälen ist die Ausnahme). | mittel |
| **Diagnose** | Keine allgemeine Anzeige „Signal da, aber nicht decodierbar“. Einzelne Module haben Hinweise (PACKET: „KEIN AUDIO/WARTEN“, SENSOREN: seit heute „zu schwach ausgesteuert“, „übersteuert“). Kein Spektrum und keine Rohbits für I/Q-Module. | hoch |
| **Verstärkungseinstellung** | Je Modul eigene Gain-Werte (HackRF LNA/VGA/AMP, RTL-SDR, RSPduo). Die Voreinstellungen stammen aus ADS-B (1090 MHz) und waren für andere Bänder zu niedrig; jetzt nur für SENSOREN geändert. Für VDL2 und TETRA habe ich die Werte nicht geprüft. | mittel |

### 4.2 Ein- und Ausgabe

| Thema | Befund | Gewicht |
|---|---|---|
| **Weitergabe nach außen** | Nichts gefunden (keine UDP-/TCP-Ausgabe). Mögliche Ausgänge: NMEA (AIS), SBS/Beast (ADS-B), MQTT/Home Assistant (SENSOREN), SondeHub-Upload, RBN/Cluster (SKIMMER). Ob das gewollt ist, sagt der Plan nicht; die App liest nur und sendet nie. | mittel |
| **Benachrichtigungen** | Keine Systemmeldung oder Alarmton gefunden (z. B. DSC-Notruf, Squawk 7700 in ADS-B, neuer Sensor, Sonde im Anflug). | gering |
| **Verlauf über Neustarts** | Stationslisten und Verläufe liegen im Speicher; dauerhaft sind nur die Tagesprotokolle unter `~/Documents/Digidec/Logs` und Aufnahmen. Keine Datenbank, keine Auswertung über Tage (z. B. Temperaturverlauf eines Sensors). | gering bis mittel |
| **Funkgerätsteuerung** | Frequenz und Mode nur über rigctld, GQRX-Remote und SDRconnect, nie PTT (bewusst). Mit dem HackRF im eigenen I/Q-Modus stellt Digidec die Frequenz selbst ein. Dialog „Funkgerät“, Info-Fenster und Klick auf den Knopf in den Commandern sind laut Plan nicht von Hand geprüft **(prüfen, teils später erledigt)**. | gering |

### 4.3 Prüfung und Qualität

| Thema | Befund | Gewicht |
|---|---|---|
| **Live-Prüfung** | Bestätigt: AIS, ADS-B, SENSOREN. **Aufnahmen und Testsignale, aber nicht live:** ALE, CW, DCF77, DSC, EFR, FREEDV, FT4, FT8, HELL, HFDL, MFSK, MT63, NAVTEX, NDB, OLIVIA, PSK, RTTY, SKIMMER, SSTV, WEFAX, WSPR, ACARS, APRS, D-STAR, DMR, DPMR, M17, PACKET, PAGER, SONDE, TETRA, TÖNE, VDL2, VOR/ILS, YSF. Einige davon haben kein echtes Gegenstück (Sende- und Empfangsseite aus derselben Quelle: MFSK, HELL, PSK). | hoch |
| **Echte Aufnahmen fehlen** | M17, DMR (Alias), ILS, FLEX/DAPNET, Notruf-DSC, VDL2 (nur Testdaten in `TestData/VDL2`), NDB (`TestData/NDB`, Aufnahme da, aber kein Funkfeuer am Gerät). | mittel |
| **Zufallsabhängige Tests** | Logiktests mit Zufall: MT63 „1000S bei 6 dB“ und POCSAG „Rauschen“. Können an der Grenze scheitern. | gering |
| **Veröffentlichung** | Offene Punkte aus dem Plan (§ „Offen vor der Veröffentlichung“): Name im Copyright bestätigen; Lizenzen von SondeHub-Daten, cty.dat, Stationslisten, DWD-Sendeplänen, acars-decoder-typescript, Jalocha-Quellen nicht abschließend geprüft; Testaufnahmen stecken noch im Git-Verlauf früherer Commits; Adresse in den Commits. | mittel (vor Veröffentlichung) |

---

## 5. Was der Plan nennt und noch nicht gebaut ist

Aus `PLAN.md`, Abschnitt 9 (Decoder-Quellen), nicht in der Modulleiste:

| Modus | Quelle | Aufwand (laut Plan) | Gewicht |
|---|---|---|---|
| JT65, JT9, Q65, MSK144, FST4 | WSJT-X | schwer (Fortran/C++) | gering |
| JS8 | JS8Call | schwer | gering |
| DRM (Kurzwellenrundfunk) | Dream | schwer | gering |
| NOAA APT / Meteor LRPT (Satellitenbilder) | aptdec / SatDump | leicht / schwer | mittel (APT, passt zu Ihren SDRs) |
| RDS (UKW-Rundfunk) | redsea | leicht | gering |
| DAB/DAB+ | welle.io | mittel bis schwer | gering |
| NXDN, P25, EDACS | dsd-fme | mittel | gering |
| FX.25, IL2P, 9600 Bd Packet | direwolf | mittel | gering |
| LoRa | SDRangel | schwer | gering |
| Radiosonden M10/M20, DFM u. a. | radiosonde_auto_rx | mittel | mittel bis hoch |

---

## 6. Vorschlag für die nächsten Schritte

1. **SENSOREN:** Ansicht „unbekannte Pakete“ (Zeit, Pegel, Pulsanzahl, Rohbits) und Sensoren-Verlauf speichern. Klein, trägt auf alle I/Q-Module aus.
2. **Eigener FM-/AM-Empfänger aus I/Q** (Abschnitt 4.1): größter Hebel, weil er zehn Module ohne GQRX und VALHost bedienbar macht.
3. **Liveprüfung mit Ihnen**, in dieser Reihenfolge (bequem, mit Ihren Geräten): PAGER (DAPNET 439,9875 MHz), APRS (144,800 MHz), SONDE (RS41 zu den Startzeiten), VDL2 (136,975 MHz), ACARS (131,725 MHz), NDB (Langwelle), FT8 (20 m).
4. **SONDE:** M10, M20, DFM.
5. **Ausgänge** (NMEA, SBS, MQTT) nur auf Ihren Wunsch.

Wichtig: Diese Datei ist eine Arbeitsgrundlage und nicht in Git aufgenommen. Wenn Sie nach dem Durchsehen Punkte streichen oder umgewichten, passe ich sie an.
