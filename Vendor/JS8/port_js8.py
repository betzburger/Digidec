#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Erzeugt Vendor/JS8/src/js8_core.cc aus JS8.cpp von JS8Call (Commit a7ff1be, 05.12.2025).
# Aufruf: python3 Vendor/JS8/port_js8.py    (Original: Vendor/_upstream/js8call, siehe UPSTREAM_JS8.md)
# Jede Ersetzung muss genau einmal treffen, sonst bricht das Skript ab: ändert sich das Original, merkt man es sofort.
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
up = os.path.join(here, "..", "_upstream", "js8call")
src = open(os.path.join(up, "JS8.cpp"), encoding="utf-8").read()


def cut(text, start, end, new, keep_end=True):
    """Ersetzt den Text von `start` (einschließlich) bis `end` (ausgeschlossen, wenn keep_end) durch `new`."""
    i = text.find(start)
    if i < 0 or text.count(start) != 1:
        sys.exit("Anfang nicht eindeutig gefunden: " + start[:60])
    j = text.find(end, i + len(start))
    if j < 0:
        sys.exit("Ende nicht gefunden: " + end[:60])
    if not keep_end:
        j += len(end)
    return text[:i] + new + text[j:]


def sub(text, old, new):
    if text.count(old) != 1:
        sys.exit("Stelle nicht eindeutig (%d): %s" % (text.count(old), old[:60]))
    return text.replace(old, new)


# --- Rumpf: ab „Compilation Utilities“ bis vor „Worker“, dazu die Kodierung --------------------------------------
a = src.index("/******************************************************************************/\n// Compilation Utilities")
b = src.index("/******************************************************************************/\n// Worker")
c = src.index("/******************************************************************************/\n// Public Interface - Encoding")
body = src[a:b] + src[c:]

# --- 1. Boost: multi_index (Kandidatenliste) -------------------------------------------------------------------
body = cut(body,
           "    // Tag structs so that we can refer to multi index container indices",
           "    // Represents a decoded message, i.e., the 3-bit message type",
           "    // ABWEICHUNG JS8Call (Digidec): Boost.MultiIndex entfällt, die Kandidaten liegen in einem std::vector.\n\n")
body = sub(body, "                sync.emplace(Mode::DF    * i,", "                sync.emplace_back(Mode::DF    * i,")
body = sub(body, "        SyncIndex                                                                     sync;",
           "        std::vector<Sync>                                                             sync;")

new_select = r'''            // If we found nothing, we're done here.

            if (sync.empty()) return {};

            // ABWEICHUNG JS8Call (Digidec): ohne Boost.MultiIndex. Dieselbe Auswahl:
            // Normierung auf das 40-%-Perzentil der Sync-Werte (Rang size*4/10 aufsteigend) ...

            {
                std::vector<float> ranked;
                ranked.reserve(sync.size());
                for (auto const & entry : sync) ranked.push_back(entry.sync);

                auto const nth = ranked.size() * 4 / 10;
                std::nth_element(ranked.begin(), ranked.begin() + nth, ranked.end());

                float const reference = ranked[nth];
                for (auto & entry : sync) entry.sync /= reference;
            }

            // ... dann wiederholt der stärkste Kandidat (bei Gleichstand der niedrigere, weil zuerst eingetragen),
            // dazu fallen alle Einträge im Abstand AZ (einschließlich) weg. `sync` ist nach Frequenz aufsteigend.

            std::vector<std::size_t> order(sync.size());
            std::iota(order.begin(), order.end(), std::size_t{0});
            std::stable_sort(order.begin(), order.end(), [this](std::size_t x, std::size_t y)
            {
                return sync[x].sync > sync[y].sync;
            });

            std::vector<bool>  removed(sync.size(), false);
            std::vector<Sync>  candidates;

            for (auto const index : order)
            {
                if (candidates.size() >= NMAXCAND) break;

                // Sortiert: alles weitere liegt unter der Schwelle (NaN wird nicht gewählt)

                if (!(sync[index].sync >= ASYNCMIN)) break;
                if (removed[index]) continue;

                auto const chosen = sync[index];
                candidates.push_back(chosen);

                for (std::size_t k = index; k < sync.size() && sync[k].freq <= chosen.freq + Mode::AZ; ++k) removed[k] = true;
                for (std::size_t k = index; k-- > 0 && sync[k].freq >= chosen.freq - Mode::AZ;) removed[k] = true;
            }

            return candidates;
        }
'''
body = cut(body, "            // If we found nothing, we're done here.\n\n            if (sync.empty()) return {};",
           "            return candidates;\n        }\n", new_select, keep_end=False)

# --- 2. Boost: CRC und Rundung -----------------------------------------------------------------------------------
body = sub(body, "        return boost::augmented_crc<12, 0xc06>(range.data(),\n                                               range.size()) ^ 42;",
           "        return augmentedCRC12(range.data(), range.size()) ^ 42;")
body = sub(body, "    template <typename T>\n    std::uint16_t\n    CRC12(",
           '''    // ABWEICHUNG JS8Call (Digidec): boost::augmented_crc<12, 0xc06> ohne Boost, bitweise (Nachricht samt Nullen
    // für die Prüfsumme wird durch das Polynom geteilt, Anfangswert 0, keine Spiegelung).

    inline std::uint16_t
    augmentedCRC12(std::uint8_t const * data, std::size_t const size)
    {
        std::uint16_t rem = 0;

        for (std::size_t i = 0; i < size; ++i)
        {
            for (int bit = 7; bit >= 0; --bit)
            {
                bool const high = rem & 0x800;
                rem = static_cast<std::uint16_t>(((rem << 1) | ((data[i] >> bit) & 1)) & 0xfff);
                if (high) rem ^= 0xc06;
            }
        }

        return rem;
    }

    template <typename T>
    std::uint16_t
    CRC12(''')
body = sub(body, "            using boost::math::ccmath::round;",
           "            constexpr auto round = [](double const x) constexpr { return static_cast<double>(static_cast<long long>(x + 0.5)); };")

# --- 3. Eigen: Ausgleichsparabel der Grundlinie --------------------------------------------------------------------
body = cut(body, "        // Baseline computation support.",
           "        std::optional<Decode>\n        js8dec(",
           r'''        // Baseline computation support.
        // ABWEICHUNG JS8Call (Digidec): ohne Eigen. Die x-Werte der Knoten werden auf [0,1) normiert, das Gleichungssystem
        // (quadratisch: ebenso viele Knoten wie Koeffizienten) mit Gauß-Elimination und Spaltenwahl gelöst.

        using Coefficients = std::array<double, BASELINE_NODES.size()>;

        std::array<std::array<double, 2>, BASELINE_NODES.size()> p;
        Coefficients                                             c;
        double                                                   cscale = 1.0;

        // Polynomauswertung nach Horner an der Stelle x (in Knoten-Einheiten)

        inline auto
        evaluate(float const x) const
        {
            double const t = x / cscale;
            double       r = 0.0;

            for (std::size_t k = c.size(); k-- > 0;) r = r * t + c[k];

            return static_cast<float>(r);
        }

''', keep_end=True)

body = sub(body, "                p.row(i) << node, span[n];", "                p[i] = {node, static_cast<double>(span[n])};")

body = cut(body, "            // Extract x and y values from points and prepare the Vandermonde",
           "            // To map an index i in the range [ia, ib] to the polynomial's",
           r'''            // Vandermonde-Matrix über x/size, dann lösen.

            constexpr std::size_t T = BASELINE_NODES.size();

            cscale = static_cast<double>(size);

            std::array<std::array<double, T + 1>, T> m;

            for (std::size_t r = 0; r < T; ++r)
            {
                double const x = p[r][0] / cscale;
                double       v = 1.0;

                for (std::size_t k = 0; k < T; ++k)
                {
                    m[r][k] = v;
                    v      *= x;
                }

                m[r][T] = p[r][1];
            }

            for (std::size_t col = 0; col < T; ++col)
            {
                std::size_t best = col;

                for (std::size_t r = col + 1; r < T; ++r)
                {
                    if (std::abs(m[r][col]) > std::abs(m[best][col])) best = r;
                }

                std::swap(m[col], m[best]);

                for (std::size_t r = col + 1; r < T; ++r)
                {
                    double const f = m[r][col] / m[col][col];
                    for (std::size_t k = col; k <= T; ++k) m[r][k] -= f * m[col][k];
                }
            }

            for (std::size_t r = T; r-- > 0;)
            {
                double s = m[r][T];
                for (std::size_t k = r + 1; k < T; ++k) s -= m[r][k] * c[k];
                c[r] = s / m[r][r];
            }

''', keep_end=True)

# --- 4. Eingang: Audio aus dem Speicher statt Ringpuffer dec_data.d2 --------------------------------------------
body = cut(body, "            // Copy the relevant frames for decoding",
           "            Decode::Map decodes;",
           r'''            // ABWEICHUNG JS8Call (Digidec): das Fenster liegt im Speicher (Zyklusbeginn = Index 0),
            // kein Ringpuffer; was fehlt, ist Stille.

            (void) kpos;
            (void) ksz;

            dd.fill(0.0f);

            auto const available = static_cast<std::size_t>(std::max(0, data.count));
            std::copy(data.samples,
                      data.samples + std::min<std::size_t>(available, Mode::NMAX),
                      dd.begin());

''', keep_end=True)

# --- Kopf --------------------------------------------------------------------------------------------------------
head = '''// SPDX-License-Identifier: GPL-3.0-or-later
// js8_core.cc  --  Digidec: JS8-Decoder und -Encoder aus JS8Call (GPLv3), erzeugt von port_js8.py aus JS8.cpp
//
// (C) 2025 Allan Bazinet W6BAZ, JS8Call (C) 2018 Jordan Sherer KN4CRD u. a. -- NICHT VON HAND ÄNDERN, siehe UPSTREAM_JS8.md
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <complex>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>
#include "js8_compat.h"

'''
tail = '\n#include "../inc/js8_api.inc"\n'

out = head + body + tail
dst = os.path.join(here, "src", "js8_core.cc")
open(dst, "w", encoding="utf-8").write(out)
print("geschrieben:", dst, len(out.splitlines()), "Zeilen")
