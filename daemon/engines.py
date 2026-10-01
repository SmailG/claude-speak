"""Loading and running the two TTS engines (MLX). Call only from the MLX worker thread."""

import gc
import os
from dataclasses import dataclass
from typing import Any, Iterator

import numpy as np

EN_MODEL, EN_VOICE, EN_LANG = "mlx-community/Kokoro-82M-bf16", "af_heart", "a"
BS_MODEL, BS_LANG = "mlx-community/OmniVoice-bfloat16", "bs"
OMNI_TOKENS_PER_SEC = 25


@dataclass
class ClonedVoice:
    model: Any
    ref_tokens: Any
    ref_text: str
    estimator: Any


def load_en() -> Any:
    from mlx_audio.tts.utils import load_model
    return load_model(EN_MODEL)


def load_bs(voices_dir: str) -> ClonedVoice:
    from mlx_audio.tts.utils import load_model
    from mlx_audio.tts.models.omnivoice.utils import create_voice_clone_prompt
    from mlx_audio.tts.models.omnivoice.duration import RuleDurationEstimator

    model = load_model(BS_MODEL)
    ref = create_voice_clone_prompt(os.path.join(voices_dir, "voice_bs.wav"),
                                    tokenizer=model.audio_tokenizer, max_duration_s=10.0)
    with open(os.path.join(voices_dir, "voice_bs.txt"), encoding="utf-8") as f:
        ref_text = f.read().strip()
    # Pace speech from the reference clip, as upstream OmniVoice does; the MLX port
    # otherwise assumes "Nice to meet you." = 1 s and pads the estimate by 15%.
    return ClonedVoice(model, ref, ref_text, RuleDurationEstimator())


def synth_en(model: Any, chunk: str, speed: float) -> Iterator[tuple[np.ndarray, int]]:
    """Both engines speed up natively (no resampling, so pitch is unchanged)."""
    for r in model.generate(text=chunk, voice=EN_VOICE, lang_code=EN_LANG, speed=speed):
        yield np.array(r.audio, dtype=np.float32), r.sample_rate


def synth_bs(voice: ClonedVoice, chunk: str, speed: float) -> Iterator[tuple[np.ndarray, int]]:
    tokens = voice.estimator.estimate_duration(chunk, voice.ref_text, voice.ref_tokens.shape[0])
    results = voice.model.generate(text=chunk, lang_code=BS_LANG, ref_tokens=voice.ref_tokens,
                                   ref_text=voice.ref_text,
                                   duration_s=max(1, int(tokens)) / OMNI_TOKENS_PER_SEC / speed)
    for r in results:
        yield np.array(r.audio, dtype=np.float32), r.sample_rate


def clear_cache() -> None:
    """Return MLX's scratch buffers (~3.6 GB after an OmniVoice reply) to the system."""
    import mlx.core as mx
    mx.clear_cache()


def release() -> None:
    """After dropping a model: collect it and return its GPU memory."""
    gc.collect()
    clear_cache()
