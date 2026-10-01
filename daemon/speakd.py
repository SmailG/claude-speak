"""claude-speak daemon: speaks Claude Code replies locally.

Keeps Kokoro (English) and OmniVoice (Bosnian/Croatian/Serbian, cloned voice) resident.
  POST /speak   Stop-hook JSON payload (last_assistant_message, session_id)
  POST /stop    UserPromptSubmit payload (session_id, prompt); empty body = stop everything
  GET  /health  {"name", "version", "home", "ready"}; 200 when ready, 503 while loading

State lives in CLAUDE_SPEAK_HOME (the plugin's data dir): voices/, off, max_chars, speed,
unload_minutes, speakd.log. Kokoro (English) stays loaded; OmniVoice (Bosnian) loads on first use and
unloads when idle or once no Claude Code session is open.
"""

import json
import multiprocessing as mp
import os
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import engines
from jobs import CancelRing, Job, JobBoard, queue_age_limit
from models import ModelManager
from sessions import SessionWatch
from player import Player
from text import CONTROL_MARKER, MERGE_TO, is_bosnian, parse_payload, prepare, split_chunks

NAME, VERSION = "claude-speak", "0.3.0"
HOST, PORT = "127.0.0.1", int(os.environ.get("CLAUDE_SPEAK_PORT", "8765"))
HOME = os.environ.get("CLAUDE_SPEAK_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_CHARS = int(os.environ.get("CLAUDE_SPEAK_MAX_CHARS", "2000"))
LIMIT_FILE = os.path.join(HOME, "max_chars")  # written by `/speak limit N`; 0 = no limit
SPEED_FILE = os.path.join(HOME, "speed")      # written by `/speak speed X`
# Above 1.3 OmniVoice (Bosnian) stops outrunning playback, so speech stalls between chunks,
# and at 1.5 its words get garbled (Whisper WER 6-30%). One range for both languages.
MIN_SPEED, MAX_SPEED = 1.0, 1.3  # keep in sync with SPEED_RE in scripts/speakctl.sh
LOG_PATH, LOG_MAX_BYTES = os.path.join(HOME, "speakd.log"), 512 * 1024

VOICES_DIR = os.path.join(HOME, "voices")
UNLOAD_FILE = os.path.join(HOME, "unload_minutes")  # written by `/speak unload N`; 0 = keep loaded
DEFAULT_UNLOAD_MIN, MAX_UNLOAD_MIN = 10, 1440
HOUSEKEEPING_EVERY_S = 30  # session scan + idle sweep
NO_SESSION_GRACE_S = 60    # /clear and restarts briefly show zero sessions


def short(session: str | None) -> str:
    return (session or "?")[:8]


def char_limit() -> int:
    """Per-reply limit: the /speak override file if valid, else MAX_CHARS."""
    try:
        with open(LIMIT_FILE, encoding="utf-8") as f:
            return max(0, int(f.read().strip()))
    except (OSError, ValueError):
        return MAX_CHARS


def speech_speed() -> float:
    """Speaking-rate multiplier from the /speak speed file, clamped; 1.0 if missing or invalid."""
    try:
        with open(SPEED_FILE, encoding="utf-8") as f:
            return min(MAX_SPEED, max(MIN_SPEED, float(f.read().strip())))
    except (OSError, ValueError):
        return MIN_SPEED


def unload_minutes() -> int:
    """Idle minutes before the Bosnian voice unloads (0 = never while a session is open)."""
    try:
        with open(UNLOAD_FILE, encoding="utf-8") as f:
            return min(MAX_UNLOAD_MIN, max(0, int(f.read().strip())))
    except (OSError, ValueError):
        return DEFAULT_UNLOAD_MIN


def trim_log() -> None:
    """Keep the log bounded; launchd opens it O_APPEND, so truncating in place is safe."""
    try:
        if os.path.getsize(LOG_PATH) > LOG_MAX_BYTES:
            os.truncate(LOG_PATH, 0)
    except OSError:
        pass


class Speaker:
    """One MLX worker thread loads models and generates; a player process plays.

    MLX GPU streams are thread-local, so models must load in the thread that runs them.
    """

    def __init__(self):
        ctx = mp.get_context("spawn")
        ring = CancelRing.create(ctx)
        self.board = JobBoard(ring)
        self.player = Player(ring, ctx)
        self.models = ModelManager({"en": engines.load_en, "bs": lambda: engines.load_bs(VOICES_DIR)},
                                   resident=("en",), release=engines.release)
        self.sessions = SessionWatch()
        self._next_housekeeping = 0.0
        self.ready = threading.Event()
        threading.Thread(target=self._generate_loop, daemon=True).start()

    def speak(self, text: str, session: str | None) -> None:
        if not text:  # e.g. a turn that ended on a tool call: never cancel for nothing
            print(f"ignored empty reply from session {short(session)}", flush=True)
            return
        if text.startswith(CONTROL_MARKER):  # Claude echoing /speak output: don't cut a replay
            return
        self.board.submit(text, session, queue_age_limit(char_limit()))

    def stop_from(self, session: str | None, prompt: str = "") -> None:
        """A prompt only silences its own session; typing /speak never stops (it may be replaying)."""
        if prompt.lstrip().startswith("/speak"):
            return
        n = self.board.cancel_session(session) if session else self.board.cancel_all()
        if n:
            print(f"stop: session={short(session) if session else 'all'} cancelled={n}", flush=True)

    def _load(self) -> None:
        list(self._synth("Ready.", False, MIN_SPEED))  # loads and warms up Kokoro
        self.ready.set()
        print(f"{NAME} {VERSION}: English voice loaded, Bosnian loads on first use (home {HOME})", flush=True)

    def _synth(self, chunk: str, bosnian: bool, speed: float):
        if bosnian:
            return engines.synth_bs(self.models.get("bs"), chunk, speed)
        return engines.synth_en(self.models.get("en"), chunk, speed)

    def _generate_loop(self) -> None:
        try:
            self._load()
        except Exception:  # never sit "loading" forever: exit so launchd logs it and retries
            traceback.print_exc()
            print(f"{NAME}: model load failed; exiting (re-run /speak setup)", flush=True)
            os._exit(1)
        while True:
            self._housekeeping()
            job = self.board.next_job(timeout=HOUSEKEEPING_EVERY_S)
            if job is None:
                continue
            audio_s = 0.0
            try:
                audio_s = self._speak_job(job)
            finally:
                self.board.finish(job, audio_s)
                engines.clear_cache()

    def _housekeeping(self) -> None:
        """Every HOUSEKEEPING_EVERY_S: rescan sessions, unload idle models (MLX thread only)."""
        now = time.monotonic()
        if now < self._next_housekeeping:
            return
        self._next_housekeeping = now + HOUSEKEEPING_EVERY_S
        self.sessions.refresh()
        self.models.sweep(unload_minutes() * 60, self.sessions.none_for(NO_SESSION_GRACE_S))

    def _speak_job(self, job: Job) -> float:
        """Generate one job's audio into the player; returns seconds of audio sent."""
        text = prepare(job.text, char_limit())
        bosnian = is_bosnian(text)
        speed = speech_speed()
        trim_log()
        print(f"reply: session={short(job.session)} engine={'omnivoice/bs' if bosnian else 'kokoro/en'} "
              f"chars={len(text)} speed={speed:g} waited={time.monotonic() - job.queued_at:.1f}s", flush=True)
        chunks = split_chunks(text, MERGE_TO["bs" if bosnian else "en"])
        started = time.monotonic()
        synth_s = audio_s = 0.0
        for chunk in chunks:
            if self.board.is_cancelled(job):
                break
            chunk_t0 = time.monotonic()
            try:
                for audio, sr in self._synth(chunk, bosnian, speed):
                    self.player.send((job.id, audio, sr, started if audio_s == 0 else None, job.expires_at))
                    audio_s += len(audio) / sr
            except Exception as e:  # keep the daemon alive on a bad chunk
                print(f"synth error: {e!r} on {chunk[:60]!r}", flush=True)
            synth_s += time.monotonic() - chunk_t0
        print(f"reply done: chunks={len(chunks)} audio={audio_s:.1f}s synth={synth_s:.1f}s", flush=True)
        return audio_s


def make_handler(speaker: Speaker):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
            text, session, prompt = parse_payload(body)
            if self.path == "/speak":
                speaker.speak(text.strip(), session)
            elif self.path == "/stop":
                speaker.stop_from(session, prompt)
            else:
                return self._reply(404)
            self._reply(204)

        def do_GET(self):
            if self.path != "/health":
                return self._reply(404)
            ready = speaker.ready.is_set()
            body = json.dumps({"name": NAME, "version": VERSION, "home": HOME, "ready": ready,
                               "models": speaker.models.loaded(), "unload_minutes": unload_minutes(),
                               "sessions": [x.tty for x in speaker.sessions.sessions]}).encode()
            self._reply(200 if ready else 503, body)

        def _reply(self, code: int, body: bytes = b""):
            self.send_response(code)
            if body:
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def log_message(self, format, *args):  # silence per-request logging
            pass

    return Handler


if __name__ == "__main__":
    speaker = Speaker()
    print(f"{NAME} {VERSION} listening on {HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), make_handler(speaker)).serve_forever()
