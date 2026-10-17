// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#include "cimagecodec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <png.h>
#include <jpeglib.h>

int cimg_write_png(const char *path, const uint8_t *pixels, int width, int height, int channels, int rowBytes, const char *description) {
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info = png ? png_create_info_struct(png) : NULL;
    if (!png || !info) { if (png) png_destroy_write_struct(&png, NULL); fclose(f); return 2; }
    if (setjmp(png_jmpbuf(png))) { png_destroy_write_struct(&png, &info); fclose(f); return 3; }
    png_init_io(png, f);
    int type = channels == 1 ? PNG_COLOR_TYPE_GRAY : channels == 3 ? PNG_COLOR_TYPE_RGB : PNG_COLOR_TYPE_RGBA;
    png_set_IHDR(png, info, (png_uint_32)width, (png_uint_32)height, 8, type, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    if (description) {
        png_text text;
        memset(&text, 0, sizeof text);
        text.compression = PNG_TEXT_COMPRESSION_NONE;
        text.key = (png_charp)"Description";
        text.text = (png_charp)description;
        text.text_length = strlen(description);
        png_set_text(png, info, &text, 1);
    }
    png_write_info(png, info);
    for (int y = 0; y < height; y++) png_write_row(png, (png_const_bytep)(pixels + (size_t)y * rowBytes));
    png_write_end(png, NULL);
    png_destroy_write_struct(&png, &info);
    fclose(f);
    return 0;
}

static uint8_t *read_png(FILE *f, int *w, int *h) {
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info = png ? png_create_info_struct(png) : NULL;
    if (!png || !info) { if (png) png_destroy_read_struct(&png, NULL, NULL); return NULL; }
    uint8_t *out = NULL;
    png_bytep *rows = NULL;
    if (setjmp(png_jmpbuf(png))) { png_destroy_read_struct(&png, &info, NULL); free(out); free(rows); return NULL; }
    png_init_io(png, f);
    png_read_info(png, info);
    int width = (int)png_get_image_width(png, info), height = (int)png_get_image_height(png, info);
    int ct = png_get_color_type(png, info), depth = png_get_bit_depth(png, info);
    if (depth == 16) png_set_strip_16(png);
    if (ct == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (ct == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (ct == PNG_COLOR_TYPE_GRAY || ct == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    png_read_update_info(png, info);
    out = malloc((size_t)width * height * 4);
    rows = malloc(sizeof(png_bytep) * height);
    if (!out || !rows) png_error(png, "memory");
    for (int y = 0; y < height; y++) rows[y] = out + (size_t)y * width * 4;
    png_read_image(png, rows);
    png_destroy_read_struct(&png, &info, NULL);
    free(rows);
    *w = width; *h = height;
    return out;
}

struct jerr { struct jpeg_error_mgr base; jmp_buf jump; };
static void jerr_exit(j_common_ptr c) { longjmp(((struct jerr *)c->err)->jump, 1); }

static uint8_t *read_jpeg(FILE *f, int *w, int *h) {
    struct jpeg_decompress_struct cinfo;
    struct jerr err;
    uint8_t *out = NULL;
    cinfo.err = jpeg_std_error(&err.base);
    err.base.error_exit = jerr_exit;
    if (setjmp(err.jump)) { jpeg_destroy_decompress(&cinfo); free(out); return NULL; }
    jpeg_create_decompress(&cinfo);
    jpeg_stdio_src(&cinfo, f);
    jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);
    int width = (int)cinfo.output_width, height = (int)cinfo.output_height;
    out = malloc((size_t)width * height * 4);
    uint8_t *line = malloc((size_t)width * 3);
    if (!out || !line) { free(line); jpeg_destroy_decompress(&cinfo); free(out); return NULL; }
    while ((int)cinfo.output_scanline < height) {
        int y = (int)cinfo.output_scanline;
        JSAMPROW row = line;
        jpeg_read_scanlines(&cinfo, &row, 1);
        uint8_t *dst = out + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) { dst[4*x] = line[3*x]; dst[4*x+1] = line[3*x+1]; dst[4*x+2] = line[3*x+2]; dst[4*x+3] = 255; }
    }
    free(line);
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    *w = width; *h = height;
    return out;
}

uint8_t *cimg_read_rgba(const char *path, int *width, int *height) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    unsigned char magic[8] = {0};
    size_t got = fread(magic, 1, 8, f);
    rewind(f);
    uint8_t *out = NULL;
    if (got >= 8 && png_sig_cmp(magic, 0, 8) == 0) out = read_png(f, width, height);
    else if (got >= 3 && magic[0] == 0xFF && magic[1] == 0xD8) out = read_jpeg(f, width, height);
    fclose(f);
    return out;
}

void cimg_free(void *p) { free(p); }
