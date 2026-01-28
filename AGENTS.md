# Network Doctor – Agent Notes

- Keep scripts POSIX‑friendly bash and avoid nonstandard dependencies.
- Prefer NetworkManager (`nmcli`) for status and recovery actions.
- Log via `logger -t network-doctor` so messages land in journald.
- Any changes to behavior should be documented in `README.md`.
