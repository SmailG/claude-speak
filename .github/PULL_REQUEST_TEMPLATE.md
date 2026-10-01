## What and why

<!-- What this changes and the problem it solves. Link the issue: "Fixes #N". -->

## How it was tested

<!-- Commands run and what you checked live (e.g. /speak setup, a spoken reply, speakd.log). -->

## Checklist

- [ ] `python3 -m unittest discover -s tests` and `bash tests/shell.test.sh` pass
- [ ] New behaviour has a test that fails without the change
- [ ] Version bumped in both `.claude-plugin/plugin.json` and `daemon/speakd.py` (if code changed)
- [ ] README updated if a command or behaviour changed
