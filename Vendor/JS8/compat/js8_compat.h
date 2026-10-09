// SPDX-License-Identifier: GPL-3.0-or-later
// ----------------------------------------------------------------------------
// js8_compat.h  --  Digidec: Ersatz für JS8.hpp, commons.h, Boost-, Eigen-, FFTW- und Qt-Teile von JS8Call
//
// JS8Call (C) 2025 Allan Bazinet W6BAZ, (C) 2018 Jordan Sherer KN4CRD, GPLv3. Vom Original bleibt die Rechnung
// (JS8.cpp); hier steht nur, was es aus dem Umfeld erwartet. Abweichungen: Vendor/JS8/UPSTREAM_JS8.md
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_JS8_COMPAT_H
#define DIGIDEC_JS8_COMPAT_H

#include <array>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <variant>
#include <vector>
#include "pocketfft_hdronly.h"

// ---- commons.h ----

#define JS8_RX_SAMPLE_RATE 12000
#define JS8_RX_SAMPLE_SIZE (60 * JS8_RX_SAMPLE_RATE)
#define JS8_NUM_SYMBOLS    79

#define JS8A_SYMBOL_SAMPLES 1920
#define JS8A_TX_SECONDS     15
#define JS8A_START_DELAY_MS 500

#define JS8B_SYMBOL_SAMPLES 1200
#define JS8B_TX_SECONDS     10
#define JS8B_START_DELAY_MS 200

#define JS8C_SYMBOL_SAMPLES 600
#define JS8C_TX_SECONDS     6
#define JS8C_START_DELAY_MS 100

#define JS8E_SYMBOL_SAMPLES 3840
#define JS8E_TX_SECONDS     30
#define JS8E_START_DELAY_MS 500

#define JS8I_SYMBOL_SAMPLES 384
#define JS8I_TX_SECONDS     4
#define JS8I_START_DELAY_MS 100

/// Eingabe eines Decodierlaufs (ersetzt `dec_data` aus commons.h): ein Fenster Audio im Speicher, Pegel wie 16-Bit-Zahlen
struct dec_data
{
    struct
    {
        int  nutc;        // wird nur durchgereicht
        int  nfqso;       // bevorzugte NF-Frequenz (Hz)
        int  nfa;         // untere Grenze der Suche (Hz)
        int  nfb;         // obere Grenze der Suche (Hz)
        bool syncStats;
    } params;
    const float *samples; // 12 kHz, Skala wie int16 (±32768)
    int          count;
};

// ---- FFTW (float) auf pocketfft: gleiche Konventionen (unnormiert, Vorzeichen), Pläne merken ihre Puffer ----

typedef float fftwf_complex[2];

#define FFTW_FORWARD  (-1)
#define FFTW_BACKWARD (+1)
#define FFTW_ESTIMATE_PATIENT 0U

struct digidec_fftwf_plan_s
{
    int          kind;     // 0 r2c, 2 c2c
    int          n;
    int          sign;
    float       *rin;
    fftwf_complex *in;
    fftwf_complex *out;
};
typedef digidec_fftwf_plan_s *fftwf_plan;

inline std::mutex fftw_mutex;

inline fftwf_plan fftwf_plan_dft_r2c_1d(int n, float *in, fftwf_complex *out, unsigned)
{ return new digidec_fftwf_plan_s{0, n, FFTW_FORWARD, in, nullptr, out}; }
inline fftwf_plan fftwf_plan_dft_1d(int n, fftwf_complex *in, fftwf_complex *out, int sign, unsigned)
{ return new digidec_fftwf_plan_s{2, n, sign, nullptr, in, out}; }
inline void fftwf_destroy_plan(fftwf_plan p) { delete p; }

inline void fftwf_execute(const fftwf_plan p)
{
    pocketfft::shape_t shape{(size_t)p->n};
    if (p->kind == 0)
    {
        // Eingang und Ausgang liegen im selben Speicher (wie bei FFTW „in place“): Eingang vorher sichern
        std::vector<float> tmp(p->rin, p->rin + p->n);
        pocketfft::r2c(shape, {(ptrdiff_t)sizeof(float)}, {(ptrdiff_t)sizeof(std::complex<float>)}, 0,
                       pocketfft::FORWARD, tmp.data(), reinterpret_cast<std::complex<float> *>(p->out), 1.0f, 1);
    }
    else
    {
        pocketfft::stride_t st{(ptrdiff_t)sizeof(std::complex<float>)};
        pocketfft::c2c(shape, st, st, {0}, p->sign == FFTW_FORWARD,
                       reinterpret_cast<std::complex<float> *>(p->in), reinterpret_cast<std::complex<float> *>(p->out), 1.0f, 1);
    }
}

// ---- JS8.hpp ohne Qt ----

namespace JS8
{
    namespace Costas
    {
        // JS8 „Normal“ benutzt die Costas-Arrays von FT8, alle anderen Betriebsarten die geänderten.
        enum class Type { ORIGINAL, MODIFIED };

        using Array = std::array<std::array<int, 7>, 3>;

        constexpr auto array = []
        {
            constexpr auto COSTAS = std::array
            {
                std::array
                {
                    std::array{4, 2, 5, 6, 1, 3, 0},
                    std::array{4, 2, 5, 6, 1, 3, 0},
                    std::array{4, 2, 5, 6, 1, 3, 0}
                },
                std::array
                {
                    std::array{0, 6, 2, 3, 5, 4, 1},
                    std::array{1, 5, 0, 2, 3, 6, 4},
                    std::array{2, 5, 0, 6, 4, 1, 3}
                }
            };

            return [COSTAS](Type type) -> Array const &
            {
                return COSTAS[static_cast<std::underlying_type_t<Type>>(type)];
            };
        }();
    }

    void encode(int type, Costas::Array const & costas, const char * message, int * tones);

    namespace Event
    {
        struct DecodeStarted { int submodes; };
        struct SyncStart { int position; int size; };
        struct SyncState
        {
            enum class Type { CANDIDATE, DECODED } type;
            int   mode;
            float frequency;
            float dt;
            union { int candidate; float decoded; } sync;
        };
        struct Decoded
        {
            int         utc;
            int         snr;
            float       xdt;
            float       frequency;
            std::string data;
            int         type;
            float       quality;
            int         mode;
        };
        struct DecodeFinished { std::size_t decoded; };

        using Variant = std::variant<DecodeStarted, SyncStart, SyncState, Decoded, DecodeFinished>;
        using Emitter = std::function<void(Variant const &)>;
    }
}

#endif
