"""Which Claude Code sessions are showing a menu right now (a permission prompt, a question, a plan
to approve, an MCP form). Voice input must not type into one: a transcript like "yes" or "2" would
answer it.

Hooks report each session by its terminal (tty). A menu opens on PermissionRequest (PreToolUse for
the menu tools, Elicitation for MCP forms) and closes when that same call finishes. Stop and
UserPromptSubmit close everything for the session. Answering "No" or pressing Esc fires neither, so
the session stays guarded until the next prompt is submitted: dictation then goes to the clipboard
only, which is the safe direction. Nothing expires by age (a prompt can wait for hours); a session's
entries go only when it closes. The state is saved to a file so a daemon restart can't forget an
open prompt.
"""

import hashlib
import json
import os
import re
import threading

OPEN_EVENTS = {"PermissionRequest", "Elicitation"}
CLOSE_EVENTS = {"PostToolUse", "PostToolUseFailure", "ElicitationResult"}
END_EVENTS = {"Stop", "UserPromptSubmit"}  # the turn ended or a new prompt was sent
MENU_TOOLS = {"AskUserQuestion", "ExitPlanMode"}  # their input gains the answer once answered
TTY_RE = re.compile(r"tty[a-z]*\d+")


def is_tty(name) -> bool:
    return isinstance(name, str) and bool(TTY_RE.fullmatch(name))


def prompt_key(event: str, tool_name: str, tool_input) -> str:
    """PermissionRequest carries no tool_use_id, so a call is known by its name and input."""
    if event.startswith("Elicitation"):
        return "Elicitation"
    if tool_name in MENU_TOOLS:
        return tool_name
    body = json.dumps(tool_input, sort_keys=True, default=str)
    return tool_name + ":" + hashlib.sha256(body.encode()).hexdigest()[:16]


class PromptGuard:
    def __init__(self, path: str | None = None):
        self._path, self._lock = path, threading.Lock()
        self._open: dict[str, set[str]] = self._load()  # tty -> open prompt keys

    def event(self, tty: str, payload: dict) -> None:
        name, tool = payload.get("hook_event_name"), payload.get("tool_name") or ""
        if not isinstance(name, str) or not isinstance(tool, str):
            return
        key = prompt_key(name, tool, payload.get("tool_input"))
        with self._lock:
            before = {t: set(k) for t, k in self._open.items()}
            if name in END_EVENTS:
                self._open.pop(tty, None)
            elif name in OPEN_EVENTS or (name == "PreToolUse" and tool in MENU_TOOLS):
                self._open.setdefault(tty, set()).add(key)
            elif name in CLOSE_EVENTS:
                self._open.get(tty, set()).discard(key)
            self._open = {t: k for t, k in self._open.items() if k}
            if self._open != before:
                self._save()

    def clear(self, tty: str) -> None:
        with self._lock:
            if self._open.pop(tty, None) is not None:
                self._save()

    def guarded(self, open_ttys: list[str] | None = None) -> list[str]:
        """Sessions showing a menu; with open_ttys, entries of closed sessions are dropped."""
        with self._lock:
            if open_ttys is not None and set(self._open) - set(open_ttys):
                self._open = {t: k for t, k in self._open.items() if t in open_ttys}
                self._save()
            return sorted(self._open)

    def _load(self) -> dict[str, set[str]]:
        if not self._path:
            return {}
        try:
            with open(self._path, encoding="utf-8") as f:
                data = json.load(f)
            return {t: set(k) for t, k in data.items() if is_tty(t) and isinstance(k, list) and k}
        except (TypeError, OSError, ValueError, AttributeError):
            return {}

    def _save(self) -> None:
        if not self._path:
            return
        tmp = self._path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({t: sorted(k) for t, k in self._open.items()}, f)
            os.replace(tmp, self._path)
        except OSError as e:
            print(f"guard: could not save state: {e}", flush=True)
