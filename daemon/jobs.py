"""Speech jobs: per-session replacement, cross-session queueing, per-job cancellation.

Rules:
  - a new reply from a session cancels that session's queued/playing jobs (it replaces them)
  - a reply from another session waits its turn (FIFO) instead of interrupting
  - a stop from a session cancels only that session's jobs; stop-all cancels everything
  - jobs that waited longer than MAX_QUEUE_AGE_S are dropped (busy sessions can't stack speech);
    checked both before generation and when a job's audio reaches the front of the player
  - a generated job stays cancellable until its audio has had time to play (generation is
    usually far faster than playback, so "done generating" is not "done speaking")

Cancelled job ids live in a small ring in shared memory so the player process can see them.
"""

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

MAX_QUEUE_AGE_S = 180
RING_SIZE = 64
PLAY_SLACK_S = 5.0  # margin on the playback-end estimate; over-cancelling a finished job is harmless


class CancelRing:
    """Last RING_SIZE cancelled job ids, in shared memory (readable from the player process)."""

    def __init__(self, ids: Any, cursor: Any):
        self.ids, self.cursor = ids, cursor

    @classmethod
    def create(cls, ctx: Any) -> "CancelRing":
        return cls(ctx.Array("q", RING_SIZE), ctx.Value("q", 0))

    def add(self, job_id: int) -> None:
        with self.cursor.get_lock():
            self.ids[self.cursor.value % RING_SIZE] = job_id
            self.cursor.value += 1

    def __contains__(self, job_id: int) -> bool:
        return job_id in self.ids[:]  # ids start at 1; 0 marks an empty slot


class StaleFilter:
    """Player side of the age limit: generation outruns playback, so the backlog waits there.

    A job is judged once, when its first audio reaches the front; a reply that started playing
    always finishes.
    """

    def __init__(self, clock: Callable[[], float] = time.monotonic, max_age_s: float = MAX_QUEUE_AGE_S):
        self.clock, self.max_age_s = clock, max_age_s
        self._current: int | None = None
        self._stale = False

    def is_stale(self, job_id: int, queued_at: float) -> bool:
        if job_id != self._current:
            self._current = job_id
            self._stale = self.clock() - queued_at > self.max_age_s
        return self._stale


@dataclass
class Job:
    id: int
    text: str
    session: str | None
    queued_at: float = field(default_factory=time.monotonic)


class JobBoard:
    def __init__(self, ring: CancelRing, clock: Callable[[], float] = time.monotonic,
                 max_age_s: float = MAX_QUEUE_AGE_S):
        self.ring, self.clock, self.max_age_s = ring, clock, max_age_s
        self._cond = threading.Condition()
        self._queue: deque[Job] = deque()
        self._live: dict[int, Job] = {}  # queued, generating, or generated but maybe still playing
        self._plays_until: dict[int, float] = {}  # generated job id -> estimated end of its audio
        self._player_busy_until = 0.0
        self._next_id = 1

    def submit(self, text: str, session: str | None) -> Job:
        with self._cond:
            if session is not None:
                self._cancel_where(lambda j: j.session == session)
            job = Job(self._next_id, text, session, self.clock())
            self._next_id += 1
            self._queue.append(job)
            self._live[job.id] = job
            self._cond.notify()
            return job

    def cancel_session(self, session: str) -> int:
        with self._cond:
            return self._cancel_where(lambda j: j.session == session)

    def cancel_all(self) -> int:
        with self._cond:
            return self._cancel_where(lambda j: True)

    def next_job(self, timeout: float | None = None) -> Job | None:
        """Block until a live, fresh job is queued; stale ones are cancelled and skipped."""
        with self._cond:
            deadline = None if timeout is None else self.clock() + timeout
            while True:
                while self._queue:
                    job = self._queue.popleft()
                    if job.id in self.ring:
                        continue
                    if self.clock() - job.queued_at > self.max_age_s:
                        self._cancel_where(lambda j: j.id == job.id)
                        continue
                    return job
                remaining = None if deadline is None else deadline - self.clock()
                if remaining is not None and remaining <= 0:
                    return None
                self._cond.wait(remaining)

    def is_cancelled(self, job: Job) -> bool:
        return job.id in self.ring

    def finish(self, job: Job, audio_s: float = 0.0) -> None:
        """Generation is done; keep the job cancellable while its audio may still be playing."""
        with self._cond:
            if job.id not in self._live:
                return
            self._player_busy_until = max(self._player_busy_until, self.clock()) + audio_s
            self._plays_until[job.id] = self._player_busy_until + PLAY_SLACK_S

    def _cancel_where(self, pred: Callable[[Job], bool]) -> int:
        self._forget_played()
        doomed = [j for j in self._live.values() if pred(j)]
        for j in doomed:
            self.ring.add(j.id)
            del self._live[j.id]
            self._plays_until.pop(j.id, None)
        self._queue = deque(j for j in self._queue if j.id in self._live)
        return len(doomed)

    def _forget_played(self) -> None:
        now = self.clock()
        for job_id in [i for i, until in self._plays_until.items() if until < now]:
            del self._plays_until[job_id]
            self._live.pop(job_id, None)
