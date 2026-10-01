"""stt.py needs numpy (CI installs it explicitly, so a missing numpy must fail, not skip)."""
import io
import os
import sys
import unittest
import wave

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
import stt  # noqa: E402


def wav(samples: np.ndarray, rate: int, channels: int = 1, width: int = 2) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.writeframes(samples.tobytes())
    return buf.getvalue()


class FakeWhisper:
    def __init__(self, text="  dobar dan  ", language="bs"):
        self.calls, self.text, self.language = [], text, language

    def generate(self, audio, **kw):
        self.calls.append(kw)
        return type("Out", (), {"text": self.text, "language": self.language})()


class DecodeWavTest(unittest.TestCase):
    def test_16k_mono_passes_through(self):
        pcm = (np.sin(np.arange(16000) / 10) * 10000).astype("<i2")
        out = stt.decode_wav(wav(pcm, 16000))
        self.assertEqual(out.dtype, np.float32)
        self.assertEqual(len(out), 16000)
        self.assertAlmostEqual(float(out[100]), pcm[100] / 32768, places=4)

    def test_48k_stereo_becomes_16k_mono(self):
        pcm = np.zeros(48000 * 2, dtype="<i2")  # 1 s, interleaved stereo
        out = stt.decode_wav(wav(pcm, 48000, channels=2))
        self.assertEqual(len(out), 16000)

    def test_rejects_non_wav_8bit_and_overlong(self):
        with self.assertRaises(stt.BadAudio):
            stt.decode_wav(b"not a wav at all")
        with self.assertRaises(stt.BadAudio):
            stt.decode_wav(wav(np.zeros(100, dtype=np.uint8), 16000, width=1))
        with self.assertRaises(stt.BadAudio):
            stt.decode_wav(wav(np.zeros(16000 * (stt.MAX_AUDIO_S + 1), dtype="<i2"), 16000))


class TranscribeTest(unittest.TestCase):
    def test_strips_text_and_passes_the_language(self):
        model = FakeWhisper()
        out = stt.transcribe(model, np.zeros(16000, dtype=np.float32), "bs")
        self.assertEqual(out, {"text": "dobar dan", "language": "bs"})
        self.assertEqual(model.calls[0]["language"], "bs")

    def test_auto_lets_whisper_detect(self):
        model = FakeWhisper()
        stt.transcribe(model, np.zeros(16000, dtype=np.float32), "auto")
        self.assertIsNone(model.calls[0]["language"])

    def test_a_tap_with_no_speech_skips_the_model(self):
        model = FakeWhisper()
        self.assertEqual(stt.transcribe(model, np.zeros(1000, dtype=np.float32), "bs")["text"], "")
        self.assertEqual(model.calls, [])


if __name__ == "__main__":
    unittest.main()
