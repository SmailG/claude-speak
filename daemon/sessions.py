"""Which interactive Claude Code sessions are open, found by scanning processes.

A process scan, not SessionStart/SessionEnd hooks: /clear fires End then Start, an async SessionEnd
dies with its claude process, and kill -9 or closing a terminal tab skips it entirely.
"""

import os
import subprocess
import time
from dataclasses import dataclass
from typing import Callable

# Claude Code's own background processes, and headless runs, are not sessions someone is using.
NOT_A_SESSION = {"bg-pty-host", "--bg-pty-host", "bg-spare", "--bg-spare", "daemon", "-p", "--print"}
NPM_ENTRY = "@anthropic-ai/claude-code"


@dataclass(frozen=True)
class Session:
    pid: int
    tty: str


def _is_claude(args: list[str]) -> bool:
    return os.path.basename(args[0]) == "claude" or any(NPM_ENTRY in a for a in args[:2])


def parse_sessions(ps_output: str) -> list[Session]:
    """Sessions from `ps -axo pid=,tty=,args=` output: a claude process with a terminal."""
    sessions = []
    for line in ps_output.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or parts[1] in ("??", "-"):
            continue
        args = parts[2].split()
        if _is_claude(args) and not NOT_A_SESSION & set(args[1:]):
            sessions.append(Session(int(parts[0]), parts[1]))
    return sessions


def run_ps() -> str | None:
    try:
        return subprocess.run(["ps", "-axo", "pid=,tty=,args="], capture_output=True, text=True,
                              timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None


class SessionWatch:
    def __init__(self, scan: Callable[[], str | None] = run_ps, clock: Callable[[], float] = time.monotonic):
        self._scan, self._clock = scan, clock
        self.sessions: list[Session] = []
        self._empty_since: float | None = clock()

    def refresh(self) -> None:
        output = self._scan()
        if output is None:  # ps failed: keep the last known state rather than guess "none open"
            return
        self.sessions = parse_sessions(output)
        if self.sessions:
            self._empty_since = None
        elif self._empty_since is None:
            self._empty_since = self._clock()

    def none_for(self, seconds: float) -> bool:
        """True once no session has been open for `seconds` (a grace for /clear and restarts)."""
        return self._empty_since is not None and self._clock() - self._empty_since >= seconds
