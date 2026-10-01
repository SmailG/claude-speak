"""Audio playback in its own process, so MLX generation in speakd can't starve the output.

MLX generation holds the GIL for long stretches. In-process playback stuttered (sounddevice's
callback needs the GIL and built-in speakers buffer only ~27 ms), and a multiprocessing Queue
was no better: its feeder thread also waits on the GIL, delaying first audio by seconds. So the
generator writes to a Pipe synchronously, and all playback work (a reader thread plus blocking
writes with a larger buffer) lives in this child process with its own GIL.
"""

import queue
import threading
import time
from typing import Any

from jobs import CancelRing, StaleFilter

BUFFER_S = 0.25   # PortAudio output latency; absorbs scheduling hiccups
BLOCK_S = 0.1     # write granularity, also the cancel reaction time


def _reader(conn: Any, local: queue.Queue) -> None:
    while True:
        local.put(conn.recv())


def player_main(conn: Any, ring_ids: Any, ring_cursor: Any) -> None:
    """Child process: play (job_id, audio, sr, t0, queued_at) items; skip cancelled or stale jobs."""
    import numpy as np
    import sounddevice as sd

    ring = CancelRing(ring_ids, ring_cursor)
    local: queue.Queue = queue.Queue()
    threading.Thread(target=_reader, args=(conn, local), daemon=True).start()
    stale = StaleFilter()
    stream, stream_sr = None, None
    while True:
        job_id, audio, sr, t0, queued_at = local.get()
        if stale.is_stale(job_id, queued_at):
            if t0 is not None:
                print(f"dropped a reply that waited {time.monotonic() - queued_at:.0f}s", flush=True)
            continue
        if job_id in ring:
            if stream is not None and stream.active and local.empty():
                stream.stop()  # release the device; don't leave it open playing silence
            continue
        if stream is None or sr != stream_sr:
            if stream is not None:
                stream.close()
            stream = sd.OutputStream(samplerate=sr, channels=1, dtype="float32", latency=BUFFER_S)
            stream_sr = sr
        if not stream.active:
            stream.start()
        if t0 is not None:
            print(f"first audio after {time.monotonic() - t0:.2f}s", flush=True)
        block = int(BLOCK_S * sr)
        samples = np.ascontiguousarray(audio, dtype=np.float32).reshape(-1, 1)
        for i in range(0, len(samples), block):
            if job_id in ring:
                stream.abort()  # drop buffered audio immediately
                break
            stream.write(samples[i:i + block])
        if local.empty() and stream.active:
            stream.stop()  # drains the buffer, then releases the device between replies


class Player:
    """Parent-side handle. send() pickles and writes in the calling thread (no feeder thread)."""

    def __init__(self, ring: CancelRing, ctx: Any):
        recv_end, self._send_end = ctx.Pipe(duplex=False)
        ctx.Process(target=player_main, args=(recv_end, ring.ids, ring.cursor), daemon=True).start()
        self._lock = threading.Lock()

    def send(self, item: tuple) -> None:
        with self._lock:
            self._send_end.send(item)
