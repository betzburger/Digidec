# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Peter Betz und Mitwirkende
# Nachbildung des Funkweges für RS41-Aufnahmen: IQ (96 kHz, complex64) -> Rauschen -> ZF-Filter -> FM-Demodulator -> NF-Kette -> WAV (48 kHz)
# Aufruf: python3 sondechan.py <iq.bin> <aus.wav> [--seconds 60] [--ifbw 15000] [--cn 10] [--offset 2000] [--deemph 75] [--hp 300] [--lp 3000] [--ppm 100]
# Braucht numpy und scipy. IQ-Beispiel: https://rfhead.net/sondes/sonde_samples.tar.gz (rs41_96k_float.bin, aus dem Projekt radiosonde_auto_rx)
import sys, numpy as np, scipy.signal as ss, wave, argparse
ap = argparse.ArgumentParser()
ap.add_argument('src'); ap.add_argument('dst')
ap.add_argument('--seconds', type=float, default=60)
ap.add_argument('--ifbw', type=float, default=15000)        # ZF-Bandbreite (6-poliger Butterworth)
ap.add_argument('--cn', type=float, default=None)           # Träger/Rauschen in der ZF-Bandbreite in dB (None = unverändert)
ap.add_argument('--offset', type=float, default=0)          # Frequenzablage der Sonde in Hz (Gleichanteil im Audio)
ap.add_argument('--deemph', type=float, default=0)          # De-Emphase-Zeitkonstante in µs (0 = aus)
ap.add_argument('--hp', type=float, default=0)              # Hochpass (Kopplung) in Hz
ap.add_argument('--lp', type=float, default=0)              # Tiefpass (NF) in Hz, 4. Ordnung
ap.add_argument('--ppm', type=float, default=0)             # Abtastuhr-Abweichung
ap.add_argument('--gain', type=float, default=1.0)
a = ap.parse_args()
fs = 96000
x = np.fromfile(a.src, dtype=np.complex64, count=int(a.seconds*fs)).astype(np.complex128)
# Mitte bestimmen und auf 0 legen
N = 1 << 16
P = (np.abs(np.fft.fft(x[:N*8].reshape(8, N) * np.hanning(N), axis=1))**2).mean(0); fr = np.fft.fftfreq(N, 1/fs)
band = np.abs(fr) < 40000; w = P[band]**2; f0 = float((fr[band]*w).sum()/w.sum())
n = np.arange(len(x)); x = x * np.exp(-2j*np.pi*(f0 - a.offset)*n/fs)
if a.cn is not None:
    # Signalleistung: Median von |x|² über die lauten Sekunden, Rauschen so, dass C/N in ifbw stimmt
    ps = np.percentile(np.abs(x)**2, 90)
    nvar = ps / (10**(a.cn/10)) * (fs / a.ifbw)               # Rauschleistung über die ganze Abtastbandbreite
    x = x + (np.random.default_rng(1).normal(size=len(x)) + 1j*np.random.default_rng(2).normal(size=len(x))) * np.sqrt(nvar/2)
sos = ss.butter(6, a.ifbw/2, fs=fs, output='sos'); x = ss.sosfilt(sos, x)
d = np.angle(x[1:] * np.conj(x[:-1])) * fs / (2*np.pi)
d = ss.decimate(d, 2, ftype='fir', zero_phase=True)
fs2 = 48000
y = d / 12000.0
if a.deemph > 0:
    tau = a.deemph*1e-6; al = np.exp(-1/(fs2*tau)); y = ss.lfilter([1-al], [1, -al], y)
if a.hp > 0:
    b, aa = ss.butter(1, a.hp/(fs2/2), 'high'); y = ss.lfilter(b, aa, y)
if a.lp > 0:
    sos = ss.butter(4, a.lp/(fs2/2), 'low', output='sos'); y = ss.sosfilt(sos, y)
if a.ppm != 0:
    y = ss.resample(y, int(len(y) * (1 + a.ppm*1e-6)))
y = np.clip(y * a.gain, -1, 1)
with wave.open(a.dst, 'wb') as wf:
    wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(fs2); wf.writeframes((y*30000).astype('<i2').tobytes())
