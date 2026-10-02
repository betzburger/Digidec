#!/usr/bin/env python3
"""Erstellt aus Resources/AppIcon-1024.png ein macOS-konformes AppIcon.icns für Digidec.

Das Icon folgt den macOS Human Interface Guidelines:
- Standard 1024x1024 Canvas mit 824x824 Squircle und weichem Drop Shadow
- Reduzierter Apple-Stil im RadioTheme (Schiefergraues gebürstetes Metall, VFD Cyan/Amber Glühen)
- Visuelle Metapher: Analoge Sinuswelle (Eingangssignal) geht im Zentrum nahtlos in diskrete digitale Rechteck-Pulse (demodulierte Baud/Bits) über.
"""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MASTER_PNG = PROJECT_ROOT / "Resources" / "AppIcon-1024.png"
OUTPUT_ICNS = PROJECT_ROOT / "Resources" / "AppIcon.icns"

SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

def main():
    if not MASTER_PNG.exists():
        raise FileNotFoundError(f"Master PNG not found at {MASTER_PNG}")

    img = Image.open(MASTER_PNG)
    with tempfile.TemporaryDirectory() as tmpdir:
        iconset_dir = Path(tmpdir) / "AppIcon.iconset"
        iconset_dir.mkdir(parents=True, exist_ok=True)

        for filename, size in SIZES:
            resized = img.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(iconset_dir / filename, "PNG")

        OUTPUT_ICNS.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(OUTPUT_ICNS)],
            check=True
        )

    print(f"✓ AppIcon.icns erfolgreich erzeugt ({OUTPUT_ICNS.stat().st_size} Bytes)")

if __name__ == "__main__":
    main()
