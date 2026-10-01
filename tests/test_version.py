import json
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")


class VersionsInSync(unittest.TestCase):
    """`claude plugin update` only updates when plugin.json's version changes, and /health
    reports the daemon's own VERSION, so both must be bumped together."""

    def test_daemon_version_matches_plugin_json(self):
        with open(os.path.join(ROOT, ".claude-plugin", "plugin.json")) as f:
            plugin_version = json.load(f)["version"]
        with open(os.path.join(ROOT, "daemon", "speakd.py")) as f:
            daemon_version = re.search(r'NAME, VERSION = "claude-speak", "([^"]+)"', f.read()).group(1)
        self.assertEqual(daemon_version, plugin_version)


if __name__ == "__main__":
    unittest.main()
