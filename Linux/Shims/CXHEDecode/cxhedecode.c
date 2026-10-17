// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#include "cxhedecode.h"
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>

struct xhe_decoder {
    AVCodecContext *ctx;
    AVPacket *packet;
    AVFrame *frame;
    int channels;
};

xhe_decoder *xhe_open(const uint8_t *asc, int ascLength, int sampleRate, int channels) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_AAC);
    if (!codec || ascLength <= 0 || channels < 1 || channels > 2) return NULL;
    xhe_decoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->channels = channels;
    d->ctx = avcodec_alloc_context3(codec);
    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->ctx || !d->packet || !d->frame) { xhe_close(d); return NULL; }
    d->ctx->extradata = av_mallocz((size_t)ascLength + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!d->ctx->extradata) { xhe_close(d); return NULL; }
    memcpy(d->ctx->extradata, asc, (size_t)ascLength);
    d->ctx->extradata_size = ascLength;
    d->ctx->sample_rate = sampleRate;
    av_channel_layout_default(&d->ctx->ch_layout, channels);
    if (avcodec_open2(d->ctx, codec, NULL) < 0) { xhe_close(d); return NULL; }
    return d;
}

int xhe_decode(xhe_decoder *d, const uint8_t *au, int length, float *out, int maxFrames) {
    if (!d || length <= 0) return -1;
    if (av_new_packet(d->packet, length) < 0) return -1;
    memcpy(d->packet->data, au, (size_t)length);
    int status = avcodec_send_packet(d->ctx, d->packet);
    av_packet_unref(d->packet);
    if (status < 0) return -1;
    status = avcodec_receive_frame(d->ctx, d->frame);
    if (status == AVERROR(EAGAIN)) return 0;
    if (status < 0) return -1;
    int frames = d->frame->nb_samples < maxFrames ? d->frame->nb_samples : maxFrames;
    int channels = d->frame->ch_layout.nb_channels < d->channels ? d->frame->ch_layout.nb_channels : d->channels;
    for (int c = 0; c < channels; c++) {
        const float *plane = (const float *)d->frame->extended_data[c];
        for (int i = 0; i < frames; i++) out[i * d->channels + c] = plane[i];
    }
    for (int c = channels; c < d->channels; c++)
        for (int i = 0; i < frames; i++) out[i * d->channels + c] = out[i * d->channels];
    av_frame_unref(d->frame);
    return frames;
}

void xhe_flush(xhe_decoder *d) { if (d && d->ctx) avcodec_flush_buffers(d->ctx); }

void xhe_close(xhe_decoder *d) {
    if (!d) return;
    av_frame_free(&d->frame);
    av_packet_free(&d->packet);
    avcodec_free_context(&d->ctx);
    free(d);
}
