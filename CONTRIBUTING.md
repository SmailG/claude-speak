# Contributing

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues
privately, as described in [SECURITY.md](SECURITY.md). Pull requests use the template in
`.github/`; a maintainer reviews and merges them.

## Layout

| Path | Role |
|---|---|
| `hooks/hooks.json`, `hooks/tts.sh` | Stop / UserPromptSubmit hooks that forward payloads to the daemon |
| `hooks/sync.sh` | SessionStart: copy new daemon code into the data dir after an update |
| `skills/speak/SKILL.md`, `scripts/speakctl.sh` | The `/speak` command |
| `scripts/setup.sh`, `scripts/uninstall.sh` | Install / remove the runtime, models and launchd service |
| `daemon/` | `speakd.py` (HTTP + MLX engine), `player.py` (playback process), `jobs.py` (queueing), `text.py` (cleanup, routing, chunking) |

## Rules

- **Bump the version on every change** in both `.claude-plugin/plugin.json` and `NAME, VERSION`
  in `daemon/speakd.py` (`tests/test_version.py` checks they match). `claude plugin update` does
  nothing while the version is unchanged.
- Hooks must never block or fail a session: short timeouts, always `exit 0`.
- MLX models must load in the thread that generates (GPU streams are thread-local), and playback
  must stay in the separate player process (in-process playback stutters while MLX holds the GIL).
- Nothing in the daemon may reference `${CLAUDE_PLUGIN_ROOT}`: it changes on every update. The
  daemon runs from `CLAUDE_SPEAK_HOME` (the plugin data dir).

## Tests

```bash
python3 -m unittest discover -s tests   # text + job queue + version sync (stdlib only)
bash tests/shell.test.sh                # hooks and /speak against a fake daemon (needs jq)
claude plugin validate --strict .claude-plugin/plugin.json
```

Shell tests are two-sided: each behaviour has a must-happen and a must-not-happen case.
For a live check: `claude --plugin-dir .`, run `/speak setup`, and watch `speakd.log`.
