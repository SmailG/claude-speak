"""claude-speak daemon: speaks Claude Code replies locally.

Keeps Kokoro (English) and OmniVoice (Bosnian/Croatian/Serbian, cloned voice) resident.
  POST /speak   Stop-hook JSON payload (last_assistant_message, session_id)
  POST /stop    UserPromptSubmit payload (session_id, prompt); empty body = stop everything
  GET  /health  {"name", "version", "home", "ready"}; 200 when ready, 503 while loading

State lives in CLAUDE_SPEAK_HOME (the plugin's data dir): voices/, off, max_chars, speakd.log.
"""

import json
import multiprocessing as mp
import os
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

from jobs import CancelRing, Job, JobBoard
from player import Player
from text import CONTROL_MARKER, MERGE_TO, is_bosnian, parse_payload, prepare, split_chunks

NAME, VERSION = "claude-speak", "0.1.0"
HOST, PORT = "127.0.0.1", int(os.environ.get("CLAUDE_SPEAK_PORT", "8765"))
HOME = os.environ.get("CLAUDE_SPEAK_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_CHARS = int(os.environ.get("CLAUDE_SPEAK_MAX_CHARS", "2000"))
LIMIT_FILE = os.path.join(HOME, "max_chars")  # written by `/speak limit N`; 0 = no limit
LOG_PATH, LOG_MAX_BYTES = os.path.join(HOME, "speakd.log"), 512 * 1024

EN_MODEL, EN_VOICE, EN_LANG = "mlx-community/Kokoro-82M-bf16", "af_heart", "a"
BS_MODEL, BS_LANG = "mlx-community/OmniVoice-bfloat16", "bs"
BS_REF_WAV = os.path.join(HOME, "voices", "voice_bs.wav")
BS_REF_TXT = os.path.join(HOME, "voices", "voice_bs.txt")
OMNI_TOKENS_PER_SEC = 25


def short(session: str | None) -> str:
    return (session or "?")[:8]


def char_limit() -> int:
    """Per-reply limit: the /speak override file if valid, else MAX_CHARS."""
    try:
        with open(LIMIT_FILE, encoding="utf-8") as f:
            return max(0, int(f.read().strip()))
    except (OSError, ValueError):
        return MAX_CHARS


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
        self.ready = threading.Event()
        threading.Thread(target=self._generate_loop, daemon=True).start()

    def speak(self, text: str, session: str | None) -> None:
        if not text:  # e.g. a turn that ended on a tool call: never cancel for nothing
            print(f"ignored empty reply from session {short(session)}", flush=True)
            return
        if text.startswith(CONTROL_MARKER):  # Claude echoing /speak output: don't cut a replay
            return
        self.board.submit(text, session)

    def stop_from(self, session: str | None, prompt: str = "") -> None:
        """A prompt only silences its own session; typing /speak never stops (it may be replaying)."""
        if prompt.lstrip().startswith("/speak"):
            return
        n = self.board.cancel_session(session) if session else self.board.cancel_all()
        if n:
            print(f"stop: session={short(session) if session else 'all'} cancelled={n}", flush=True)

    def _load(self) -> None:
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.models.omnivoice.utils import create_voice_clone_prompt
        from mlx_audio.tts.models.omnivoice.duration import RuleDurationEstimator

        self.en = load_model(EN_MODEL)
        self.bs = load_model(BS_MODEL)
        self.bs_ref = create_voice_clone_prompt(BS_REF_WAV, tokenizer=self.bs.audio_tokenizer,
                                                max_duration_s=10.0)
        with open(BS_REF_TXT, encoding="utf-8") as f:
            self.bs_ref_text = f.read().strip()
        # Pace speech from the reference clip, as upstream OmniVoice does; the MLX port
        # otherwise assumes "Nice to meet you." = 1 s and pads the estimate by 15%.
        self.bs_est = RuleDurationEstimator()
        for bosnian in (False, True):  # warm up both pipelines (consume the generators)
            list(self._synth("Spreman.", bosnian))
        self.ready.set()
        print(f"{NAME} {VERSION}: models loaded (home {HOME})", flush=True)

    def _synth(self, chunk: str, bosnian: bool):
        if bosnian:
            tokens = self.bs_est.estimate_duration(chunk, self.bs_ref_text, self.bs_ref.shape[0])
            results = self.bs.generate(text=chunk, lang_code=BS_LANG,
                                       ref_tokens=self.bs_ref, ref_text=self.bs_ref_text,
                                       duration_s=max(1, int(tokens)) / OMNI_TOKENS_PER_SEC)
        else:
            results = self.en.generate(text=chunk, voice=EN_VOICE, lang_code=EN_LANG)
        for r in results:
            yield np.array(r.audio, dtype=np.float32), r.sample_rate

    def _generate_loop(self) -> None:
        try:
            self._load()
        except Exception:  # never sit "loading" forever: exit so launchd logs it and retries
            traceback.print_exc()
            print(f"{NAME}: model load failed; exiting (re-run /speak setup)", flush=True)
            os._exit(1)
        while True:
            job = self.board.next_job()
            audio_s = 0.0
            try:
                audio_s = self._speak_job(job)
            finally:
                self.board.finish(job, audio_s)

    def _speak_job(self, job: Job) -> float:
        """Generate one job's audio into the player; returns seconds of audio sent."""
        text = prepare(job.text, char_limit())
        bosnian = is_bosnian(text)
        trim_log()
        print(f"reply: session={short(job.session)} engine={'omnivoice/bs' if bosnian else 'kokoro/en'} "
              f"chars={len(text)} waited={time.monotonic() - job.queued_at:.1f}s", flush=True)
        chunks = split_chunks(text, MERGE_TO["bs" if bosnian else "en"])
        started = time.monotonic()
        synth_s = audio_s = 0.0
        for chunk in chunks:
            if self.board.is_cancelled(job):
                break
            chunk_t0 = time.monotonic()
            try:
                for audio, sr in self._synth(chunk, bosnian):
                    self.player.send((job.id, audio, sr, started if audio_s == 0 else None, job.queued_at))
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
            body = json.dumps({"name": NAME, "version": VERSION, "home": HOME, "ready": ready}).encode()
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
