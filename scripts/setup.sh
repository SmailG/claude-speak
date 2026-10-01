#!/bin/bash
# claude-speak setup: install the speech runtime, download voice models, start the daemon.
#   setup.sh <data_dir>         speech output (the /speak skill passes ${CLAUDE_PLUGIN_DATA})
#   setup.sh <data_dir> input   add local voice input (Whisper, ~1.5 GB) to an existing setup
# Idempotent and safe to re-run: installs are skipped when present, downloads resume.
set -euo pipefail

DATA="${1:-${CLAUDE_PLUGIN_DATA:-}}"
MODE="${2:-speech}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=platform.sh
source "$ROOT/scripts/platform.sh"

# A terminal running under Rosetta would install x86_64 Python, which MLX can't use:
# re-run natively.
if is_translated; then
  exec arch -arm64 /bin/bash "${BASH_SOURCE[0]}" "$@"
fi
LABEL="com.claude-speak.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${CLAUDE_SPEAK_PORT:-8765}"
MLX_AUDIO_VERSION="0.5.7"
SPACY_EN="en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
READY_TIMEOUT_S=180

step() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
  [ -n "$DATA" ] || fail "no data directory given (run this through /speak setup)"
  local problem
  problem=$(platform_problem)
  [ -z "$problem" ] || fail "$problem"
  for tool in uv jq curl; do
    command -v "$tool" >/dev/null || fail "'$tool' not found. Install it (e.g. brew install $tool) and re-run /speak setup"
  done
}

install_runtime() {
  PY="$(uv tool dir)/mlx-audio/bin/python"
  if [ -x "$PY" ] && "$PY" -c "import mlx_audio, misaki, en_core_web_sm, sounddevice" 2>/dev/null; then
    step "mlx-audio runtime already installed"
    return
  fi
  step "installing mlx-audio $MLX_AUDIO_VERSION (uv tool, Python 3.12)"
  uv tool install --force --python 3.12 "mlx-audio==$MLX_AUDIO_VERSION" \
    --with 'misaki[en]' --with "$SPACY_EN"
  "$PY" -c "import mlx_audio, misaki, en_core_web_sm, sounddevice" || fail "runtime import check failed"
}

download_models() {
  step "downloading voice models (~4.5 GB on first run; resumes if interrupted)"
  "$PY" - <<'PY'
from huggingface_hub import hf_hub_download, snapshot_download
snapshot_download("mlx-community/Kokoro-82M-bf16")          # English model + voices
hf_hub_download("prince-canuma/Kokoro-82M", "voices/af_heart.safetensors")  # read by the Kokoro pipeline
snapshot_download("mlx-community/OmniVoice-bfloat16")       # Bosnian/Croatian/Serbian model
print("models ready")
PY
}

install_whisper() {
  step "downloading the Whisper speech-to-text model (~1.5 GB on first run; resumes if interrupted)"
  "$PY" - "$DATA/models/whisper" <<'PY'
import os, shutil, sys
from huggingface_hub import hf_hub_download, snapshot_download
dest = sys.argv[1]
os.makedirs(dest, exist_ok=True)
# The MLX weights ship without a tokenizer; the tokenizer comes from the original OpenAI repo.
weights = snapshot_download("mlx-community/whisper-large-v3-turbo")
for name in ("config.json", "weights.safetensors"):
    link = os.path.join(dest, name)
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(os.path.join(weights, name), link)
for name in ("tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "normalizer.json",
             "added_tokens.json", "special_tokens_map.json", "preprocessor_config.json",
             "generation_config.json"):
    shutil.copy(hf_hub_download("openai/whisper-large-v3-turbo", name), os.path.join(dest, name))
print("whisper ready")
PY
}

check_voice_input() {
  local health
  health=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" || true)
  [ "$(printf '%s' "$health" | jq -r '.home' 2>/dev/null)" = "$DATA" ] \
    || fail "the speech service isn't running from this install; run /speak setup first"
  [ "$(curl -s --max-time 2 "http://127.0.0.1:$PORT/config" | jq -r '.voice_input' 2>/dev/null)" = "true" ] \
    || fail "the service doesn't see the Whisper model in $DATA/models/whisper; see $DATA/speakd.log"
  step "voice input is ready: the model loads on first use and unloads like the Bosnian voice"
}

install_files() {
  step "installing daemon into $DATA"
  mkdir -p "$DATA/daemon" "$DATA/voices"
  cp "$ROOT"/daemon/*.py "$DATA/daemon/"
  for f in "$ROOT"/voices/voice_bs.*; do  # keep a voice the user replaced
    [ -e "$DATA/voices/$(basename "$f")" ] || cp "$f" "$DATA/voices/"
  done
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$PY</string><string>$DATA/daemon/speakd.py</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_SPEAK_HOME</key><string>$DATA</string>
    <key>CLAUDE_SPEAK_PORT</key><string>$PORT</string>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Stop respawning once the plugin's data dir is gone (plugin uninstalled). -->
  <key>KeepAlive</key>
  <dict><key>PathState</key><dict><key>$DATA/daemon/speakd.py</key><true/></dict></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$DATA/speakd.log</string>
  <key>StandardErrorPath</key><string>$DATA/speakd.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || fail "generated plist is invalid: $PLIST"
}

start_daemon() {
  step "starting the speech service ($LABEL)"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  sleep 1
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $PORT is already in use by another process (lsof -nP -iTCP:$PORT). Stop it and re-run /speak setup"
  fi
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT_S" ]; do
    health=$(curl -s --max-time 1 "http://127.0.0.1:$PORT/health" || true)
    if [ "$(printf '%s' "$health" | jq -r '.ready' 2>/dev/null)" = "true" ]; then
      [ "$(printf '%s' "$health" | jq -r '.home')" = "$DATA" ] || fail "a different claude-speak install answered on port $PORT"
      curl -s --max-time 2 -o /dev/null --data-binary '{"last_assistant_message":"Speech is ready."}' \
        "http://127.0.0.1:$PORT/speak" || true
      step "claude-speak is ready (took ${waited}s to load). Log: $DATA/speakd.log"
      return
    fi
    sleep 2; waited=$((waited + 2))
  done
  fail "service did not become ready in ${READY_TIMEOUT_S}s; see $DATA/speakd.log"
}

check_prereqs
install_runtime
case "$MODE" in
  speech)
    download_models
    install_files
    write_plist
    start_daemon ;;
  input)
    install_whisper
    check_voice_input ;;
  *) fail "unknown setup mode '$MODE' (use: setup.sh <data_dir> [input])" ;;
esac
