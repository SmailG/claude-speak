"""Which Claude Code sessions are showing a menu right now (a permission prompt, a question, a plan
to approve). Voice input must not type into one: a transcript like "yes" or "2" would answer it.

Hooks report each session by its terminal (tty). A prompt opens on PermissionRequest (or PreToolUse
for the menu tools) and closes when that same tool call finishes. Stop and UserPromptSubmit close
everything for the session. A manual "No" fires neither, so the session stays guarded until the
next prompt is submitted: dictation then goes to the clipboard only, which is the safe direction.
"""

import json
import re
import threading
import time

OPEN_EVENTS = {"PermissionRequest"}
CLOSE_EVENTS = {"PostToolUse", "PostToolUseFailure"}
END_EVENTS = {"Stop", "UserPromptSubmit"}  # the turn ended or a new prompt was sent
MENU_TOOLS = {"AskUserQuestion", "ExitPlanMode"}  # their input gains the answer once answered
MAX_AGE_S = 30 * 60
TTY_RE = re.compile(r"^tty[a-z]*\d+$")


def is_tty(name: str | None) -> bool:
    return bool(name) and bool(TTY_RE.match(name))


def prompt_key(tool_name: str, tool_input) -> str:
    """PermissionRequest carries no tool_use_id, so a call is known by its name and input."""
    if tool_name in MENU_TOOLS:
        return tool_name
    return tool_name + json.dumps(tool_input, sort_keys=True, default=str)


class PromptGuard:
    def __init__(self, clock=time.monotonic):
        self._clock, self._lock = clock, threading.Lock()
        self._open: dict[str, dict[str, float]] = {}  # tty -> {prompt key: opened at}

    def event(self, tty: str, payload: dict) -> None:
        name, tool = payload.get("hook_event_name"), payload.get("tool_name") or ""
        key = prompt_key(tool, payload.get("tool_input"))
        with self._lock:
            if name in END_EVENTS:
                self._open.pop(tty, None)
            elif name in OPEN_EVENTS or (name == "PreToolUse" and tool in MENU_TOOLS):
                self._open.setdefault(tty, {})[key] = self._clock()
            elif name in CLOSE_EVENTS:
                self._open.get(tty, {}).pop(key, None)

    def clear(self, tty: str) -> None:
        with self._lock:
            self._open.pop(tty, None)

    def guarded(self) -> list[str]:
        cutoff = self._clock() - MAX_AGE_S
        with self._lock:
            for tty, prompts in list(self._open.items()):
                live = {k: t for k, t in prompts.items() if t > cutoff}
                if live:
                    self._open[tty] = live
                else:
                    del self._open[tty]
            return sorted(self._open)
