"""Which voice models are in memory: residents stay loaded, the rest load on use and unload when idle.

Pure bookkeeping (loaders, release and clock are injected) so the rules are unit-testable. All calls
must come from the MLX worker thread: MLX GPU streams are thread-local.
"""

import time
from typing import Any, Callable


class ModelManager:
    def __init__(self, loaders: dict[str, Callable[[], Any]], resident: tuple[str, ...] = (),
                 release: Callable[[], None] = lambda: None,
                 clock: Callable[[], float] = time.monotonic):
        self._loaders, self._resident = loaders, set(resident)
        self._release, self._clock = release, clock
        self._models: dict[str, Any] = {}
        self._last_used: dict[str, float] = {}

    def get(self, name: str) -> Any:
        """The model, loading it first if needed; every call counts as use."""
        if name not in self._models:
            started = self._clock()
            self._models[name] = self._loaders[name]()
            print(f"loaded {name} in {self._clock() - started:.1f}s", flush=True)
        self._last_used[name] = self._clock()
        return self._models[name]

    def loaded(self) -> dict[str, bool]:
        return {name: name in self._models for name in self._loaders}

    def sweep(self, idle_limit_s: float, no_sessions: bool) -> list[str]:
        """Unload non-resident models idle longer than idle_limit_s (0 = never), or all of them when
        no Claude Code session is open. Returns the names unloaded."""
        now = self._clock()
        doomed = [name for name in self._models if name not in self._resident and (
            no_sessions or (idle_limit_s > 0 and now - self._last_used[name] > idle_limit_s))]
        for name in doomed:
            del self._models[name]
            del self._last_used[name]
            reason = "no sessions" if no_sessions else f"idle {idle_limit_s / 60:g} min"
            print(f"unloaded {name} ({reason})", flush=True)
        if doomed:
            self._release()
        return doomed
