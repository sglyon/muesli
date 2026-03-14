#!/usr/bin/env python3
"""Benchmark mlx-whisper transcription.

Usage:
    python3 benchmarks/bench_mlx.py <wav-path> [--iterations N] [--model MODEL]

Prints JSON to stdout with: backend, model, load_time, cold_time, warm_avg, warm_min, iterations, text
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import wave

import numpy as np

DEFAULT_MODEL = "mlx-community/whisper-small.en-mlx"


def load_wav(path: str) -> np.ndarray:
    """Read WAV to float32 numpy array, resampling to 16kHz mono if needed."""
    with wave.open(path, "r") as wf:
        sample_rate = wf.getframerate()
        n_channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        raw = wf.readframes(wf.getnframes())

    if sample_width == 2:
        audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sample_width == 4:
        audio = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        audio = np.frombuffer(raw, dtype=np.float32)

    if n_channels > 1:
        audio = audio.reshape(-1, n_channels).mean(axis=1)

    if sample_rate != 16000:
        from scipy.signal import resample

        n_samples = int(len(audio) * 16000 / sample_rate)
        audio = resample(audio, n_samples).astype(np.float32)

    return audio


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark mlx-whisper")
    parser.add_argument("wav", help="Path to WAV file")
    parser.add_argument(
        "--iterations", "-n", type=int, default=3, help="Warm runs (default: 3)"
    )
    parser.add_argument("--model", "-m", default=DEFAULT_MODEL, help="Model repo")
    args = parser.parse_args()

    audio = load_wav(args.wav)

    # Load model
    t0 = time.perf_counter()
    from mlx_whisper import transcribe as mlx_transcribe
    from mlx_whisper.load_models import load_model

    load_model(args.model)
    load_time = time.perf_counter() - t0
    print(f"[load] {load_time:.3f}s", file=sys.stderr)

    def do_transcribe() -> str:
        return mlx_transcribe(audio, path_or_hf_repo=args.model).get("text", "").strip()

    # Cold run
    t0 = time.perf_counter()
    text = do_transcribe()
    cold_time = time.perf_counter() - t0
    print(f"[cold] {cold_time:.3f}s", file=sys.stderr)

    # Warm runs
    warm_times: list[float] = []
    for i in range(args.iterations):
        t0 = time.perf_counter()
        do_transcribe()
        elapsed = time.perf_counter() - t0
        warm_times.append(elapsed)
        print(f"[warm[{i}]] {elapsed:.3f}s", file=sys.stderr)

    warm_avg = sum(warm_times) / len(warm_times) if warm_times else 0.0
    warm_min = min(warm_times) if warm_times else 0.0

    result = {
        "backend": "mlx_whisper",
        "model": args.model,
        "load_time": round(load_time, 3),
        "cold_time": round(cold_time, 3),
        "warm_avg": round(warm_avg, 3),
        "warm_min": round(warm_min, 3),
        "iterations": args.iterations,
        "text": text,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
