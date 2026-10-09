#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
"""AIS-Funkstrecke nachbilden: Sätze (!AIVDM) -> GMSK (BT 0,4, 9600 Bd, ±2,4 kHz) -> Rauschen (C/N in 25 kHz) -> ZF-Filter -> FM-Diskriminator.
Schreibt <präfix>_iq.wav (I/Q 192 kHz, Träger bei +25 kHz, für AIS-catcher) und <präfix>_fm.wav (Diskriminator-Audio 48 kHz, für Digidec).
Aufruf: ais_rf_sim.py <sätze.nmea> <präfix> --cn 12 [--seed 1] [--spacing 0.12] [--clock-ppm 40] [--offset-hz 800] [--audio-lp 12000]
"""
import sys, argparse, wave
import numpy as np
from scipy.signal import butter, sosfilt, resample_poly

def dearmor(payload, fill):
    bits = []
    for ch in payload:
        v = ord(ch) - 48
        if v > 40: v -= 8
        bits += [(v >> k) & 1 for k in range(5, -1, -1)]
    return bits[:len(bits) - fill] if fill else bits

def crc16(bits):
    crc = 0xFFFF
    for b in bits:
        mix = (crc ^ b) & 1
        crc >>= 1
        if mix: crc ^= 0x8408
    return crc

def swap_bytes(bits):
    out = list(bits)
    for i in range(0, len(bits) - len(bits) % 8, 8):
        out[i:i+8] = bits[i:i+8][::-1]
    return out

def wire(payload):
    p = list(payload)
    while len(p) % 8: p.append(0)
    t = swap_bytes(p)
    crc = ~crc16(t) & 0xFFFF
    t += [(crc >> k) & 1 for k in range(16)]
    out = [i % 2 for i in range(24)] + [0,1,1,1,1,1,1,0]
    ones = 0
    for b in t:
        out.append(b)
        if b: 
            ones += 1
            if ones == 5: out.append(0); ones = 0
        else: ones = 0
    out += [0,1,1,1,1,1,1,0] + [0] * 24
    return out

def nrzi(bits, level):
    out = []
    for b in bits:
        if b == 0: level = -level
        out.append(level)
    return np.array(out, dtype=float)

def gmsk_freq(levels, sps, bt=0.4):
    # Rechteckimpuls (1 Bit) gefaltet mit Gauß; Ausgabe: Momentanfrequenz in Einheiten des Hubs (±1)
    n = len(levels)
    up = np.repeat(levels, int(sps))
    sigma = np.sqrt(np.log(2)) / (2 * np.pi * bt) * sps
    k = np.arange(-int(4 * sigma), int(4 * sigma) + 1)
    g = np.exp(-k**2 / (2 * sigma**2)); g /= g.sum()
    pad = np.concatenate([np.full(len(g), up[0]), up, np.full(len(g), up[-1])])
    return np.convolve(pad, g, mode='same')[len(g):len(g) + len(up)]

ap = argparse.ArgumentParser()
ap.add_argument('nmea'); ap.add_argument('prefix')
ap.add_argument('--cn', type=float, default=15.0, help='Träger/Rausch in 25 kHz (dB)')
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--spacing', type=float, default=0.12)
ap.add_argument('--clock-ppm', type=float, default=40.0)
ap.add_argument('--offset-hz', type=float, default=800.0, help='größte Frequenzablage der Sender')
ap.add_argument('--audio-lp', type=float, default=12000.0, help='Tiefpass des Audiozweigs im SDR-Programm (Hz)')
ap.add_argument('--truth', default=None, help='JSON-Datei mit Beginn, Pegelfolge und Takt je Burst (für Genie-Auswertungen)')
ap.add_argument('--fading', type=float, default=0.0, help='Schwankung der Amplitude in dB (Rayleigh-ähnlich, 0 = keine)')
a = ap.parse_args()

rng = np.random.default_rng(a.seed)
FS = 192000
SPS = FS / 9600           # 20
msgs = []
for line in open(a.nmea):
    line = line.strip()
    if not line.startswith('!AIVDM'): continue
    f = line.split(',')
    if int(f[1]) != 1: continue
    msgs.append(dearmor(f[5], int(f[6].split('*')[0])))
total = int((0.3 + len(msgs) * a.spacing + 0.3) * FS)
sig = np.zeros(total, dtype=complex)
truth = []
for k, m in enumerate(msgs):
    levels = nrzi(wire(m), rng.choice([-1, 1]))
    ppm = (rng.random() - 0.5) * 2 * a.clock_ppm
    sps = SPS * (1 + ppm * 1e-6)
    # Taktabweichung: Pegelfolge mit gebrochenem sps erzeugen
    n = int(len(levels) * sps)
    idx = np.minimum((np.arange(n) / sps).astype(int), len(levels) - 1)
    up = levels[idx]
    sigma = np.sqrt(np.log(2)) / (2 * np.pi * 0.4) * sps
    kk = np.arange(-int(4 * sigma), int(4 * sigma) + 1)
    g = np.exp(-kk**2 / (2 * sigma**2)); g /= g.sum()
    pad = np.concatenate([np.full(len(g), up[0]), up, np.full(len(g), up[-1])])
    fr = np.convolve(pad, g, mode='same')[len(g):len(g) + n]
    off = (rng.random() - 0.5) * 2 * a.offset_hz
    inst = fr * 2400 + off
    ph = 2 * np.pi * np.cumsum(inst) / FS + rng.random() * 2 * np.pi
    amp = np.ones(n)
    if a.fading > 0:
        amp = 10 ** (rng.normal(0, a.fading / 2) / 20) * np.ones(n)
    start = int((0.3 + k * a.spacing + rng.random() * 0.03) * FS)
    ramp = np.minimum(1, np.minimum(np.arange(n), np.arange(n)[::-1]) / (0.0004 * FS))
    sig[start:start + n] += amp * ramp * np.exp(1j * ph)
    truth.append({'start': start / FS, 'sps': sps / 4, 'off': off, 'levels': levels.tolist()})
# Rauschen: C/N in 25 kHz; Träger hat Betrag 1
sigma_n = np.sqrt(10 ** (-a.cn / 10) * FS / 25000 / 2)
noise = sigma_n * (rng.standard_normal(total) + 1j * rng.standard_normal(total))
rx = sig + noise
# I/Q-Datei für AIS-catcher: Träger bei +25 kHz
n_ = np.arange(total)
iq = rx * np.exp(2j * np.pi * 25000 * n_ / FS)
scale = 0.25 / np.sqrt(np.mean(np.abs(iq) ** 2))
st = np.empty((total, 2), dtype='<i2'); st[:, 0] = np.clip(iq.real * scale * 32767, -32768, 32767); st[:, 1] = np.clip(iq.imag * scale * 32767, -32768, 32767)
w = wave.open(a.prefix + '_iq.wav', 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(FS); w.writeframes(st.tobytes()); w.close()
# Digidec: ZF-Filter (±12,5 kHz, Butterworth 4. Ordnung), Diskriminator, Audio-Tiefpass, auf 48 kHz
sos = butter(4, 12500, btype='low', fs=FS, output='sos')
bb = sosfilt(sos, rx)
d = bb[1:] * np.conj(bb[:-1])
f = np.angle(d) / (2 * np.pi) * FS
f = np.concatenate([[0], f])
if a.audio_lp < FS / 2:
    f = sosfilt(butter(4, a.audio_lp, btype='low', fs=FS, output='sos'), f)
au = resample_poly(f, 1, 4) / 2400 * 0.3
w = wave.open(a.prefix + '_fm.wav', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
w.writeframes((np.clip(au, -1, 1) * 32767).astype('<i2').tobytes()); w.close()
if a.truth:
    import json; json.dump(truth, open(a.truth, 'w'))
print(f"{len(msgs)} Bursts, C/N {a.cn} dB -> {a.prefix}_iq.wav / {a.prefix}_fm.wav")
