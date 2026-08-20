# Security policy

This is an independent, third-party companion to goose. It is not an official
goose component, and security reports about this repository should not be
sent to the goose maintainers unless they also affect the upstream project.
See [UPSTREAM.md](UPSTREAM.md) for the relationship and contribution path.

## Supported versions

Only the `main` branch is currently supported. Older snapshots and locally
modified copies are not guaranteed to receive security fixes.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository’s
private **Security → Report a vulnerability** / Security Advisory form. If
that form is unavailable, contact the project maintainer through the account
that owns the repository rather than including session data in a public
report.

When reporting an issue, include a minimal reproduction, affected version or
commit, expected behavior, and impact. Do not attach real goose session
exports, database files, credentials, or other private conversation content.

## Security considerations

honk is a local launcher around the goose CLI and SQLite session database.
It does not intentionally transmit data over the network, but users should
still:

- install it from a trusted checkout and review changes before upgrading;
- keep the goose database and exported session files private;
- review paths and session IDs before using export, resume, or delete actions;
- remember that the interactive preview displays local conversation content;
- protect the same accounts and host access used by goose itself.

Resume, fork, and new-session operations hand control to goose. Deletion is
performed by the corresponding goose command only after a confirmation prompt.
