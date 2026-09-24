#!/usr/bin/env python3
"""Generates FOX-1's ring earcons: assets/sounds/ring_press.pcm and
ring_release.pcm. Original sounds, made here, so they carry the project's
licence. Raw 24 kHz mono PCM16 little-endian — the AudioTrack's own format.

    python3 tool/make_earcons.py

Swap in your own by writing files in the same format; keep them short (under
half a second) and faded at the end, or the track clicks.
"""
import math
import struct
from pathlib import Path

RATE = 24000


def chirp(f0, f1, ms, gain=0.55, harmonics=((1, 1.0), (2, 0.25), (3, 0.08))):
    """A pitch glide from f0 to f1 with a fast attack and an exponential tail."""
    n = int(RATE * ms / 1000)
    out, phase = [], 0.0
    for i in range(n):
        t = i / n
        f = f0 * (f1 / f0) ** t  # glide evenly in pitch, not in Hz
        phase += 2 * math.pi * f / RATE
        attack = min(1.0, i / (RATE * 0.004))
        env = attack * math.exp(-4.5 * t)
        s = sum(a * math.sin(k * phase) for k, a in harmonics)
        out.append(gain * env * s / sum(a for _, a in harmonics))
    return out


def silence(ms):
    return [0.0] * int(RATE * ms / 1000)


def write(path, samples):
    # A short fade on the very end, whatever the envelope left.
    fade = int(RATE * 0.01)
    for i in range(1, min(fade, len(samples)) + 1):
        samples[-i] *= (i - 1) / fade
    data = b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples)
    Path(path).write_bytes(data)
    print(f"{path}: {len(samples) / RATE * 1000:.0f} ms")


root = Path(__file__).resolve().parent.parent / "assets" / "sounds"
root.mkdir(parents=True, exist_ok=True)
# Press: two quick rising notes — "I'm listening".
write(root / "ring_press.pcm", chirp(740, 990, 70) + silence(25) + chirp(990, 1480, 150))
# Release: one soft falling note — "got it".
write(root / "ring_release.pcm", chirp(1175, 660, 260, gain=0.45))
