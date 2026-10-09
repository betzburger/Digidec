// ----------------------------------------------------------------------------
// ft8lib_synth.c  --  Digidec: FT8-Testsignal aus Klartext (nur für Tests; Digidec sendet nie)
//
// Kodierung mit ft8_lib (message.c, encode.c), GFSK-Synthese wörtlich aus ft8_lib demo/gen_ft8.c
// (gfsk_pulse, synth_gfsk). Copyright (c) 2018 Kārlis Goba, MIT (LICENSE_ft8_lib.txt).
// ----------------------------------------------------------------------------
#include <math.h>
#include <string.h>
#include "ft8_digidec.h"
#include "ft8lib/message.h"
#include "ft8lib/encode.h"
#include "ft8lib/constants.h"

#define FT8_SYMBOL_BT 2.0f ///< symbol smoothing filter bandwidth factor (BT)
#define GFSK_CONST_K 5.336446f ///< == pi * sqrt(2 / log(2))

static void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse)
{
    for (int i = 0; i < 3 * n_spsym; ++i)
    {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = GFSK_CONST_K * symbol_bt * (t + 0.5f);
        float arg2 = GFSK_CONST_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

static void synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt, float symbol_period, int signal_rate, float* signal)
{
    int n_spsym = (int)(0.5f + signal_rate * symbol_period); // Samples per symbol
    int n_wave = n_sym * n_spsym;                            // Number of output samples
    float hmod = 1.0f;

    // Compute the smoothed frequency waveform.
    // Length = (nsym+2)*n_spsym samples, first and last symbols extended
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    float dphi[n_wave + 2 * n_spsym];

    // Shift frequency up by f0
    for (int i = 0; i < n_wave + 2 * n_spsym; ++i)
    {
        dphi[i] = 2 * M_PI * f0 / signal_rate;
    }

    float pulse[3 * n_spsym];
    gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < n_sym; ++i)
    {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
        {
            dphi[j + ib] += dphi_peak * symbols[i] * pulse[j];
        }
    }

    // Add dummy symbols at beginning and end with tone values equal to 1st and last symbol, respectively
    for (int j = 0; j < 2 * n_spsym; ++j)
    {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * symbols[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * symbols[n_sym - 1];
    }

    // Calculate and insert the audio waveform
    float phi = 0;
    for (int k = 0; k < n_wave; ++k)
    { // Don't include dummy symbols
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }

    // Apply envelope shaping to the first and last symbols
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i)
    {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }
}

#define FT4_SYMBOL_BT 1.0f

int ft8dd_synthesize(const char *text, double f0, int rate, float *out, int max_samples)
{
    ftx_message_t msg;
    if (ftx_message_encode(&msg, NULL, text) != FTX_MESSAGE_RC_OK) return -1;
    uint8_t tones[FT8_NN];
    ft8_encode(msg.payload, tones);
    int n_spsym = (int)(0.5f + rate * FT8_SYMBOL_PERIOD);
    int n = FT8_NN * n_spsym;
    if (n > max_samples) return -2;
    synth_gfsk(tones, FT8_NN, (float)f0, FT8_SYMBOL_BT, FT8_SYMBOL_PERIOD, rate, out);
    return n;
}

int ft4dd_synthesize(const char *text, double f0, int rate, float *out, int max_samples)
{
    ftx_message_t msg;
    if (ftx_message_encode(&msg, NULL, text) != FTX_MESSAGE_RC_OK) return -1;
    uint8_t tones[FT4_NN];
    ft4_encode(msg.payload, tones);
    int n_spsym = (int)(0.5f + rate * FT4_SYMBOL_PERIOD);
    int n = FT4_NN * n_spsym;
    if (n > max_samples) return -2;
    synth_gfsk(tones, FT4_NN, (float)f0, FT4_SYMBOL_BT, FT4_SYMBOL_PERIOD, rate, out);
    return n;
}

// FT2 (inoffiziell): FT4 mit halber Symboldauer (0,024 s, 41,667 Baud, Tonabstand 41,667 Hz), 105 Symbole = 2,52 s
int ft2dd_synthesize(const char *text, double f0, int rate, float *out, int max_samples)
{
    ftx_message_t msg;
    if (ftx_message_encode(&msg, NULL, text) != FTX_MESSAGE_RC_OK) return -1;
    uint8_t tones[FT4_NN];
    ft4_encode(msg.payload, tones);
    const float period = FT4_SYMBOL_PERIOD / 2.0f;
    int n_spsym = (int)(0.5f + rate * period);
    int n = FT4_NN * n_spsym;
    if (n > max_samples) return -2;
    synth_gfsk(tones, FT4_NN, (float)f0, FT4_SYMBOL_BT, period, rate, out);
    return n;
}
