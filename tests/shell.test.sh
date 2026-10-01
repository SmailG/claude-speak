#!/bin/bash
# Two-sided tests for hooks/tts.sh and scripts/speakctl.sh against a fake daemon.
# Every behaviour has a case that must happen AND a case that must not, so a broken
# harness (e.g. the fake daemon never receiving anything) fails instead of passing vacuously.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TTS="$ROOT/hooks/tts.sh"; CTL="$ROOT/scripts/speakctl.sh"; SYNC="$ROOT/hooks/sync.sh"
for f in "$TTS" "$CTL" "$SYNC"; do [ -f "$f" ] || { echo "FATAL: missing $f"; exit 2; }; done
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FATAL: need jq and python3"; exit 2; }

PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi; }

TMP=$(mktemp -d); DATA="$TMP/data"; mkdir -p "$DATA"
PORT=$((20000 + RANDOM % 20000)); export CLAUDE_SPEAK_PORT=$PORT
LOG="$TMP/requests.log"

# Fake daemon: records "<path> <body>" per request; /health reports home=$DATA.
python3 - "$PORT" "$LOG" "$DATA" <<'PY' &
import http.server, json, sys
port, log, home = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)).decode()
        open(log, "a").write(f"{self.path} {body}\n"); self.send_response(204); self.end_headers()
    def do_GET(self):
        b = json.dumps({"name": "claude-speak", "version": "t", "home": home, "ready": True,
                        "models": {"en": True, "bs": False}, "sessions": ["ttys001", "ttys002"]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
FAKE=$!
trap 'kill $FAKE 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 0.1; done

requests() { grep -c '^/' "$LOG" 2>/dev/null || true; }  # count requests, not lines (bodies may end in \n)
: > "$LOG"

# --- tts.sh: forwards in interactive sessions ...
echo '{"session_id":"s1","last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "speak forwarded (cli)" "/speak" "$(grep -m1 -o '^/[a-z]*' "$LOG")"
check "tty param is a terminal name or empty" "1" "$(grep -cE '^/speak\?tty=(ttys[0-9]+)? ' "$LOG")"
: > "$LOG"; echo '{"session_id":"s1","prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
check "stop forwards payload with session" "s1" "$(grep -m1 '^/stop?' "$LOG" | cut -d' ' -f2- | jq -r .session_id)"
: > "$LOG"; echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "guard forwards the hook event" "PermissionRequest" "$(grep -m1 '^/guard?' "$LOG" | cut -d' ' -f2- | jq -r .hook_event_name)"
: > "$LOG"; echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":"BIG"}' \
  | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "guard sends the call, not its output" '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x"}}' \
  "$(grep -m1 '^/guard?' "$LOG" | cut -d' ' -f2-)"
if [ "$(uname)" = Darwin ]; then  # a real terminal: the tty of the process that ran the hook
  : > "$LOG"; script -q /dev/null bash -c "echo '{}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash '$TTS' guard" </dev/null >/dev/null
  check "guard reports the session's tty" "1" "$(grep -cE '^/guard\?tty=ttys[0-9]+ ' "$LOG")"
fi
# ... stays silent for headless runs, and when muted only closes the session's menus
: > "$LOG"
echo '{"last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
echo '{"prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=sdk-py CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
echo '{}' | CLAUDE_CODE_ENTRYPOINT=sdk-py CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" guard
check "headless sends nothing" "0" "$(requests)"
touch "$DATA/off"; echo '{"hook_event_name":"Stop","last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "muted: no speech, only the guard" "/guard" "$(grep -o '^/[a-z]*' "$LOG" | tr '\n' ' ' | sed 's/ $//')"; rm -f "$DATA/off"

# --- tts.sh with the daemon down: fast, silent, exit 0
start=$(python3 -c 'import time; print(time.time())')
out=$(echo '{}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_SPEAK_PORT=1 CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak 2>&1); rc=$?
fast=$(python3 -c "import time; print(time.time() - $start < 1.5)")
check "daemon down: exit 0" "0" "$rc"; check "daemon down: no output" "" "$out"; check "daemon down: fast" "True" "$fast"

# --- speakctl: valid options change state, invalid ones don't
# speakctl talks to launchd about the hotkey helper: give it a fake launchctl that logs its calls and
# reports the agent loaded only while $TMP/agent_up exists.
CTLBIN="$TMP/ctlbin"; mkdir -p "$CTLBIN"
printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\n[ "$1" != print ] || [ -e "%s/agent_up" ]\n' "$TMP" "$TMP" > "$CTLBIN/launchctl"
chmod +x "$CTLBIN/launchctl"
ctl() { PATH="$CTLBIN:$PATH" bash "$CTL" "$1" "${2:-}" "$DATA"; }
check "off mutes" "yes" "$(ctl off >/dev/null; [ -e "$DATA/off" ] && echo yes || echo no)"
check "on unmutes" "no" "$(ctl on >/dev/null; [ -e "$DATA/off" ] && echo yes || echo no)"
check "limit 3000" "3000" "$(ctl 'limit 3000' >/dev/null; cat "$DATA/max_chars")"
check "LIMIT 0 (case)" "0" "$(ctl 'LIMIT 0' >/dev/null; cat "$DATA/max_chars")"
check "limit 0100 (leading zero)" "100" "$(ctl 'limit 0100' >/dev/null; cat "$DATA/max_chars")"
for bad in "limit" "limit abc" "limit 999999" "limit 5; touch $TMP/pwned"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "100" "$(cat "$DATA/max_chars")"
done
check "no injection" "no" "$([ -e "$TMP/pwned" ] && echo yes || echo no)"
for good in "1:1" "1.0:1" "1.25:1.25" "1.3:1.3" "1.30:1.3"; do
  ctl "speed ${good%%:*}" >/dev/null
  check "speed accepts ${good%%:*}" "${good##*:}" "$(cat "$DATA/speed")"
done
for bad in "speed" "speed 0.9" "speed 1.31" "speed 1.4" "speed 1.5" "speed 2" "speed .5" "speed 1." "speed abc" "speed 1.2; touch $TMP/pwned2"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "1.3" "$(cat "$DATA/speed")"
done
check "no injection via speed" "no" "$([ -e "$TMP/pwned2" ] && echo yes || echo no)"
check "status shows speed" "1" "$(ctl status | grep -c 'speed 1.3x (~243 wpm in English)')"
echo garbage > "$DATA/speed"
check "corrupt speed file reads as 1x" "1" "$(ctl status | grep -c 'speed 1x')"
for good in "0:0" "10:10" "1440:1440" "007:7"; do
  ctl "unload ${good%%:*}" >/dev/null
  check "unload accepts ${good%%:*}" "${good##*:}" "$(cat "$DATA/unload_minutes")"
done
for bad in "unload" "unload -1" "unload 1441" "unload 2.5" "unload abc" "unload 5; touch $TMP/pwned3"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "7" "$(cat "$DATA/unload_minutes")"
done
check "no injection via unload" "no" "$([ -e "$TMP/pwned3" ] && echo yes || echo no)"
check "status shows memory state" "1" "$(ctl status | grep -c 'Bosnian voice not loaded · 2 sessions open — Bosnian voice unloads after 7 min idle')"
ctl "unload 0" >/dev/null
check "status shows keep-loaded" "1" "$(ctl status | grep -c 'kept loaded while a session is open')"
for good in auto bs hr sr en; do
  ctl "lang $good" >/dev/null
  check "lang accepts $good" "$good" "$(cat "$DATA/stt_lang")"
done
for bad in "lang" "lang de" "lang BSX" "lang en; touch $TMP/pwned4"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "en" "$(cat "$DATA/stt_lang")"
done
check "no injection via lang" "no" "$([ -e "$TMP/pwned4" ] && echo yes || echo no)"
for good in right-command fn off right-option; do
  ctl "hotkey $good" >/dev/null
  check "hotkey accepts $good" "$good" "$(cat "$DATA/hotkey")"
done
check "hotkey change restarts the helper" "4" "$(grep -c "kickstart -k gui/$(id -u)/com.claude-speak.hotkey" "$TMP/launchctl.log")"
for bad in "hotkey" "hotkey left-option" "hotkey caps" "hotkey fn; touch $TMP/pwned5"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "right-option" "$(cat "$DATA/hotkey")"
done
check "no injection via hotkey" "no" "$([ -e "$TMP/pwned5" ] && echo yes || echo no)"
check "fn warns about other double-Fn apps" "1" "$(ctl 'hotkey fn' | grep -c 'Wispr Flow')"
check "right option gives no Fn warning" "0" "$(ctl 'hotkey right-option' | grep -c 'Wispr Flow')"
ctl "autosend on" >/dev/null; check "autosend on" "on" "$(cat "$DATA/autosend")"
for bad in "autosend" "autosend yes" "autosend off; touch $TMP/pwned6"; do
  ctl "$bad" >/dev/null
  check "rejects '$bad'" "on" "$(cat "$DATA/autosend")"
done
check "no injection via autosend" "no" "$([ -e "$TMP/pwned6" ] && echo yes || echo no)"
check "status: no voice-input line before setup input" "0" "$(ctl status | grep -c 'Voice input')"
mkdir -p "$DATA/models/whisper"; touch "$DATA/models/whisper/config.json"
check "status: helper not running" "1" "$(ctl status | grep -c 'Voice input: double-tap right-option · autosend on · language en · hotkey helper not running')"
touch "$TMP/agent_up"
check "status: no status file is not 'ready'" "1" "$(ctl status | grep -c 'helper state unknown')"
echo '{"input_monitoring":true,"microphone":"not asked"}' > "$DATA/hotkey_status.json"
check "status: missing permission named" "1" "$(ctl status | grep -c 'needs Microphone (System Settings')"
echo '{"input_monitoring":true,"microphone":"granted"}' > "$DATA/hotkey_status.json"
check "status: helper ready" "1" "$(ctl status | grep -c 'language en · ready$')"
check "setup asks for speech setup" "[speak] SETUP" "$(ctl setup)"
check "setup input asks for input setup" "[speak] SETUP input" "$(ctl 'setup input')"
check "setup rejects other targets" "0" "$(ctl 'setup bogus' | grep -c '^\[speak\] SETUP')"
check "status names plugin" "1" "$(ctl status | grep -c '^\[speak\] claude-speak ')"
check "status sees own daemon" "1" "$(ctl status | grep -c 'service running')"
check "unknown option" "1" "$(ctl bogus | grep -c 'Unknown option')"
check "every line marked" "0" "$({ ctl status; ctl bogus; ctl 'limit x'; } 2>&1 | grep -vc '^\[speak\] ')"

# --- replay: reads the session transcript, skips /speak echoes; nothing without a transcript
SID="0000aaaa-1111-2222-3333-444455556666"; PROJ="$HOME/.claude/projects/claude-speak-test-$$"
mkdir -p "$PROJ"; trap 'kill $FAKE 2>/dev/null; rm -rf "$TMP" "$PROJ"' EXIT
{ echo '{"type":"assistant","message":{"content":[{"type":"text","text":"The real reply."}]}}'
  echo '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"[speak] Speech ON"}]}}'; } > "$PROJ/$SID.jsonl"
: > "$LOG"; ctl "" "$SID" >/dev/null
check "replay sends last real reply" "The real reply." "$(cut -d' ' -f2- "$LOG" | jq -r .last_assistant_message)"
: > "$LOG"
check "fresh session: nothing to replay" "1" "$(ctl "" "9999bbbb-0000-0000-0000-000000000000" | grep -c 'Nothing to replay')"
check "fresh session: nothing sent" "0" "$(requests)"
check "bad session id rejected" "1" "$(ctl "" '../../etc' | grep -c 'Nothing to replay')"

# --- platform.sh: stubbed uname / sysctl / sw_vers, so every case runs on any OS
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\n[ "$1" = "-s" ] && echo "$FAKE_OS" || echo "$FAKE_ARCH"\n' > "$STUBS/uname"
printf '#!/bin/sh\ncase "$2" in hw.optional.arm64) echo "$FAKE_ARM64";; sysctl.proc_translated) echo "$FAKE_TRANSLATED";; esac\n' > "$STUBS/sysctl"
printf '#!/bin/sh\necho "$FAKE_MACOS"\n' > "$STUBS/sw_vers"
chmod +x "$STUBS"/*
on() {  # on <os> <uname -m> <hw.optional.arm64> <proc_translated> <macOS> <shell code>
  FAKE_OS=$1 FAKE_ARCH=$2 FAKE_ARM64=$3 FAKE_TRANSLATED=$4 FAKE_MACOS=$5 PATH="$STUBS:$PATH" \
    bash -c "source '$ROOT/scripts/platform.sh'; $6"
}
check "platform: Apple Silicon, macOS 14.0" "" "$(on Darwin arm64 1 0 14.0 platform_problem)"
check "platform: Apple Silicon, macOS 26.5" "" "$(on Darwin arm64 1 0 26.5 platform_problem)"
check "platform: Rosetta shell is still Apple Silicon" "" "$(on Darwin x86_64 1 1 26.5 platform_problem)"
check "platform: Rosetta detected" "yes" "$(on Darwin x86_64 1 1 26.5 'is_translated && echo yes || echo no')"
check "platform: native is not translated" "no" "$(on Darwin arm64 1 0 26.5 'is_translated && echo yes || echo no')"
check "platform: macOS 13 refused" "1" "$(on Darwin arm64 1 0 13.6.1 platform_problem | grep -c 'macOS 14 Sonoma or newer; this is macOS 13.6.1')"
check "platform: unknown macOS refused" "1" "$(on Darwin arm64 1 0 '' platform_problem | grep -c 'this is macOS unknown')"
check "platform: Intel Mac refused" "1" "$(on Darwin x86_64 0 0 15.7 platform_problem | grep -c 'MLX does not run on Intel')"
check "platform: Intel Mac without the arm64 key refused" "1" "$(on Darwin x86_64 '' '' 15.7 platform_problem | grep -c 'Intel')"
check "platform: Linux refused" "1" "$(on Linux x86_64 '' '' '' platform_problem | grep -c 'this is Linux')"

# --- sync.sh: restarts the service only when daemon sources changed, and only for its own install
if [ -x /usr/libexec/PlistBuddy ]; then
  SH="$TMP/synchome"; SD="$TMP/syncdata"; BIN="$TMP/bin"; KICKS="$TMP/kicks.log"
  mkdir -p "$SH/Library/LaunchAgents" "$SD/daemon/__pycache__" "$BIN"
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$KICKS" > "$BIN/launchctl"; chmod +x "$BIN/launchctl"
  plist() { /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:CLAUDE_SPEAK_HOME string $1" \
    "$SH/Library/LaunchAgents/com.claude-speak.daemon.plist" >/dev/null; }
  sync_run() { HOME="$SH" PATH="$BIN:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$SD" bash "$SYNC"; }
  kicks() { cat "$KICKS" 2>/dev/null | grep -c kickstart; }  # prints 0 before the first call
  plist "$SD"; cp "$ROOT"/daemon/*.py "$SD/daemon/"; echo junk > "$SD/daemon/__pycache__/x.pyc"
  sync_run; check "sync: bytecode alone is not a change" "0" "$(kicks)"
  echo "# old" >> "$SD/daemon/text.py"; sync_run
  check "sync: changed source restarts once" "1" "$(kicks)"
  check "sync: changed source is copied" "0" "$(cmp -s "$ROOT/daemon/text.py" "$SD/daemon/text.py"; echo $?)"
  boots() { cat "$KICKS" 2>/dev/null | grep -c bootstrap; }
  if xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then  # the hotkey helper
    out=$(HOME="$TMP/buildhome" PATH="$BIN:$PATH" bash "$ROOT/scripts/build-helper.sh" "$TMP/builddata" 2>&1); rc=$?
    check "build-helper: a good build exits 0" "0" "$rc"
    check "build-helper: reports the build" "1" "$(printf '%s' "$out" | grep -c '^built ')"
    check "build-helper: leaves no lock" "0" "$(ls -a "$TMP/builddata" | grep -c lock)"
    mkdir "$TMP/builddata/.hotkey-build.lock"
    check "build-helper: a running build is left alone" "1" \
      "$(HOME="$TMP/buildhome" PATH="$BIN:$PATH" bash "$ROOT/scripts/build-helper.sh" "$TMP/builddata" | grep -c 'another hotkey helper build')"
    rmdir "$TMP/builddata/.hotkey-build.lock"; KB=$(boots)
    HP="$SH/Library/LaunchAgents/com.claude-speak.hotkey.plist"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments array" -c "Add :ProgramArguments:0 string x" \
      -c "Add :ProgramArguments:1 string $SD" "$HP" >/dev/null
    sync_run
    check "sync: hotkey helper built" "1" "$(ls "$SH/Applications/Claude Speak Hotkey.app/Contents/MacOS" 2>/dev/null | grep -c ClaudeSpeakHotkey)"
    check "sync: hotkey helper started" "$((KB + 1))" "$(boots)"
    sync_run; check "sync: unchanged helper is not rebuilt or restarted" "$((KB + 1))" "$(boots)"
    rm -f "$HP"
  else
    echo "SKIP: 7 hotkey helper checks (no Swift compiler)"
  fi
  rm "$SH/Library/LaunchAgents/com.claude-speak.daemon.plist"; plist "/some/other/install"
  echo "# old" >> "$SD/daemon/text.py"; sync_run
  check "sync: another install's service is left alone" "1" "$(kicks)"
else
  echo "SKIP: 4 sync.sh checks (need macOS PlistBuddy)"
fi

echo "shell tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
