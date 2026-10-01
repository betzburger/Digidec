// ----------------------------------------------------------------------------
// ft4_digidec.c  --  C-Schnittstelle zum FT4-Decoder (ft8_lib von Karlis Goba YL3JG, MIT) für Swift
//
// Digidec. Ein Aufruf decodiert einen 7,5-s-Zyklus (4-GFSK, 20.8333 Baud).
// ----------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>
#include <pthread.h>

#include "ft8_digidec.h"
#include "ft8lib/constants.h"
#include "ft8lib/decode.h"
#include "ft8lib/encode.h"
#include "ft8lib/message.h"
#include "ft8lib/monitor.h"

#define CALLSIGN_HASHTABLE_SIZE 256

static struct {
    char callsign[12];
    uint32_t hash;
} g_callsign_hashtable[CALLSIGN_HASHTABLE_SIZE];

static int g_callsign_hashtable_size = 0;
static pthread_mutex_t g_hash_mu = PTHREAD_MUTEX_INITIALIZER;

static void hashtable_add(const char *callsign, uint32_t hash)
{
    uint16_t hash10 = (hash >> 12) & 0x3FFu;
    int idx_hash = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx_hash].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx_hash].hash & 0x3FFFFFu) == hash) &&
            (strcmp(g_callsign_hashtable[idx_hash].callsign, callsign) == 0)) {
            g_callsign_hashtable[idx_hash].hash &= 0x3FFFFFu; // reset age
            return;
        }
        idx_hash = (idx_hash + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    g_callsign_hashtable_size++;
    strncpy(g_callsign_hashtable[idx_hash].callsign, callsign, 11);
    g_callsign_hashtable[idx_hash].callsign[11] = '\0';
    g_callsign_hashtable[idx_hash].hash = hash;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char *callsign)
{
    uint8_t hash_shift = (hash_type == FTX_CALLSIGN_HASH_10_BITS) ? 12 : (hash_type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t hash10 = (hash >> (12 - hash_shift)) & 0x3FFu;
    int idx_hash = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx_hash].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx_hash].hash & 0x3FFFFFu) >> hash_shift) == hash) {
            strcpy(callsign, g_callsign_hashtable[idx_hash].callsign);
            return true;
        }
        idx_hash = (idx_hash + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    callsign[0] = '\0';
    return false;
}

static void hashtable_cleanup(uint8_t max_age)
{
    for (int idx_hash = 0; idx_hash < CALLSIGN_HASHTABLE_SIZE; ++idx_hash) {
        if (g_callsign_hashtable[idx_hash].callsign[0] != '\0') {
            uint8_t age = (uint8_t)(g_callsign_hashtable[idx_hash].hash >> 24);
            if (age > max_age) {
                g_callsign_hashtable[idx_hash].callsign[0] = '\0';
                g_callsign_hashtable[idx_hash].hash = 0;
                g_callsign_hashtable_size--;
            } else {
                g_callsign_hashtable[idx_hash].hash = (((uint32_t)age + 1u) << 24) | (g_callsign_hashtable[idx_hash].hash & 0x3FFFFFu);
            }
        }
    }
}

static ftx_callsign_hash_interface_t g_hash_if = {
    .lookup_hash = hashtable_lookup,
    .save_hash = hashtable_add
};

int ft4dd_decode_cycle(const float *samples, int count, int rate, double min_hz, double max_hz,
                       ft4dd_decode_fn on_decode, void *ctx)
{
    if (samples == NULL || count <= 0 || on_decode == NULL) return 0;

#define FT4_MIN_SCORE 10
#define FT4_MAX_CANDIDATES 140
#define FT4_LDPC_ITERATIONS 25
#define FT4_MAX_DECODED_MESSAGES 64

    monitor_t mon;
    monitor_config_t mon_cfg = {
        .f_min = (float)(min_hz < 100.0 ? 100.0 : min_hz),
        .f_max = (float)(max_hz > 3800.0 ? 3800.0 : max_hz),
        .sample_rate = rate,
        .time_osr = 2,
        .freq_osr = 2,
        .protocol = FTX_PROTOCOL_FT4
    };

    monitor_init(&mon, &mon_cfg);

    // Audio-Blocke verarbeiten
    for (int pos = 0; pos + mon.block_size <= count; pos += mon.block_size) {
        monitor_process(&mon, samples + pos);
    }

    ftx_candidate_t candidate_list[FT4_MAX_CANDIDATES];
    int num_candidates = ftx_find_candidates(&mon.wf, FT4_MAX_CANDIDATES, candidate_list, FT4_MIN_SCORE);

    int num_decoded = 0;
    ftx_message_t decoded[FT4_MAX_DECODED_MESSAGES];
    bool slot_used[FT4_MAX_DECODED_MESSAGES];
    memset(slot_used, 0, sizeof(slot_used));

    for (int idx = 0; idx < num_candidates; ++idx) {
        const ftx_candidate_t *cand = &candidate_list[idx];
        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(&mon.wf, cand, FT4_LDPC_ITERATIONS, &message, &status)) {
            continue;
        }

        // Duplikate im aktuellen Zyklus ausfiltern
        int h = message.hash % FT4_MAX_DECODED_MESSAGES;
        bool dup = false;
        for (int probe = 0; probe < FT4_MAX_DECODED_MESSAGES; ++probe) {
            int slot = (h + probe) % FT4_MAX_DECODED_MESSAGES;
            if (!slot_used[slot]) {
                slot_used[slot] = true;
                memcpy(&decoded[slot], &message, sizeof(message));
                break;
            }
            if (decoded[slot].hash == message.hash &&
                memcmp(decoded[slot].payload, message.payload, sizeof(message.payload)) == 0) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        // Klartext entpacken
        char text[FTX_MAX_MESSAGE_LENGTH + 8];
        memset(text, 0, sizeof(text));
        ftx_message_offsets_t offsets;

        pthread_mutex_lock(&g_hash_mu);
        ftx_message_rc_t rc = ftx_message_decode(&message, &g_hash_if, text, &offsets);
        pthread_mutex_unlock(&g_hash_mu);

        if (rc != FTX_MESSAGE_RC_OK) {
            continue;
        }

        double freq_hz = (mon.min_bin + cand->freq_offset + (double)cand->freq_sub / mon.wf.freq_osr) / (double)mon.symbol_period;
        double time_sec = (cand->time_offset + (double)cand->time_sub / mon.wf.time_osr) * (double)mon.symbol_period;

        // WSJT-X-SNR-Approximation in 2500 Hz Bandbreite:
        // score * 0.5 ist Tonpegel über Hintergrundrauschen in dB.
        // Bandbreitenverhältnis 2500 Hz / 20.83 Hz = 120 = 20.8 dB.
        double snr = (double)cand->score * 0.5 - 20.8;

        ft4dd_decode d;
        memset(&d, 0, sizeof(d));
        strncpy(d.text, text, sizeof(d.text) - 1);
        d.snr_db = snr;
        d.dt = time_sec;
        d.freq_hz = freq_hz;
        d.correct_bits = 174;
        d.pass = 0;

        on_decode(ctx, &d);
        num_decoded++;
    }

    monitor_free(&mon);

    pthread_mutex_lock(&g_hash_mu);
    hashtable_cleanup(10);
    pthread_mutex_unlock(&g_hash_mu);

    return num_decoded;
}
