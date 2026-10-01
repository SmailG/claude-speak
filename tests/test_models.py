import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from models import ModelManager  # noqa: E402


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class Counting:
    def __init__(self):
        self.loads = {"en": 0, "bs": 0}
        self.releases = 0

    def loader(self, name):
        def load():
            self.loads[name] += 1
            return f"{name}-model-{self.loads[name]}"
        return load

    def release(self):
        self.releases += 1


def make(clock):
    c = Counting()
    m = ModelManager({"en": c.loader("en"), "bs": c.loader("bs")}, resident=("en",),
                     release=c.release, clock=clock)
    return m, c


class ModelManagerTest(unittest.TestCase):
    def test_loads_lazily_and_only_once(self):
        m, c = make(FakeClock())
        self.assertEqual(m.loaded(), {"en": False, "bs": False})
        m.get("bs"); m.get("bs")
        self.assertEqual(c.loads["bs"], 1)
        self.assertEqual(m.loaded(), {"en": False, "bs": True})

    def test_idle_model_unloads_after_the_limit(self):
        clock = FakeClock()
        m, c = make(clock)
        m.get("bs")
        clock.now += 599
        self.assertEqual(m.sweep(600, no_sessions=False), [])
        clock.now += 2
        self.assertEqual(m.sweep(600, no_sessions=False), ["bs"])
        self.assertFalse(m.loaded()["bs"])
        self.assertEqual(c.releases, 1)

    def test_use_resets_the_idle_timer(self):
        clock = FakeClock()
        m, _ = make(clock)
        m.get("bs")
        clock.now += 500
        m.get("bs")
        clock.now += 500
        self.assertEqual(m.sweep(600, no_sessions=False), [])

    def test_zero_minutes_keeps_it_loaded_while_sessions_are_open(self):
        clock = FakeClock()
        m, _ = make(clock)
        m.get("bs")
        clock.now += 86_400
        self.assertEqual(m.sweep(0, no_sessions=False), [])

    def test_no_sessions_unloads_even_with_zero_minutes(self):
        m, _ = make(FakeClock())
        m.get("bs")
        self.assertEqual(m.sweep(0, no_sessions=True), ["bs"])

    def test_resident_model_never_unloads(self):
        clock = FakeClock()
        m, c = make(clock)
        m.get("en")
        clock.now += 86_400
        self.assertEqual(m.sweep(60, no_sessions=True), [])
        self.assertEqual(c.releases, 0)  # nothing dropped, nothing to release

    def test_reloads_after_unload(self):
        m, c = make(FakeClock())
        m.get("bs")
        m.sweep(0, no_sessions=True)
        self.assertEqual(m.get("bs"), "bs-model-2")
        self.assertEqual(c.loads["bs"], 2)


if __name__ == "__main__":
    unittest.main()
