#!/bin/bash
# claude-speak uninstall: stop and unregister the speech service. Never deletes models or the
# runtime (they may be shared); prints how to remove them. The plugin's data dir is removed by
# `claude plugin uninstall claude-speak`.
#   uninstall.sh <data_dir>

DATA="${1:-${CLAUDE_PLUGIN_DATA:-}}"
LABEL="com.claude-speak.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "Stopped the speech service." \
  || echo "Speech service was not running."
if [ -f "$PLIST" ]; then
  rm -f "$PLIST" && echo "Removed $PLIST."
fi
[ -n "$DATA" ] && touch "$DATA/off" 2>/dev/null  # hooks stay quiet until you run /speak setup again
echo "Now run: claude plugin uninstall claude-speak   (removes the plugin and its data dir)"
echo "Optional, frees ~5 GB: 'uv tool uninstall mlx-audio', and delete these folders in ~/.cache/huggingface/hub:"
echo "  models--mlx-community--Kokoro-82M-bf16, models--prince-canuma--Kokoro-82M, models--mlx-community--OmniVoice-bfloat16"
