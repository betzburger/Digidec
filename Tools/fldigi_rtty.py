#!/usr/bin/env python3
"""fldigi (4.2.13) per XML-RPC für den Vergleich mit Digidec vorbereiten und Empfangstext abholen (PLAN.md, M6).

fldigi muss laufen (XML-RPC-Server Standard: 127.0.0.1:7362). Die Wiedergabe der Aufnahme startet man in fldigi
von Hand: File → Audio → Playback (die WAV-Datei aus ~/Documents/Digidec/Recordings).

  fldigi_rtty.py prepare <aufnahme.wav>   RTTY, Mitte, Reverse und AFC wie in der Begleitdatei setzen, RX-Text leeren
  fldigi_rtty.py status                   Modem, Mitte, Reverse, AFC, Squelch anzeigen
  fldigi_rtty.py fetch <aufnahme.wav>     RX-Text holen und als <aufnahme>.fldigi.txt speichern

Shift, Baud, Bits, Stoppbits, Unshift on Space und ITA2 lassen sich über XML-RPC nicht setzen; prepare nennt die
nötigen Werte für Configure → Modems → TTY.
"""
import json
import sys
import xmlrpc.client
from pathlib import Path

URL = "http://127.0.0.1:7362/RPC2"


def server():
    return xmlrpc.client.ServerProxy(URL, allow_none=True)


def sidecar(wav: Path) -> dict:
    info = wav.with_suffix(".json")
    if not info.exists():
        sys.exit(f"Begleitdatei fehlt: {info}")
    return json.loads(info.read_text(encoding="utf-8"))


def prepare(wav: Path):
    info = sidecar(wav)
    s = server()
    s.modem.set_by_name("RTTY")
    s.modem.set_carrier(int(round(info["centerHz"])))
    # fldigi dreht bei LSB selbst um (Rev xor !USB). Ohne Funkgerät-Anbindung kennt fldigi das Seitenband
    # nicht und nimmt USB an -> hier den fertigen Decoder-Wert setzen, den auch Digidec benutzt hat.
    s.main.set_reverse(bool(info["decoderParameters"]["reverse"]))
    s.main.set_afc(info["options"]["afc"] != -1)
    s.main.set_squelch(False)
    s.text.clear_rx()
    p = info["decoderParameters"]
    print("fldigi vorbereitet: RTTY, Mitte %d Hz, Reverse %s, AFC %s, Squelch aus"
          % (round(info["centerHz"]), p["reverse"], info["options"]["afc"] != -1))
    print("Bitte in fldigi prüfen (Configure → Modems → TTY → Rx/Tx):")
    print("  Shift %g Hz · Baud %g · Bits %d · Stoppbits %g · Parität %s"
          % (p["shift"], p["baud"], p["bits"], p["stopBits"], p["parity"]))
    print("  RX – unshift on space: %s · ITA2: %s"
          % ("an" if p.get("unshiftOnSpace", True) else "AUS", "an" if p.get("ita2") else "aus"))
    print("  AFC-Tempo: %s" % {0: "Slow", 1: "Normal", 2: "Fast"}.get(info["options"]["afc"], "aus"))
    print("Dann: File → Audio → Playback → %s" % wav.name)
    print("Warnung: Das Seitenband muss in fldigi USB sein (kein Rig-Control), sonst dreht fldigi zusätzlich um.")


def status():
    s = server()
    print("Modem:   ", s.modem.get_name())
    print("Mitte:   ", s.modem.get_carrier(), "Hz")
    print("Reverse: ", s.main.get_reverse())
    print("AFC:     ", s.main.get_afc())
    print("Squelch: ", s.main.get_squelch())
    print("RX-Text: ", s.text.get_rx_length(), "Zeichen")


def fetch(wav: Path):
    s = server()
    n = s.text.get_rx_length()
    data = s.text.get_rx(0, n)
    raw = data.data if isinstance(data, xmlrpc.client.Binary) else str(data).encode("latin-1", "replace")
    text = raw.decode("latin-1", "replace")
    out = wav.with_suffix(".fldigi.txt")
    out.write_text(text, encoding="utf-8")
    print(f"{len(text)} Zeichen von fldigi -> {out}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("prepare", "status", "fetch"):
        sys.exit(__doc__)
    try:
        if sys.argv[1] == "status":
            status()
        elif len(sys.argv) < 3:
            sys.exit(__doc__)
        elif sys.argv[1] == "prepare":
            prepare(Path(sys.argv[2]).expanduser())
        else:
            fetch(Path(sys.argv[2]).expanduser())
    except ConnectionRefusedError:
        sys.exit("fldigi antwortet nicht auf 127.0.0.1:7362 – läuft fldigi?")


if __name__ == "__main__":
    main()
