/* SPDX-License-Identifier: GPL-2.0-or-later */
/* FAAD2 mit DRM-Unterstützung (DRM_SUPPORT) als eigenes Ziel neben dem normalen Decoder: alle globalen Namen tragen die Vorsilbe faaddrm_ (siehe
 * Package.swift und symbols.txt), damit beide Fassungen im selben Programm stehen können. Dieser Kopf macht die Umbenennung auch für Swift sichtbar. */
#ifndef FAAD2DRM_H
#define FAAD2DRM_H
#define NeAACDecAudioSpecificConfig faaddrm_NeAACDecAudioSpecificConfig
#define NeAACDecClose faaddrm_NeAACDecClose
#define NeAACDecDecode faaddrm_NeAACDecDecode
#define NeAACDecDecode2 faaddrm_NeAACDecDecode2
#define NeAACDecGetCapabilities faaddrm_NeAACDecGetCapabilities
#define NeAACDecGetCurrentConfiguration faaddrm_NeAACDecGetCurrentConfiguration
#define NeAACDecGetErrorMessage faaddrm_NeAACDecGetErrorMessage
#define NeAACDecGetVersion faaddrm_NeAACDecGetVersion
#define NeAACDecInit faaddrm_NeAACDecInit
#define NeAACDecInit2 faaddrm_NeAACDecInit2
#define NeAACDecInitDRM faaddrm_NeAACDecInitDRM
#define NeAACDecOpen faaddrm_NeAACDecOpen
#define NeAACDecPostSeekReset faaddrm_NeAACDecPostSeekReset
#define NeAACDecSetConfiguration faaddrm_NeAACDecSetConfiguration
#include "neaacdec.h"
#endif
