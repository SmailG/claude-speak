import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from sessions import Session, SessionWatch, parse_sessions  # noqa: E402

# Shape of `ps -axo pid=,tty=,args=` on a Mac running Claude Code 2.1 (session ids made up).
PS = """\
  101 ??       /Users/u/.local/bin/claude daemon run
  102 ??       claude bg-pty-host --bg-pty-host
  103 ??       claude bg-spare --bg-spare
  104 ttys011  claude bg-spare --bg-spare
  105 ttys009  claude --resume 00000000-1111-2222-3333-444444444444
  106 ttys014  claude --dangerously-skip-permissions
  107 ttys020  claude -p summarize this
  108 ttys021  /usr/bin/python3 -m claude_tools
  109 ttys022  node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js
  110 ttys023  vim claude.md
  111 ttys024  claude --print hello
  112 ??       claude --resume 55555555-6666-7777-8888-999999999999
"""


class ParseSessionsTest(unittest.TestCase):
    def test_finds_interactive_sessions_only(self):
        self.assertEqual(parse_sessions(PS), [Session(105, "ttys009"), Session(106, "ttys014"),
                                              Session(109, "ttys022")])

    def test_claude_without_a_terminal_is_not_a_session(self):
        self.assertNotIn(112, [s.pid for s in parse_sessions(PS)])

    def test_background_helpers_with_a_tty_are_not_sessions(self):
        self.assertNotIn("ttys011", [s.tty for s in parse_sessions(PS)])

    def test_empty_and_garbage_output(self):
        self.assertEqual(parse_sessions(""), [])
        self.assertEqual(parse_sessions("not ps output\n\n  x y"), [])


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class SessionWatchTest(unittest.TestCase):
    def setUp(self):
        self.clock, self.output = FakeClock(), PS
        self.watch = SessionWatch(scan=lambda: self.output, clock=self.clock)

    def test_open_sessions_are_never_none_for(self):
        self.watch.refresh()
        self.clock.now += 3600
        self.assertFalse(self.watch.none_for(60))

    def test_grace_period_after_the_last_session_closes(self):
        self.watch.refresh()
        self.output = ""
        self.watch.refresh()
        self.clock.now += 59
        self.assertFalse(self.watch.none_for(60))  # /clear or a restart: not yet
        self.clock.now += 1
        self.assertTrue(self.watch.none_for(60))

    def test_rescans_during_the_grace_do_not_restart_it(self):
        self.output = ""
        self.watch.refresh()
        self.clock.now += 30
        self.watch.refresh()  # housekeeping scans every 30 s
        self.clock.now += 30
        self.assertTrue(self.watch.none_for(60))

    def test_a_returning_session_resets_the_grace(self):
        self.output = ""
        self.watch.refresh()
        self.clock.now += 30
        self.output = PS
        self.watch.refresh()
        self.output = ""
        self.watch.refresh()
        self.clock.now += 59
        self.assertFalse(self.watch.none_for(60))

    def test_failed_scan_keeps_the_last_known_sessions(self):
        self.watch.refresh()
        self.output = None
        self.watch.refresh()
        self.clock.now += 3600
        self.assertEqual(len(self.watch.sessions), 3)
        self.assertFalse(self.watch.none_for(60))


if __name__ == "__main__":
    unittest.main()
