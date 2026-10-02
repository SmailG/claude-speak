import importlib
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))


def load_settings(home: str):
    os.environ["VOICE_CONVERSATION_HOME"] = home
    import settings
    return importlib.reload(settings)


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.saved_home = os.environ.get("VOICE_CONVERSATION_HOME")
        self.home = tempfile.mkdtemp()
        self.s = load_settings(self.home)

    def tearDown(self):
        if self.saved_home is None:
            os.environ.pop("VOICE_CONVERSATION_HOME", None)
        else:
            os.environ["VOICE_CONVERSATION_HOME"] = self.saved_home

    def write(self, name: str, value: str):
        with open(os.path.join(self.home, name), "w", encoding="utf-8") as f:
            f.write(value)

    def test_defaults_without_files(self):
        self.assertEqual((self.s.char_limit(), self.s.speech_speed(), self.s.unload_minutes(),
                          self.s.stt_language()), (2000, 1.0, 10, "auto"))

    def test_values_are_read_and_clamped(self):
        self.write("speed", "1.9")
        self.write("unload_minutes", "99999")
        self.write("stt_lang", "bs\n")
        self.assertEqual(self.s.speech_speed(), 1.3)
        self.assertEqual(self.s.unload_minutes(), 1440)
        self.assertEqual(self.s.stt_language(), "bs")

    def test_garbage_falls_back_to_defaults(self):
        for name in ("max_chars", "speed", "unload_minutes", "stt_lang"):
            self.write(name, "garbage; rm -rf /")
        self.assertEqual((self.s.char_limit(), self.s.speech_speed(), self.s.unload_minutes(),
                          self.s.stt_language()), (2000, 1.0, 10, "auto"))


if __name__ == "__main__":
    unittest.main()
