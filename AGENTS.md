# Network Doctor – Agent Notes

- Keep scripts POSIX‑friendly bash and avoid nonstandard dependencies.
- Prefer NetworkManager (`nmcli`) for status and recovery actions.
- Log via `logger -t network-doctor` so messages land in journald.
- Any changes to behavior should be documented in `README.md`.

## Agent testing
When running local tests as an agent, prefer a per-agent venv at `.<agent_name>/.venv`.

The value <agent_name> is the simplified lowercase version of your name. e.g. Codex would be "codex", Claude would be "claude", Gemini would be "gemini", etc.

## Session Reload (IMPORTANT)

At session start, read these files to restore context:
```bash
cat .<agent_name>/STATE.md
cat .<agent_name>/DECISIONS.md
cat .<agent_name>/TODO.md
cat .<agent_name>/CONTEXT.md
```

.<agent_name>/
├── STATE.md
├── DECISIONS.md
├── TODO.md
└── CONTEXT.md

## Logging

Log all your actions in .<agent_name>/log.txt.

Format: "<datetime>,<description>"
