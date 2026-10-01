#!/bin/bash
# claude-speak setup: install the speech runtime, download voice models, start the daemon.
#   setup.sh <data_dir>       (the /speak skill passes ${CLAUDE_PLUGIN_DATA})
# Idempotent and safe to re-run: installs are skipped when present, downloads resume.
set -euo pipefail

DATA="${1:-${CLAUDE_PLUGIN_DATA:-}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] \
    || fail "claude-speak needs macOS on Apple Silicon (MLX); this is $(uname -s)/$(uname -m)"
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
download_models
install_files
write_plist
start_daemon
