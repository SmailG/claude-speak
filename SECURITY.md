# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security** tab → **Report a vulnerability**
([private vulnerability reporting](https://github.com/SmailG/claude-speak/security/advisories/new)).
Do not open a public issue for a vulnerability.

You can expect a first response within a week.

## Scope

claude-speak runs entirely on your Mac: a launchd service listening on `127.0.0.1` only, hooks
that forward Claude Code's reply text to it, and the `/speak` command. Relevant reports include
anything that lets another local user or a web page drive the service, command injection through
`/speak` arguments or reply text, and ways to make the hooks block or break a Claude Code session.

Only the latest release is supported.
