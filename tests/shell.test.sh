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
        b = json.dumps({"name": "claude-speak", "version": "t", "home": home, "ready": True}).encode()
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
: > "$LOG"; echo '{"session_id":"s1","prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
check "stop forwards payload with session" "s1" "$(grep -m1 '^/stop ' "$LOG" | cut -d' ' -f2- | jq -r .session_id)"
# ... and stays silent for headless runs and when muted
n=$(requests)
echo '{"last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
echo '{"prompt":"x"}' | CLAUDE_CODE_ENTRYPOINT=sdk-py CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" stop
touch "$DATA/off"; echo '{"last_assistant_message":"hi"}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak
check "headless + muted send nothing" "$n" "$(requests)"; rm -f "$DATA/off"

# --- tts.sh with the daemon down: fast, silent, exit 0
start=$(python3 -c 'import time; print(time.time())')
out=$(echo '{}' | CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_SPEAK_PORT=1 CLAUDE_PLUGIN_DATA=$DATA bash "$TTS" speak 2>&1); rc=$?
fast=$(python3 -c "import time; print(time.time() - $start < 1.5)")
check "daemon down: exit 0" "0" "$rc"; check "daemon down: no output" "" "$out"; check "daemon down: fast" "True" "$fast"

# --- speakctl: valid options change state, invalid ones don't
ctl() { bash "$CTL" "$1" "${2:-}" "$DATA"; }
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
  rm "$SH/Library/LaunchAgents/com.claude-speak.daemon.plist"; plist "/some/other/install"
  echo "# old" >> "$SD/daemon/text.py"; sync_run
  check "sync: another install's service is left alone" "1" "$(kicks)"
else
  echo "SKIP: 3 sync.sh checks (need macOS PlistBuddy)"
fi

echo "shell tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
