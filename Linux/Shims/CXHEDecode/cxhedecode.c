// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// xHE-AAC über libfdk-aac (Fraunhofer FDK AAC), zur Laufzeit mit dlopen geladen: Digidec bindet die Bibliothek nicht fest ein
// (ihre Lizenz ist mit der GPL nicht verträglich); wer sie installiert hat (Paket „fdk-aac“/„libfdk-aac“), bekommt xHE-AAC.
#include "cxhedecode.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Minimale Deklarationen nach fdk-aac/aacdecoder_lib.h (Version 2.x, ABI stabil), damit zum Bauen keine Entwicklungsdateien nötig sind
typedef void *HANDLE_AACDECODER;
typedef unsigned char UCHAR;
typedef unsigned int UINT;
typedef int INT;
typedef short INT_PCM;
typedef int TRANSPORT_TYPE;
typedef int AAC_DECODER_ERROR;
enum { TT_MP4_RAW = 0 };
enum { AAC_DEC_OK = 0 };
enum { AACDEC_INTR = 4, AACDEC_CLRHIST = 8 };
/// Die ersten Felder von CStreamInfo
typedef struct { INT sampleRate; INT frameSize; INT numChannels; } CStreamInfo;

typedef HANDLE_AACDECODER (*open_fn)(TRANSPORT_TYPE, UINT);
typedef AAC_DECODER_ERROR (*config_raw_fn)(HANDLE_AACDECODER, UCHAR *[], const UINT[]);
typedef AAC_DECODER_ERROR (*fill_fn)(HANDLE_AACDECODER, UCHAR *[], const UINT[], UINT *);
typedef AAC_DECODER_ERROR (*decode_fn)(HANDLE_AACDECODER, INT_PCM *, const INT, const UINT);
typedef CStreamInfo *(*info_fn)(HANDLE_AACDECODER);
typedef void (*close_fn)(HANDLE_AACDECODER);

struct api {
    open_fn open; config_raw_fn config; fill_fn fill; decode_fn decode; info_fn info; close_fn close;
};

static struct api cached;
static int cached_ok = 0;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load_library(void) {
    void *lib = NULL;
    const char *names[] = {"libfdk-aac.so.2", "libfdk-aac.so", NULL};
    for (int i = 0; names[i] && !lib; i++) lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!lib) return;
    cached.open = (open_fn)dlsym(lib, "aacDecoder_Open");
    cached.config = (config_raw_fn)dlsym(lib, "aacDecoder_ConfigRaw");
    cached.fill = (fill_fn)dlsym(lib, "aacDecoder_Fill");
    cached.decode = (decode_fn)dlsym(lib, "aacDecoder_DecodeFrame");
    cached.info = (info_fn)dlsym(lib, "aacDecoder_GetStreamInfo");
    cached.close = (close_fn)dlsym(lib, "aacDecoder_Close");
    cached_ok = cached.open && cached.config && cached.fill && cached.decode && cached.info && cached.close;
}

/// Bibliothek einmal laden (auch wenn mehrere Fäden zugleich einen Decoder öffnen)
static int load_api(struct api *a) {
    pthread_once(&load_once, load_library);
    if (cached_ok) *a = cached;
    return cached_ok;
}

int xhe_available(void) {
    struct api a;
    return load_api(&a);
}

struct xhe_decoder {
    struct api api;
    HANDLE_AACDECODER handle;
    int channels;
    UINT pendingFlags;
};

xhe_decoder *xhe_open(const uint8_t *asc, int ascLength, int sampleRate, int channels) {
    (void)sampleRate;
    if (ascLength <= 0 || channels < 1 || channels > 2) return NULL;
    xhe_decoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    if (!load_api(&d->api)) { free(d); return NULL; }
    d->channels = channels;
    d->handle = d->api.open(TT_MP4_RAW, 1);
    UCHAR *conf[1] = {(UCHAR *)asc};
    UINT length[1] = {(UINT)ascLength};
    if (!d->handle || d->api.config(d->handle, conf, length) != AAC_DEC_OK) { xhe_close(d); return NULL; }
    d->pendingFlags = AACDEC_INTR;
    return d;
}

int xhe_decode(xhe_decoder *d, const uint8_t *au, int length, float *out, int maxFrames) {
    if (!d || !au || !out || length <= 0 || maxFrames <= 0) return -1;
    UCHAR *buffer[1] = {(UCHAR *)au};
    UINT size[1] = {(UINT)length};
    UINT valid = (UINT)length;
    if (d->api.fill(d->handle, buffer, size, &valid) != AAC_DEC_OK) return -1;
    INT_PCM pcm[8 * 2048];
    UINT flags = d->pendingFlags;
    d->pendingFlags = 0;
    AAC_DECODER_ERROR status = d->api.decode(d->handle, pcm, (INT)(sizeof pcm / sizeof pcm[0]), flags);
    if (status != AAC_DEC_OK) return -1;
    CStreamInfo *info = d->api.info(d->handle);
    if (!info || info->frameSize <= 0 || info->numChannels < 1) return -1;
    if ((long)info->frameSize * info->numChannels > (long)(sizeof pcm / sizeof pcm[0])) return -1;
    int frames = info->frameSize < maxFrames ? info->frameSize : maxFrames;
    int channels = info->numChannels;
    for (int i = 0; i < frames; i++)
        for (int c = 0; c < d->channels; c++)
            out[i * d->channels + c] = (float)pcm[i * channels + (c < channels ? c : 0)] / 32768.0f;
    return frames;
}

void xhe_flush(xhe_decoder *d) { if (d) d->pendingFlags = AACDEC_INTR | AACDEC_CLRHIST; }

void xhe_close(xhe_decoder *d) {
    if (!d) return;
    if (d->handle) d->api.close(d->handle);
    free(d);
}
