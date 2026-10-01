import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from guard import MAX_AGE_S, PromptGuard, is_tty  # noqa: E402

TTY = "ttys009"


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def ev(name, tool="Bash", tool_input=None):
    return {"hook_event_name": name, "tool_name": tool,
            "tool_input": {"command": "rm -r build"} if tool_input is None else tool_input}


class PromptGuardTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.g = PromptGuard(clock=self.clock)

    def test_permission_prompt_guards_until_that_call_finishes(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.assertEqual(self.g.guarded(), [TTY])
        self.g.event(TTY, ev("PostToolUse"))
        self.assertEqual(self.g.guarded(), [])

    def test_a_different_call_finishing_keeps_the_prompt_guarded(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.g.event(TTY, ev("PostToolUse", tool_input={"command": "ls"}))
        self.assertEqual(self.g.guarded(), [TTY])

    def test_failed_call_closes_its_prompt(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.g.event(TTY, ev("PostToolUseFailure"))
        self.assertEqual(self.g.guarded(), [])

    def test_question_menu_closes_although_its_input_gained_answers(self):
        q = {"questions": [{"question": "Which?"}]}
        self.g.event(TTY, ev("PreToolUse", "AskUserQuestion", q))
        self.assertEqual(self.g.guarded(), [TTY])
        self.g.event(TTY, ev("PostToolUse", "AskUserQuestion", {**q, "answers": {"Which?": "A"}}))
        self.assertEqual(self.g.guarded(), [])

    def test_pretooluse_of_an_ordinary_tool_is_not_a_prompt(self):
        self.g.event(TTY, ev("PreToolUse"))
        self.assertEqual(self.g.guarded(), [])

    def test_clear_closes_every_prompt_of_that_session_only(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.g.event("ttys010", ev("PermissionRequest"))
        self.g.clear(TTY)
        self.assertEqual(self.g.guarded(), ["ttys010"])

    def test_end_of_turn_closes_the_session_prompts(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.g.event(TTY, {"hook_event_name": "Stop"})
        self.assertEqual(self.g.guarded(), [])

    def test_a_forgotten_prompt_expires(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.clock.now += MAX_AGE_S - 1
        self.assertEqual(self.g.guarded(), [TTY])
        self.clock.now += 2
        self.assertEqual(self.g.guarded(), [])


class IsTtyTest(unittest.TestCase):
    def test_accepts_terminal_names_only(self):
        self.assertTrue(is_tty("ttys009"))
        for bad in ("", None, "??", "ttys009; rm", "../ttys1", "console"):
            self.assertFalse(is_tty(bad), bad)


if __name__ == "__main__":
    unittest.main()
