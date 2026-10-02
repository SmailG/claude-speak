"""User settings, read fresh on every use from small files in the data dir (written by /speak).

Each reader falls back to its default when the file is missing or holds garbage.
"""

import os

HOME = os.environ.get("VOICE_CONVERSATION_HOME") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_CHARS = int(os.environ.get("VOICE_CONVERSATION_MAX_CHARS", "2000"))
LIMIT_FILE = os.path.join(HOME, "max_chars")  # written by `/speak limit N`; 0 = no limit
SPEED_FILE = os.path.join(HOME, "speed")      # written by `/speak speed X`
# Above 1.3 OmniVoice (Bosnian) stops outrunning playback, so speech stalls between chunks,
# and at 1.5 its words get garbled (Whisper WER 6-30%). One range for both languages.
MIN_SPEED, MAX_SPEED = 1.0, 1.3  # keep in sync with SPEED_RE in scripts/speakctl.sh

VOICES_DIR = os.path.join(HOME, "voices")
UNLOAD_FILE = os.path.join(HOME, "unload_minutes")  # written by `/speak unload N`; 0 = keep loaded
DEFAULT_UNLOAD_MIN, MAX_UNLOAD_MIN = 10, 1440
LANG_FILE = os.path.join(HOME, "stt_lang")  # written by `/speak lang X`
LANGUAGES = ("auto", "bs", "hr", "sr", "en")  # keep in sync with LANG_RE in scripts/speakctl.sh


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


def stt_language() -> str:
    try:
        with open(LANG_FILE, encoding="utf-8") as f:
            lang = f.read().strip()
        return lang if lang in LANGUAGES else "auto"
    except OSError:
        return "auto"
