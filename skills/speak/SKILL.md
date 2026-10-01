---
name: speak
description: Replay the last reply aloud, turn spoken replies on or off, set the length limit, speaking speed or when the Bosnian voice unloads, set up and configure local voice input (hotkey, language, autosend), show status, or set up / uninstall the local speech service
argument-hint: "[on|off|status|limit N|speed X|unload N|lang X|hotkey X|autosend on|off|setup [input]|uninstall]  (no argument = replay last reply)"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *)
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/speakctl.sh" "$ARGUMENTS" "${CLAUDE_SESSION_ID}" "${CLAUDE_PLUGIN_DATA}"`

If the line above is exactly `[speak] SETUP` or `[speak] SETUP input`: run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "${CLAUDE_PLUGIN_DATA}"` — adding ` input` at the end
for `SETUP input` — with the Bash tool and `run_in_background: true` (it downloads voice models,
~4.5 GB for speech and ~1.5 GB more for voice input, and can take a while), tell the user it has
started, and when it finishes report its last lines: success, or the error and the fix it suggests.
Do nothing else.

Otherwise reply with exactly the line(s) above and nothing else. Do not call any tools.
