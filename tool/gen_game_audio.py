#!/usr/bin/env python3
"""Generate original stone, bowl, and looping play-room music (no third-party audio)."""

from __future__ import annotations

import math
import random
import struct
import subprocess
import tempfile
import wave
from pathlib import Path

SR = 44100


def _clamp(v: float) -> int:
    return max(-32767, min(32767, int(v * 32767)))


def write_wav(path: Path, left: list[float], right: list[float] | None = None) -> None:
    if right is None:
        right = left
    n = min(len(left), len(right))
    with wave.open(str(path), "w") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            frames += struct.pack("<hh", _clamp(left[i]), _clamp(right[i]))
        w.writeframes(frames)


def to_mp3(wav_path: Path, mp3_path: Path, bitrate: str) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(wav_path),
            "-codec:a",
            "libmp3lame",
            "-b:a",
            bitrate,
            str(mp3_path),
        ],
        check=True,
    )


def env_exp(t: float, decay: float) -> float:
    return math.exp(-t / decay) if t >= 0 else 0.0


def _normalize(left: list[float], right: list[float], peak_target: float) -> tuple[list[float], list[float]]:
    peak = max(1e-6, max(abs(v) for v in left + right))
    gain = peak_target / peak
    return [v * gain for v in left], [v * gain for v in right]


def make_stone() -> tuple[list[float], list[float]]:
    """Dry slate-on-wood knock. Noise crack and a short thump, no musical tone."""
    n = int(SR * 0.07)
    rng = random.Random(11)
    noise = [rng.random() * 2 - 1 for _ in range(n)]
    crack = [0.0] * n
    prev = 0.0
    for i, sample in enumerate(noise):
        t = i / SR
        delta = sample - prev
        prev = sample
        crack[i] = delta * env_exp(t, 0.0009)
    alpha = 1.0 - math.exp(-2.0 * math.pi * 700.0 / SR)
    low = 0.0
    body = [0.0] * n
    for i, sample in enumerate(noise):
        t = i / SR
        low += alpha * (sample - low)
        body[i] = low * env_exp(t, 0.007)
    left = [0.0] * n
    right = [0.0] * n
    for i in range(n):
        t = i / SR
        attack = 1.0 if t > 0.00035 else t / 0.00035
        thump = math.sin(2 * math.pi * 118 * t) * env_exp(t, 0.0035)
        # Hardness lives in the click spectrum and dies before it reads as a pitch.
        hard = (
            math.sin(2 * math.pi * 890 * t) * env_exp(t, 0.0022) * 0.35
            + math.sin(2 * math.pi * 1470 * t) * env_exp(t, 0.0014) * 0.18
        )
        sample = (crack[i] * 1.15 + body[i] * 0.62 + thump * 0.42 + hard) * attack
        left[i] = sample
        right[i] = sample * 0.97
    return _normalize(left, right, 0.98)


def make_bowl() -> tuple[list[float], list[float]]:
    """Several stones dropping into a wooden bowl: one rattle, not one click per stone."""
    n = int(SR * 0.62)
    left = [0.0] * n
    right = [0.0] * n
    rng = random.Random(41)
    clicks = (
        (0.000, 1.00),
        (0.045, 0.72),
        (0.078, 0.55),
        (0.140, 0.42),
        (0.210, 0.30),
        (0.310, 0.22),
        (0.390, 0.14),
    )
    alpha = 1.0 - math.exp(-2.0 * math.pi * 1400.0 / SR)
    for start, amp in clicks:
        start_i = int(start * SR)
        length = int(SR * 0.09)
        prev = 0.0
        low = 0.0
        for k in range(length):
            idx = start_i + k
            if idx >= n:
                break
            t = k / SR
            raw = rng.random() * 2 - 1
            delta = raw - prev
            prev = raw
            low += alpha * (raw - low)
            crack = delta * env_exp(t, 0.0013)
            body = low * env_exp(t, 0.012)
            hollow = (
                math.sin(2 * math.pi * 640 * t) * env_exp(t, 0.016)
                + 0.45 * math.sin(2 * math.pi * 980 * t) * env_exp(t, 0.009)
            )
            sample = (crack * 0.75 + body * 0.38 + hollow * 0.28) * amp
            left[idx] += sample
            right[idx] += sample * 0.94
    return _normalize(left, right, 0.92)


def loop_freq(hz: float, seconds: float) -> float:
    return round(hz * seconds) / seconds


def make_ambient(seconds: float = 64.0) -> tuple[list[float], list[float]]:
    n = int(SR * seconds)
    left = [0.0] * n
    right = [0.0] * n
    rng = random.Random(20260922)
    pent = [loop_freq(f, seconds) for f in (261.63, 293.66, 329.63, 392.00, 440.00)]
    drones = [
        (loop_freq(65.41, seconds), 0.045),
        (loop_freq(98.00, seconds), 0.032),
        (loop_freq(130.81, seconds), 0.028),
        (loop_freq(196.00, seconds), 0.016),
    ]

    events: list[tuple[int, float, float]] = []
    t = 1.6
    while t < seconds - 2.4:
        freq = pent[rng.randrange(len(pent))]
        if rng.random() < 0.35:
            freq *= 0.5
        pan = rng.uniform(-0.45, 0.45)
        events.append((int(t * SR), freq, pan))
        t += rng.uniform(1.8, 3.4)

    for i in range(n):
        sec = i / SR
        drone = 0.0
        for freq, amp in drones:
            wobble = 1 + 0.012 * math.sin(2 * math.pi * (0.04 + freq / 4000) * sec)
            drone += math.sin(2 * math.pi * freq * sec) * amp * wobble
        pad = (
            math.sin(2 * math.pi * pent[0] * sec) * (0.018 + 0.01 * math.sin(2 * math.pi * 0.03 * sec))
            + math.sin(2 * math.pi * pent[3] * sec) * (0.014 + 0.008 * math.sin(2 * math.pi * 0.023 * sec + 1.1))
        )
        air = (rng.random() * 2 - 1) * 0.006
        sample_l = drone + pad + air
        sample_r = drone * 0.96 + pad * 1.04 + air * 0.7
        left[i] = sample_l
        right[i] = sample_r

    for start, freq, pan in events:
        length = int(SR * 2.4)
        for k in range(length):
            idx = start + k
            if idx >= n:
                break
            t = k / SR
            tone = math.sin(2 * math.pi * freq * t) * env_exp(t, 0.55)
            tone += 0.18 * math.sin(2 * math.pi * freq * 2 * t) * env_exp(t, 0.18)
            amp = tone * 0.085
            left[idx] += amp * (1 - pan)
            right[idx] += amp * (1 + pan)

    fade = int(SR * 2.0)
    for i in range(fade):
        w = i / fade
        a = 0.5 - 0.5 * math.cos(math.pi * w)
        left[i] = left[i] * a + left[n - fade + i] * (1 - a)
        right[i] = right[i] * a + right[n - fade + i] * (1 - a)
    del left[-fade:]
    del right[-fade:]

    return _normalize(left, right, 0.55)


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "assets" / "sounds"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        stone_wav = tmp_path / "stone.wav"
        sl, sr_ = make_stone()
        write_wav(stone_wav, sl, sr_)
        to_mp3(stone_wav, root / "stone.mp3", "128k")
        bowl_wav = tmp_path / "capture.wav"
        bl, br = make_bowl()
        write_wav(bowl_wav, bl, br)
        to_mp3(bowl_wav, root / "capture.mp3", "128k")
        ambient_wav = tmp_path / "play_ambient.wav"
        al, ar = make_ambient()
        write_wav(ambient_wav, al, ar)
        to_mp3(ambient_wav, root / "play_ambient.mp3", "96k")
    print("wrote", root / "stone.mp3")
    print("wrote", root / "capture.mp3")
    print("wrote", root / "play_ambient.mp3")


if __name__ == "__main__":
    main()
