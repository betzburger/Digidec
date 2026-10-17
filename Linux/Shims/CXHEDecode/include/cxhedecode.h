// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// xHE-AAC (USAC) über libavcodec (FFmpeg), Gegenstück zum Format 'usac' von AudioToolbox unter macOS.
#ifndef CXHEDECODE_H
#define CXHEDECODE_H
#include <stdint.h>

typedef struct xhe_decoder xhe_decoder;

/// Öffnet den Decoder mit der AudioSpecificConfig (USAC). NULL, wenn FFmpeg sie nicht annimmt.
xhe_decoder *xhe_open(const uint8_t *asc, int ascLength, int sampleRate, int channels);

/// Decodiert eine Zugriffseinheit; schreibt verschachtelte Gleitkommawerte (L R L R …) nach `out` (höchstens `maxFrames` Rahmen).
/// Rückgabe: Anzahl Rahmen, 0 = nichts geliefert, < 0 = Fehler.
int xhe_decode(xhe_decoder *d, const uint8_t *au, int length, float *out, int maxFrames);

/// Zustand verwerfen (nach Verlust)
void xhe_flush(xhe_decoder *d);

void xhe_close(xhe_decoder *d);
#endif
