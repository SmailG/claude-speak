import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from guard import PromptGuard, is_tty  # noqa: E402

TTY = "ttys009"


def ev(name, tool="Bash", tool_input=None):
    return {"hook_event_name": name, "tool_name": tool,
            "tool_input": {"command": "rm -r build"} if tool_input is None else tool_input}


class PromptGuardTest(unittest.TestCase):
    def setUp(self):
        self.g = PromptGuard()

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

    def test_mcp_form_guards_until_answered(self):
        self.g.event(TTY, {"hook_event_name": "Elicitation", "mcp_server_name": "x"})
        self.assertEqual(self.g.guarded(), [TTY])
        self.g.event(TTY, {"hook_event_name": "ElicitationResult", "mcp_server_name": "x"})
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

    def test_an_old_prompt_stays_guarded_while_its_session_is_open(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.assertEqual(self.g.guarded(open_ttys=[TTY, "ttys010"]), [TTY])

    def test_a_closed_session_drops_its_prompts(self):
        self.g.event(TTY, ev("PermissionRequest"))
        self.assertEqual(self.g.guarded(open_ttys=["ttys010"]), [])

    def test_malformed_events_are_ignored(self):
        self.g.event(TTY, {"hook_event_name": ["PermissionRequest"], "tool_name": "Bash"})
        self.g.event(TTY, {"hook_event_name": "PermissionRequest", "tool_name": {"x": 1}})
        self.assertEqual(self.g.guarded(), [])

    def test_open_prompts_survive_a_restart(self):
        path = os.path.join(tempfile.mkdtemp(), "guard.json")
        PromptGuard(path).event(TTY, ev("PermissionRequest"))
        restarted = PromptGuard(path)
        self.assertEqual(restarted.guarded(), [TTY])
        restarted.event(TTY, ev("PostToolUse"))
        self.assertEqual(PromptGuard(path).guarded(), [])

    def test_a_corrupt_state_file_starts_empty(self):
        path = os.path.join(tempfile.mkdtemp(), "guard.json")
        with open(path, "w") as f:
            f.write("{not json")
        self.assertEqual(PromptGuard(path).guarded(), [])


class IsTtyTest(unittest.TestCase):
    def test_accepts_terminal_names_only(self):
        self.assertTrue(is_tty("ttys009"))
        for bad in ("", None, "??", "ttys009\n", "ttys009; rm", "../ttys1", "console", 7):
            self.assertFalse(is_tty(bad), repr(bad))


if __name__ == "__main__":
    unittest.main()
