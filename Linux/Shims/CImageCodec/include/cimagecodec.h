// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// PNG schreiben, PNG und JPEG lesen (libpng, libjpeg). Fehlerbehandlung mit setjmp bleibt in C.
#ifndef CIMAGECODEC_H
#define CIMAGECODEC_H
#include <stdint.h>

/// Schreibt ein PNG. channels: 1 = Grau, 3 = RGB, 4 = RGBA (nicht vormultipliziert). description darf NULL sein. 0 = Erfolg.
int cimg_write_png(const char *path, const uint8_t *pixels, int width, int height, int channels, int rowBytes, const char *description);

/// Liest PNG oder JPEG als 8-Bit-RGBA (4 Bytes je Punkt). Rückgabe mit cimg_free freigeben; NULL bei Fehler.
uint8_t *cimg_read_rgba(const char *path, int *width, int *height);

void cimg_free(void *p);
#endif
