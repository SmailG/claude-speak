# claude-speak

Speaks Claude Code replies aloud with local, offline text-to-speech on Apple Silicon.
English uses [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M); Bosnian, Croatian and
Serbian use [OmniVoice](https://github.com/k2-fsa/OmniVoice) with a cloned voice. Both run through
[mlx-audio](https://github.com/Blaizzy/mlx-audio). Nothing is sent to a cloud service.

## Install

```bash
claude plugin marketplace add SmailG/claude-speak
claude plugin install claude-speak@claude-speak
```

Then, in a Claude Code session:

```
/speak setup
```

Setup installs the `mlx-audio` runtime as a [uv](https://docs.astral.sh/uv/) tool, downloads the
voice models (about 4.5 GB, once), and registers a small launchd service that keeps them loaded.
Re-running it is safe. When it finishes you hear "Speech is ready."

**Requirements:** macOS on Apple Silicon, `uv`, `jq`, `curl`, ~5 GB disk, ~3 GB free memory.

## Use

Replies are spoken automatically once setup is done.

| Command | What it does |
|---|---|
| `/speak` | Replay the last reply of this session (works while muted) |
| `/speak off` / `/speak on` | Mute / unmute spoken replies (`off` also stops current speech) |
| `/speak status` | Version, mute state, length limit, service state |
| `/speak limit N` | Speak at most N characters per reply (default 2000; `0` = no limit) |
| `/speak setup` | Install or repair the speech service |
| `/speak uninstall` | Stop and remove the speech service |

The plugin skill is `/claude-speak:speak`; plain `/speak` works as long as no other command uses that name.

## How it behaves

- **Typing stops speech** — but only the speech of the session you type in.
- **Several sessions** — a reply from another session waits until the current one finishes;
  a new reply from the same session replaces its own older one. Replies that waited more than
  3 minutes are dropped.
- **Headless runs** (`claude -p`, Agent SDK, background summarizers) are never spoken.
- **What is read**: code blocks, tables, URLs and file paths are skipped; long replies are cut
  at a sentence end at the length limit.
- **Language** is decided per reply: Bosnian/Croatian/Serbian text goes to OmniVoice, everything
  else to Kokoro (`af_heart`). Typical time to first audio: English ~0.3 s, Bosnian ~3 s.

## How it works

```
Stop hook ──► hooks/tts.sh ──► speakd (launchd, 127.0.0.1:8765) ──► player process ──► speakers
UserPromptSubmit ──► tts.sh stop ─┘   generates sentence chunks with MLX   (own process, so
/speak ──► scripts/speakctl.sh ───┘   while earlier chunks play            generation can't stutter it)
```

The service runs from the plugin's data directory (`~/.claude/plugins/data/…`), so plugin updates
don't break it; a SessionStart hook copies new daemon code there and restarts the service after an
update. Its log is `speakd.log` in that directory.

## Custom Bosnian voice

Replace `voices/voice_bs.wav` (≤10 s of clean speech) and `voices/voice_bs.txt` (its exact
transcript) in the plugin's data directory, then restart the service:
`launchctl kickstart -k gui/$(id -u)/com.claude-speak.daemon`. Setup never overwrites them.

## Uninstall

Run `/speak uninstall` first (stops and unregisters the service), then
`claude plugin uninstall claude-speak`. The models and the `mlx-audio` uv tool are left in place
because other tools may use them; `/speak uninstall` prints how to remove them.

## Privacy

Everything runs locally. Reply text goes only to the local service on `127.0.0.1`. `/speak`
reads the current session's transcript in `~/.claude/projects/` to find the last reply. The
service log records per reply only the session id prefix, engine, length and timings.

## Licenses

- Code: MIT, see [LICENSE](LICENSE).
- `voices/`: generated with OmniVoice, whose weights are **CC-BY-NC-4.0**; see [voices/NOTICE](voices/NOTICE).
- Models (downloaded at setup, not redistributed here): Kokoro-82M is Apache-2.0; OmniVoice
  weights are CC-BY-NC-4.0 (non-commercial use).
