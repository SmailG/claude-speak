#!/bin/bash
# claude-speak SessionStart hook: after a plugin update, copy the new daemon code into the
# data dir the launchd service runs from, and restart it; rebuild the voice-input hotkey helper
# if its source changed (build-helper.sh is a no-op otherwise). A no-op unless /speak setup was run
# by THIS install (a --plugin-dir checkout and a marketplace install share one launchd label).
# Never fails the session.

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
DATA="${CLAUDE_PLUGIN_DATA:-}"
LABEL="com.claude-speak.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -n "$ROOT" ] && [ -n "$DATA" ] && [ -f "$PLIST" ] || exit 0
owner=$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:CLAUDE_SPEAK_HOME" "$PLIST" 2>/dev/null)
[ "$owner" = "$DATA" ] || exit 0

# Compare only the sources: the running daemon writes __pycache__/ into DATA, and treating that
# as a change would restart the service (and cut off speech) at every session start.
daemon_changed() {
  local f
  for f in "$ROOT"/daemon/*.py; do
    cmp -s "$f" "$DATA/daemon/${f##*/}" || return 0
  done
  return 1
}
if daemon_changed; then
  mkdir -p "$DATA/daemon" && cp "$ROOT"/daemon/*.py "$DATA/daemon/" \
    && launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
fi

HOTKEY_PLIST="$HOME/Library/LaunchAgents/com.claude-speak.hotkey.plist"
if [ -f "$HOTKEY_PLIST" ] \
  && [ "$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$HOTKEY_PLIST" 2>/dev/null)" = "$DATA" ]; then
  bash "$ROOT/scripts/build-helper.sh" "$DATA" >/dev/null 2>&1
fi
exit 0
