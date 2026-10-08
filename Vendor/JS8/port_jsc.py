#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Erzeugt Vendor/JS8/src/jsc_words.c: das JSC-Wörterbuch von JS8Call (jsc_map.cpp, 262 144 Wörter, Latin-1) als eine
# Zeichenfolge, Wörter durch NUL getrennt, in der Reihenfolge ihres Index. Swift schlägt Wörter damit nur nach (Empfang).
# Aufruf: python3 Vendor/JS8/port_jsc.py     (Original: Vendor/_upstream/js8call/jsc_map.cpp)
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "_upstream", "js8call", "jsc_map.cpp")

entry = re.compile(rb'^\s*\{"((?:[^"\\]|\\.)*)"\s*(?:/\*.*?\*/)?\s*,\s*(\d+)\s*,\s*(\d+)\s*\}')


def unescape(raw: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(raw):
        c = raw[i]
        if c != 0x5C:
            out.append(c)
            i += 1
            continue
        n = raw[i + 1]
        if n == 0x78:  # \xNN
            out.append(int(raw[i + 2:i + 4], 16))
            i += 4
        elif n in b'"\\\'':
            out.append(n)
            i += 2
        elif n in b'ntrabfv0':
            out.append({0x6E: 10, 0x74: 9, 0x72: 13, 0x61: 7, 0x62: 8, 0x66: 12, 0x76: 11, 0x30: 0}[n])
            i += 2
        else:
            sys.exit("unbekannte Escape-Folge: %r" % raw[i:i + 6])
    return bytes(out)


words = []
for line in open(src, "rb"):
    m = entry.match(line)
    if not m:
        continue
    text, size, index = unescape(m.group(1)), int(m.group(2)), int(m.group(3))
    if index != len(words):
        sys.exit("Reihenfolge verletzt bei Index %d" % index)
    words.append(text)

if len(words) != 262144:
    sys.exit("erwartet 262144 Wörter, gefunden %d" % len(words))
if any(b"\0" in w for w in words):
    sys.exit("NUL im Wort")


def c_lit(w: bytes) -> str:
    s = []
    for b in w:
        if b == 0x22:
            s.append('\\"')
        elif b == 0x5C:
            s.append("\\\\")
        elif 0x20 <= b < 0x7F and b != 0x3F:  # kein „?“ (Trigraphen)
            s.append(chr(b))
        else:
            s.append("\\%03o" % b)
    return "".join(s)


lines = [
    "// SPDX-License-Identifier: GPL-3.0-or-later",
    "// jsc_words.c  --  Digidec: JSC-Wörterbuch aus JS8Call (jsc_map.cpp, (C) 2018 Jordan Sherer KN4CRD, GPLv3).",
    "// ERZEUGT von port_jsc.py, nicht von Hand ändern. 262 144 Wörter, Latin-1, durch NUL getrennt, in Indexreihenfolge.",
    '#include "jsc_words.h"',
    "const char jsc_words[] =",
]
chunk = []
for w in words:
    chunk.append(c_lit(w) + "\\000")
    if len(chunk) == 24:
        lines.append('"' + "".join(chunk) + '"')
        chunk = []
if chunk:
    lines.append('"' + "".join(chunk) + '"')
lines[-1] += ";"
lines.append("const unsigned long jsc_words_size = sizeof(jsc_words);")
lines.append("const unsigned jsc_word_count = 262144;")
open(os.path.join(here, "src", "jsc_words.c"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("geschrieben:", len(words), "Wörter,", sum(len(w) + 1 for w in words), "Byte")
