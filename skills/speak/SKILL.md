---
name: speak
description: Replay the last reply aloud, turn spoken replies on or off, set the length limit or speaking speed, show status, or set up / uninstall the local speech service
argument-hint: "[on|off|status|limit N|speed X|setup|uninstall]  (no argument = replay last reply)"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" "$ARGUMENTS" "${CLAUDE_SESSION_ID}" "${CLAUDE_PLUGIN_DATA}"`

If the line above is exactly `[speak] SETUP`: run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "${CLAUDE_PLUGIN_DATA}"` with the Bash tool and
`run_in_background: true` (it downloads ~4.5 GB of voice models and can take a while), tell the
user it has started, and when it finishes report its last lines: success, or the error and the
fix it suggests. Do nothing else.

Otherwise reply with exactly the line(s) above and nothing else. Do not call any tools.
