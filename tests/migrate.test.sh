#!/bin/bash
# Two-sided tests for scripts/migrate.sh (taking over an install made under the old name,
# claude-speak) in a fake HOME, with fake launchctl, tccutil and lsof that log their calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$ROOT/scripts/migrate.sh"
[ -f "$MIGRATE" ] || { echo "FATAL: missing $MIGRATE"; exit 2; }
command -v rsync >/dev/null || { echo "FATAL: need rsync"; exit 2; }

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }
exists() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; CALLS="$TMP/calls.log"; mkdir -p "$BIN"
for tool in launchctl tccutil; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$tool" "$CALLS" > "$BIN/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$BIN/lsof"  # the port is free
chmod +x "$BIN"/*
run() { HOME="$1" PATH="$BIN:$PATH" VOICE_CONVERSATION_APP_DIR="$1/Applications" bash "$MIGRATE" "$2" >/dev/null 2>&1; echo $?; }

# --- no old install: nothing happens
H="$TMP/clean"; mkdir -p "$H"
check "no old install: exit 0" "0" "$(run "$H" "$H/new")"
check "no old install: no data dir made" "no" "$(exists "$H/new")"
check "no old install: launchd untouched" "no" "$(exists "$CALLS")"

# --- an old install with voice input
H="$TMP/home"; OLD="$H/.claude/plugins/data/claude-speak-claude-speak"; NEW="$H/new"
AG="$H/Library/LaunchAgents"; APP="$H/Applications/Claude Speak Hotkey.app"
mkdir -p "$OLD/daemon" "$OLD/voices" "$OLD/models/whisper" "$AG" "$APP/Contents" "$NEW/voices"
echo bs > "$OLD/stt_lang"; echo off > "$OLD/hotkey"; echo 1.3 > "$OLD/speed"
echo old-voice > "$OLD/voices/voice_bs.txt"; echo mine > "$OLD/voices/extra.txt"
ln -s "$TMP/cache/config.json" "$OLD/models/whisper/config.json"
echo code > "$OLD/daemon/speakd.py"; echo log > "$OLD/speakd.log"; echo '{}' > "$OLD/guard.json"
echo '{}' > "$OLD/hotkey_status.json"; mkdir "$OLD/.hotkey-build.lock"
echo new-voice > "$NEW/voices/voice_bs.txt"
touch "$AG/com.claude-speak.daemon.plist" "$AG/com.claude-speak.hotkey.plist" "$AG/com.other.plist"

check "old install: exit 10" "10" "$(run "$H" "$NEW")"
check "settings copied" "bs 1.3 off" "$(cat "$NEW/stt_lang" "$NEW/speed" "$NEW/hotkey" | tr '\n' ' ' | sed 's/ $//')"
check "a voice only the old install had is copied" "mine" "$(cat "$NEW/voices/extra.txt")"
check "an existing file is not overwritten" "new-voice" "$(cat "$NEW/voices/voice_bs.txt")"
check "the Whisper link stays a link" "$TMP/cache/config.json" "$(readlink "$NEW/models/whisper/config.json")"
for f in daemon speakd.log guard.json hotkey_status.json .hotkey-build.lock off; do
  check "not copied: $f" "no" "$(exists "$NEW/$f")"
done
check "old hooks muted" "yes" "$(exists "$OLD/off")"
check "old plists removed" "no no" "$(exists "$AG/com.claude-speak.daemon.plist") $(exists "$AG/com.claude-speak.hotkey.plist")"
check "other agents left alone" "yes" "$(exists "$AG/com.other.plist")"
check "old app removed" "no" "$(exists "$APP")"
check "old services stopped" "2" "$(grep -c 'launchctl bootout gui/[0-9]*/com.claude-speak\.' "$CALLS")"
check "old app's permissions reset" "1" "$(grep -c 'tccutil reset All com.claude-speak.hotkey' "$CALLS")"

# --- run again (setup re-run): still safe, still no overwrite
echo changed > "$NEW/stt_lang"
check "re-run: exit 10" "10" "$(run "$H" "$NEW")"
check "re-run: newer setting kept" "changed" "$(cat "$NEW/stt_lang")"

echo "migrate tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
