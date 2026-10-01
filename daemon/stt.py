"""Local speech-to-text with Whisper large-v3-turbo (MLX). Load and run only on the MLX worker thread.

The mlx-community weights ship without a tokenizer, so `/speak setup input` assembles a folder:
config + weights linked from the Hugging Face cache, tokenizer files from openai/whisper-large-v3-turbo.
"""

import io
import os
import wave
from typing import Any

import numpy as np

WHISPER_RATE = 16000
MAX_AUDIO_S = 180  # a recording is capped at 2 min; reject anything far beyond that


class BadAudio(ValueError):
    pass


def model_dir(home: str) -> str:
    return os.path.join(home, "models", "whisper")


def is_installed(home: str) -> bool:
    return all(os.path.exists(os.path.join(model_dir(home), f))
               for f in ("config.json", "weights.safetensors", "tokenizer.json"))


def load(home: str) -> Any:
    if not is_installed(home):
        raise FileNotFoundError("voice input is not set up; run /speak setup input")
    from mlx_audio.stt.utils import load_model
    return load_model(model_dir(home))


def decode_wav(data: bytes) -> np.ndarray:
    """16-bit PCM WAV (any rate, mono or stereo) -> mono float32 at 16 kHz."""
    try:
        with wave.open(io.BytesIO(data)) as w:
            if w.getsampwidth() != 2:
                raise BadAudio("expected 16-bit PCM")
            rate, channels, frames = w.getframerate(), w.getnchannels(), w.readframes(w.getnframes())
    except (wave.Error, EOFError) as e:
        raise BadAudio(f"not a WAV file: {e}") from e
    if rate <= 0 or channels <= 0:
        raise BadAudio("invalid WAV header")
    samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    samples = samples[: len(samples) - len(samples) % channels].reshape(-1, channels).mean(axis=1)
    if len(samples) / rate > MAX_AUDIO_S:
        raise BadAudio(f"recording longer than {MAX_AUDIO_S} s")
    if rate != WHISPER_RATE and len(samples) > 1:
        n_out = int(round(len(samples) * WHISPER_RATE / rate))
        samples = np.interp(np.linspace(0, len(samples) - 1, n_out), np.arange(len(samples)), samples)
    return samples.astype(np.float32)


def transcribe(model: Any, audio: np.ndarray, language: str) -> dict:
    if len(audio) < WHISPER_RATE // 4:  # under 0.25 s: nothing was said
        return {"text": "", "language": None}
    result = model.generate(audio, language=None if language == "auto" else language,
                            verbose=False, condition_on_previous_text=False)
    return {"text": (result.text or "").strip(), "language": getattr(result, "language", None)}
