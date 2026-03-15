from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np


DEFAULT_WHISPER_MODEL = "mlx-community/whisper-small.en-mlx"
DEFAULT_QWEN_MODEL = "mlx-community/Qwen3-ASR-0.6B-4bit"
DEFAULT_PARAKEET_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


class SpeechBackend(Protocol):
    name: str
    model_repo: str

    def load(self) -> None: ...
    def transcribe(self, audio: np.ndarray) -> str: ...
    def transcribe_segments(self, audio: np.ndarray) -> list[dict]: ...


def _normalize_segments(raw_segments) -> list[dict]:
    normalized = []
    for segment in raw_segments or []:
        if isinstance(segment, dict):
            start = float(segment.get("start", 0.0))
            end = float(segment.get("end", start))
            text = str(segment.get("text", "")).strip()
            if text:
                normalized.append({"start": start, "end": end, "text": text})
    return normalized


@dataclass
class WhisperBackend:
    model_repo: str = DEFAULT_WHISPER_MODEL
    name: str = "whisper"

    def __post_init__(self):
        self._transcribe_fn = None

    def load(self) -> None:
        if self._transcribe_fn is not None:
            return
        from mlx_whisper import transcribe as mlx_transcribe
        from mlx_whisper.load_models import load_model

        load_model(self.model_repo)
        self._transcribe_fn = mlx_transcribe

    def _transcribe_chunk(self, audio: np.ndarray) -> str:
        if audio.size == 0:
            return ""
        self.load()
        result = self._transcribe_fn(audio, path_or_hf_repo=self.model_repo)
        return result.get("text", "").strip()

    def transcribe(self, audio: np.ndarray) -> str:
        return self._transcribe_chunk(audio)

    def transcribe_segments(self, audio: np.ndarray) -> list[dict]:
        chunk_duration = 30
        chunk_size = 16000 * chunk_duration
        segments = []

        for start_idx in range(0, len(audio), chunk_size):
            chunk = audio[start_idx : start_idx + chunk_size]
            if len(chunk) < 1600:
                continue
            start_time = start_idx / 16000
            text = self._transcribe_chunk(chunk)
            if text:
                segments.append({
                    "start": start_time,
                    "end": start_time + len(chunk) / 16000,
                    "text": text,
                })

        return segments


@dataclass
class MlxAudioBackend:
    """Backend for models supported by mlx-audio (Qwen ASR, Parakeet, etc.)."""
    model_repo: str = DEFAULT_QWEN_MODEL
    name: str = "mlx_audio"

    def __post_init__(self):
        self._model = None

    def load(self) -> None:
        if self._model is not None:
            return
        from mlx_audio.stt import load

        self._model = load(self.model_repo)

    def _generate(self, audio: np.ndarray):
        self.load()
        return self._model.generate(audio)

    def transcribe(self, audio: np.ndarray) -> str:
        if audio.size == 0:
            return ""
        result = self._generate(audio)
        return str(getattr(result, "text", "")).strip()

    def transcribe_segments(self, audio: np.ndarray) -> list[dict]:
        if audio.size == 0:
            return []
        result = self._generate(audio)
        return _normalize_segments(getattr(result, "segments", []))


# Keep QwenBackend as alias for backward compat
QwenBackend = MlxAudioBackend


def create_backend(name: str, model_repo: str) -> SpeechBackend:
    if name == "whisper":
        return WhisperBackend(model_repo=model_repo)
    if name in ("qwen", "parakeet", "mlx_audio"):
        return MlxAudioBackend(model_repo=model_repo)
    raise ValueError(f"Unsupported STT backend: {name}")
