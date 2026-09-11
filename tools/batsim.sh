#!/usr/bin/env bash
#
# batsim.sh — synthesise a train of FM-sweep "bat" pulses and (optionally) play
# them out of this Mac's speaker, so the listening path can be exercised without
# a bat.
#
# A MacBook's output tops out around 23 kHz (48 kHz devices, and the tweeter and
# the anti-alias filter both give up before Nyquist), so nothing here is a real
# bat call: a Pipistrelle sweeps 65→45 kHz. What it IS good for is anything that
# only cares about the SHAPE — a short, downward FM sweep repeating at a plausible
# rate, landing above OpenBat's 15 kHz band floor (SimplifiedView.bandLowHz) so
# the detector, the squelch gate, the auto-tuner and HowlGuard all see it.
# Below 15 kHz the app is deaf to it by design; the default 22→16 kHz stays
# inside the usable window on both ends.
#
# Usage:
#   tools/batsim.sh                       # 22→16 kHz, 5 ms, 10 pulses/s, play it
#   tools/batsim.sh -s 23 -e 18 -d 3      # steeper, shorter
#   tools/batsim.sh --buzz                # feeding-buzz tail on the end
#   tools/batsim.sh -o /tmp/bat.wav -P    # write the file, don't play
#
set -euo pipefail

start_khz=22        # -s  sweep start (highest) frequency, kHz
end_khz=16          # -e  sweep end (lowest) frequency, kHz
dur_ms=5            # -d  pulse duration, ms
rate_hz=10          # -i  pulses per second
count=30            # -n  number of pulses
amp=0.5             # -a  peak amplitude, 0–1
sample_rate=48000   # -r  output sample rate
shape=hyperbolic    # -S  hyperbolic | linear | log  (sweep law)
buzz=0              # --buzz: append a feeding buzz
out=""              # -o  output path (default: a temp file)
play=1              # -P: don't play

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--start)    start_khz=$2; shift 2 ;;
    -e|--end)      end_khz=$2;   shift 2 ;;
    -d|--duration) dur_ms=$2;    shift 2 ;;
    -i|--rate)     rate_hz=$2;   shift 2 ;;
    -n|--count)    count=$2;     shift 2 ;;
    -a|--amp)      amp=$2;       shift 2 ;;
    -r|--samplerate) sample_rate=$2; shift 2 ;;
    -S|--shape)    shape=$2;     shift 2 ;;
    --buzz)        buzz=1;       shift ;;
    -o|--out)      out=$2;       shift 2 ;;
    -P|--no-play)  play=0;       shift ;;
    -h|--help)     usage 0 ;;
    *) echo "batsim: unknown option $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$out" ]]; then out="${TMPDIR:-/tmp}/batsim_${start_khz}-${end_khz}kHz.wav"; fi

python3 - "$out" "$start_khz" "$end_khz" "$dur_ms" "$rate_hz" "$count" \
              "$amp" "$sample_rate" "$shape" "$buzz" <<'PY'
import math, struct, sys, wave

(out, start_khz, end_khz, dur_ms, rate_hz, count,
 amp, fs, shape, buzz) = sys.argv[1:]
f0, f1 = float(start_khz) * 1000, float(end_khz) * 1000
dur, prf, n_pulses = float(dur_ms) / 1000, float(rate_hz), int(count)
amp, fs, buzz = float(amp), int(fs), int(buzz)

nyq = fs / 2
for name, f in (("start", f0), ("end", f1)):
    if f >= nyq:
        sys.exit(f"batsim: {name} {f/1000:.1f} kHz is at or above Nyquist "
                 f"({nyq/1000:.1f} kHz) for {fs} Hz — it will alias, not play")
    if f > nyq * 0.92:
        print(f"batsim: warning — {name} {f/1000:.1f} kHz is close to Nyquist; "
              f"most laptop speakers roll off hard by here", file=sys.stderr)

def sweep(seconds, fa, fb, peak):
    """One pulse: a downward FM sweep with a 1 ms raised-cosine envelope.

    The envelope matters as much as the sweep — a rectangular gate is a click,
    i.e. broadband energy at every frequency, which any detector will happily
    call a bat and which is exactly the thing that sets the speaker loop off."""
    n = int(seconds * fs)
    edge = max(1, int(0.001 * fs))
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n if n > 1 else 0
        if shape == "linear":
            f = fa + (fb - fa) * t
        elif shape == "log":
            f = fa * (fb / fa) ** t
        else:   # hyperbolic — what a real FM bat sweep is closest to
            f = 1 / (1 / fa + (1 / fb - 1 / fa) * t)
        phase += 2 * math.pi * f / fs
        env = 1.0
        if i < edge:            env = 0.5 - 0.5 * math.cos(math.pi * i / edge)
        elif i > n - edge - 1:  env = 0.5 - 0.5 * math.cos(math.pi * (n - 1 - i) / edge)
        out.append(peak * env * math.sin(phase))
    return out

samples = []
gap = max(0, int(fs / prf) - int(dur * fs)) if prf > 0 else 0
for _ in range(n_pulses):
    samples += sweep(dur, f0, f1, amp)
    samples += [0.0] * gap

if buzz:
    # Terminal buzz: pulses shorten, repetition rate climbs, band narrows and
    # drops. The sustained-energy shape that HowlGuard has to NOT mistake for a
    # runaway, so it is worth having on the end of a test run.
    samples += [0.0] * int(0.2 * fs)
    for k in range(60):
        t = k / 59
        d = 0.0035 - 0.0022 * t                     # 3.5 ms → 1.3 ms
        lo = f1 - (f1 - f0) * 0.15 * t              # band narrows a little
        samples += sweep(d, f0 - (f0 - f1) * 0.3 * t, lo, amp)
        samples += [0.0] * max(0, int(fs * (0.020 - 0.014 * t)) - int(d * fs))
samples += [0.0] * int(0.1 * fs)

with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(fs)
    w.writeframes(b"".join(
        struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples))

print(f"batsim: {n_pulses} pulses {f0/1000:.1f}→{f1/1000:.1f} kHz "
      f"({shape}), {dur*1000:.1f} ms at {prf:g}/s"
      f"{', + feeding buzz' if buzz else ''} → {out} "
      f"[{len(samples)/fs:.1f} s @ {fs} Hz]")
PY

if [[ "$play" == 1 ]]; then
  echo "batsim: playing — turn the volume up; ${start_khz} kHz is quiet on a laptop speaker"
  afplay "$out"
fi
