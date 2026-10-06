#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
"""Kopiert Codec2 (David Rowe, LGPL-2.1) aus Vendor/_upstream/freedv/codec2 nach Vendor/Codec2.

Aufruf:  python3 Vendor/Codec2/port_codec2.py <Ordner mit den erzeugten codebook*.c>
Die acht Codebuch-Tabellen erzeugt cmake beim Bau von Codec2 (Hilfsprogramm generate_codebook):
    cmake -S Vendor/_upstream/freedv/codec2 -B /tmp/c2build -DUNITTEST=OFF -DLPCNET=OFF
    cmake --build /tmp/c2build --target codec2
    python3 Vendor/Codec2/port_codec2.py /tmp/c2build/src
Das Skript bricht ab, wenn die Quelle nicht wie erwartet aussieht.
"""
import os, re, shutil, sys

root = os.path.dirname(os.path.abspath(__file__))
up = os.path.join(root, "..", "_upstream", "freedv", "codec2")
src = os.path.join(up, "src")
if len(sys.argv) != 2:
    sys.exit(__doc__)
generated = sys.argv[1]

cmake = open(os.path.join(src, "CMakeLists.txt")).read()
a = cmake.index("set(CODEC2_SRCS")
b = cmake.index(")", a)
files = sorted(set(re.findall(r"^\s+([A-Za-z0-9_]+\.c)\s*$", cmake[a:b], re.M)))
if len(files) != 63:
    sys.exit(f"Erwartet 63 Quelldateien, gefunden {len(files)}: Codec2 hat sich geändert, Skript prüfen")

dest = os.path.join(root, "src")
shutil.rmtree(dest, ignore_errors=True)
os.makedirs(dest)
for f in files:
    origin = os.path.join(src, f)
    if not os.path.exists(origin):
        origin = os.path.join(generated, f)
    if not os.path.exists(origin):
        sys.exit(f"{f} fehlt (erzeugte Tabellen unter {generated}?)")
    shutil.copy(origin, os.path.join(dest, f))
# Header: alle, die die Quellen brauchen (die Datei ist klein, Header ohne Gebrauch stören nicht)
for f in sorted(os.listdir(src)):
    if f.endswith(".h") and not f.endswith("_test.h"):          # Testvektoren der Prüfprogramme werden nicht gebraucht
        shutil.copy(os.path.join(src, f), os.path.join(dest, f))
shutil.copy(os.path.join(up, "COPYING"), os.path.join(root, "COPYING_codec2_LGPL-2.1.txt"))
os.makedirs(os.path.join(root, "include", "codec2"), exist_ok=True)
version = os.path.join(generated, "..", "codec2", "version.h")
if not os.path.exists(version):
    sys.exit("codec2/version.h fehlt neben dem Build-Ordner")
shutil.copy(version, os.path.join(root, "include", "codec2", "version.h"))
print(len(files), "Quelldateien übernommen")
