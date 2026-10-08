// SPDX-License-Identifier: GPL-3.0-or-later
// Digidec: C-Schnittstelle (ersetzt Worker und Decoder von JS8.cpp, die auf Qt-Threads aufbauen).
// Wird von port_js8.py ans Ende von js8_core.cc gehängt.

#include "js8_digidec.h"

namespace
{
    // Jeder Decoder trägt Pläne und große Zwischenspeicher (bis 10 MB): einmal je Betriebsart auf dem Heap, erst bei Bedarf
    template <typename Mode>
    struct Slot
    {
        std::mutex                        mutex;
        std::unique_ptr<DecodeMode<Mode>> decoder;
    };

    Slot<ModeA> slotA;
    Slot<ModeB> slotB;
    Slot<ModeC> slotC;
    Slot<ModeE> slotE;
    Slot<ModeI> slotI;

    struct Bridge
    {
        js8dd_decode_fn fn;
        void           *ctx;

        void operator()(JS8::Event::Variant const &event) const
        {
            auto const *d = std::get_if<JS8::Event::Decoded>(&event);
            if (!d || !fn) return;
            js8dd_decode out{};
            std::strncpy(out.data, d->data.c_str(), sizeof(out.data) - 1);
            out.frame_type = d->type;
            out.snr        = d->snr;
            out.dt         = d->xdt;
            out.freq_hz    = d->frequency;
            out.quality    = d->quality;
            out.submode    = d->mode;
            fn(ctx, &out);
        }
    };

    template <typename Mode>
    int run(Slot<Mode> &slot, dec_data const &data, Bridge const &bridge)
    {
        std::lock_guard<std::mutex> lock(slot.mutex);
        if (!slot.decoder) slot.decoder = std::make_unique<DecodeMode<Mode>>();
        return static_cast<int>((*slot.decoder)(data, 0, Mode::NMAX, bridge));
    }
}

extern "C" int js8dd_decode_window(const float *samples, int count, int submode, int nfa, int nfb, int nfqso,
                                   js8dd_decode_fn on_decode, void *ctx)
{
    if (!samples || count <= 0) return -1;

    dec_data data{};
    data.params.nutc      = 0;
    data.params.nfqso     = nfqso;
    data.params.nfa       = nfa;
    data.params.nfb       = nfb;
    data.params.syncStats = false;
    data.samples          = samples;
    data.count            = count;

    Bridge const bridge{on_decode, ctx};

    try
    {
        switch (submode)
        {
        case JS8DD_NORMAL: return run(slotA, data, bridge);
        case JS8DD_FAST:   return run(slotB, data, bridge);
        case JS8DD_TURBO:  return run(slotC, data, bridge);
        case JS8DD_SLOW:   return run(slotE, data, bridge);
        case JS8DD_ULTRA:  return run(slotI, data, bridge);
        default:           return -1;
        }
    }
    catch (...)
    {
        return -1;
    }
}

namespace
{
    struct Params { int seconds; int sps; int delayMs; JS8::Costas::Type costas; };

    bool params(int submode, Params &p)
    {
        switch (submode)
        {
        case JS8DD_NORMAL: p = {JS8A_TX_SECONDS, JS8A_SYMBOL_SAMPLES, JS8A_START_DELAY_MS, JS8::Costas::Type::ORIGINAL}; return true;
        case JS8DD_FAST:   p = {JS8B_TX_SECONDS, JS8B_SYMBOL_SAMPLES, JS8B_START_DELAY_MS, JS8::Costas::Type::MODIFIED}; return true;
        case JS8DD_TURBO:  p = {JS8C_TX_SECONDS, JS8C_SYMBOL_SAMPLES, JS8C_START_DELAY_MS, JS8::Costas::Type::MODIFIED}; return true;
        case JS8DD_SLOW:   p = {JS8E_TX_SECONDS, JS8E_SYMBOL_SAMPLES, JS8E_START_DELAY_MS, JS8::Costas::Type::MODIFIED}; return true;
        case JS8DD_ULTRA:  p = {JS8I_TX_SECONDS, JS8I_SYMBOL_SAMPLES, JS8I_START_DELAY_MS, JS8::Costas::Type::MODIFIED}; return true;
        default:           return false;
        }
    }
}

extern "C" int js8dd_period_seconds(int submode) { Params p; return params(submode, p) ? p.seconds : 0; }
extern "C" int js8dd_symbol_samples(int submode) { Params p; return params(submode, p) ? p.sps : 0; }
extern "C" int js8dd_start_delay_ms(int submode) { Params p; return params(submode, p) ? p.delayMs : 0; }

extern "C" int js8dd_encode(int frame_type, int submode, const char *data, int *tones79)
{
    Params p;
    if (!data || !tones79 || !params(submode, p) || std::strlen(data) != 12) return -1;
    try
    {
        JS8::encode(frame_type, JS8::Costas::array(p.costas), data, tones79);
    }
    catch (...)
    {
        return -1;
    }
    return 0;
}

extern "C" int js8dd_synthesize(int frame_type, int submode, const char *data, double f0, double amp, float *out, int max_samples)
{
    Params p;
    int tones[NN];
    if (!out || !params(submode, p) || js8dd_encode(frame_type, submode, data, tones) != 0) return -1;

    int const delay = p.delayMs * JS8_RX_SAMPLE_RATE / 1000;
    int const total = delay + NN * p.sps;
    if (total > max_samples) return -1;

    std::fill(out, out + delay, 0.0f);

    // Phasenstetiges 8-FSK wie Modulator.cpp von JS8Call: Tonabstand = 12000 / Symbolabtastwerte
    double const spacing = static_cast<double>(JS8_RX_SAMPLE_RATE) / p.sps;
    double       phi     = 0.0;
    int          k       = delay;
    for (int i = 0; i < NN; ++i)
    {
        double const dphi = 2.0 * M_PI * (f0 + tones[i] * spacing) / JS8_RX_SAMPLE_RATE;
        for (int j = 0; j < p.sps; ++j)
        {
            out[k++] = static_cast<float>(amp * std::sin(phi));
            phi += dphi;
            if (phi > 2.0 * M_PI) phi -= 2.0 * M_PI;
        }
    }
    return total;
}
