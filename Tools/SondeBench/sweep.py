# Prüfstand für den RS41-Empfänger: eine IQ-Aufnahme durch nachgebildete Funkbedingungen schicken und mitzählen, wie viele Rahmen Digidec liest
# (Vergleich: rs41mod von zilog80, wenn als drittes Argument angegeben).
# Aufruf: python3 Tools/SondeBench/sweep.py <rs41_96k_float.bin> [Sekunden=60] [pfad/zu/rs41mod]
import subprocess, re, sys, os
here = os.path.dirname(os.path.abspath(__file__)); root = os.path.dirname(os.path.dirname(here))
iq = sys.argv[1]; seconds = sys.argv[2] if len(sys.argv) > 2 else '60'; ref = sys.argv[3] if len(sys.argv) > 3 else None
tmp = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'sondebench.wav')
cases = [('sauber', []), ('C/N 12 dB', ['--cn', '12']), ('C/N 8 dB', ['--cn', '8']), ('C/N 6 dB', ['--cn', '6']),
         ('ZF 50 kHz, C/N 10 dB', ['--ifbw', '50000', '--cn', '10']),
         ('De-Emphase 75 µs', ['--deemph', '75']), ('De-Emphase 150 µs', ['--deemph', '150']), ('De-Emphase 300 µs', ['--deemph', '300']),
         ('Hochpass 300 Hz', ['--hp', '300']), ('Hochpass 500 Hz', ['--hp', '500']), ('Tiefpass 1800 Hz', ['--lp', '1800']),
         ('Sprachband 300–3000 Hz', ['--hp', '300', '--lp', '3000']),
         ('De-Emphase 75 + 300 Hz + 3 kHz, C/N 8 dB', ['--deemph', '75', '--hp', '300', '--lp', '3000', '--cn', '8']),
         ('Frequenzablage +5 kHz', ['--offset', '5000']), ('Bitrate +300 ppm', ['--ppm', '300']), ('Bitrate −300 ppm', ['--ppm', '-300'])]
print('%-44s %8s %s' % ('Bedingung', 'Digidec', 'rs41mod' if ref else ''))
for name, args in cases:
    subprocess.run(['python3', os.path.join(here, 'sondechan.py'), iq, tmp, '--seconds', seconds] + args, check=True)
    out = subprocess.run([os.path.join(root, 'Tools/DecodeFile/decode_file.sh'), tmp, '--sonde'], capture_output=True, text=True).stdout
    n = int(re.search(r'(\d+) Rahmen', out).group(1))
    line = '%-44s %8d' % (name, n)
    if ref: line += ' %8d' % subprocess.run([ref, '-v', tmp], capture_output=True, text=True).stdout.count('lat:')
    print(line, flush=True)
