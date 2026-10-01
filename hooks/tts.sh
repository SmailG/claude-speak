#!/bin/bash
# claude-speak hook: forwards hook payloads to the local speakd daemon.
#   Stop:             tts.sh speak   (stdin = hook JSON: last_assistant_message, session_id)
#   UserPromptSubmit: tts.sh stop    (stdin = hook JSON: session_id, prompt)
# Never blocks or fails the session: 1 s timeout, always exits 0.

PORT="${CLAUDE_SPEAK_PORT:-8765}"
HOME_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-speak}"
ACTION="${1:-speak}"

# Headless runs (claude -p, Agent SDK, e.g. background summarizers) report an sdk-*
# entrypoint; interactive CLI/IDE sessions report cli, claude-vscode, ...
case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac

if [ "$ACTION" = "speak" ]; then
  [ -e "$HOME_DIR/off" ] && exit 0
  curl -s --max-time 1 -o /dev/null --data-binary @- "http://127.0.0.1:$PORT/speak" 2>/dev/null
else
  curl -s --max-time 1 -o /dev/null --data-binary @- "http://127.0.0.1:$PORT/stop" 2>/dev/null
fi
exit 0
