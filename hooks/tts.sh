#!/bin/bash
# claude-speak hook: forwards hook payloads to the local speakd daemon.
#   Stop:             tts.sh speak   (stdin = hook JSON: last_assistant_message, session_id)
#   UserPromptSubmit: tts.sh stop    (stdin = hook JSON: session_id, prompt)
#   PermissionRequest, PreToolUse (menu tools), PostToolUse(Failure): tts.sh guard
#     (a menu opened or closed: voice input must not type into it)
# Never blocks or fails the session: 1 s timeout, always exits 0.

PORT="${CLAUDE_SPEAK_PORT:-8765}"
HOME_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-speak}"
ACTION="${1:-speak}"

# Headless runs (claude -p, Agent SDK, e.g. background summarizers) report an sdk-*
# entrypoint; interactive CLI/IDE sessions report cli, claude-vscode, ...
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac

# Hooks run without a terminal; the claude process that started them has one.
claude_tty() {
  local pid=$PPID t _
  for _ in 1 2 3 4 5 6; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$t" in tty*) printf '%s' "$t"; return ;; esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return
  done
}

# The header marks a hook (a web page can't send it to localhost without a CORS preflight).
post() {
  curl -s --max-time 1 -o /dev/null -H "X-Claude-Speak-Hook: 1" --data-binary @- \
    "http://127.0.0.1:$PORT/$1?tty=$(claude_tty)" 2>/dev/null
}

# The guard needs only what identifies the call, not tool_response (which can be megabytes).
guard_fields() {
  if command -v jq >/dev/null 2>&1; then
    jq -c '{hook_event_name, tool_name, tool_input}' 2>/dev/null
  else
    cat
  fi
}

case "$ACTION" in
  speak) if [ -e "$HOME_DIR/off" ]; then guard_fields | post guard; else post speak; fi ;;
  guard) guard_fields | post guard ;;
  *) post stop ;;
esac
exit 0
