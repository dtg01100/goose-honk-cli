# Changelog

All notable changes to Honk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-20

### Added
- `--version` flag reports the current honk version. When the checkout is a
  git working tree, the version is derived from `git describe --always
  --dirty`, so development builds self-identify (e.g. `0.1.0-3-g4f2a1b-dirty`).
  Source tarballs and non-git checkouts fall back to the baked-in release
  tag (`0.1.0`).
- `--grep <query>` and `HONK_GREP=<query>` filter the picker to sessions
  whose messages contain the query (case-insensitive substring match
  against the SQLite `messages.content_json` field). Useful for finding
  sessions about a specific topic without remembering session names.
  `--no-grep` clears the filter. The picker honors the non-empty / empty
  contract: an empty grep is treated as no filter.
- `Ctrl-G` keybinding prompts for a grep query and reopens the picker
  filtered to matching sessions. Empty input clears the filter. The
  cwd-only mode is preserved across the reopen (Ctrl-A and Ctrl-G
  compose independently). Query input is read from `/dev/tty` so it
  does not interfere with the picker stdin. The Ctrl-A reopen also
  preserves any active grep, so toggling cwd-only does not silently
  drop the content filter.

### Fixed
- Preview pane corrupted message bodies that contained `|` characters. The
  sqlite-to-format pipeline used `|` as a column separator, and the row
  formatter used `IFS='|' read` to split the role label from the body, so a
  tool run containing `a | b | c` would be shredded into three pieces.
  Switched the separator to the ASCII unit separator (US, `\x1f`), which
  does not appear in normal text content, and parsed the first column
  with shell parameter expansion so the body is preserved verbatim. Bodies
  like `echo a | b` and `if x | grep y; then …` now render correctly.
- The interactive picker showed only the synthetic "new session" rows and
  no real goose sessions, because the picker exported `HONK_LIST_CACHE`
  *before* the first call to `honk_list_json`. `honk_list_json` treats a
  readable cache file as authoritative and reads from it; the `mktemp`
  tempfile is empty but still readable, so the first call short-circuited
  to an empty result and the picker was left with zero real sessions.
  The picker now runs the initial fetch first and exports
  `HONK_LIST_CACHE` only after the cache has been populated, so the row
  builder, the recent-directories strip, fzf's preview pane, and the
  action helpers all see the same goose roundtrip instead of a stale
  empty file.

### Changed
- The picker now fetches the session list exactly once per invocation and
  caches it on disk (`$HONK_LIST_CACHE`). fzf's preview pane runs on every
  cursor move and keystroke, and was previously re-invoking `goose session
  list` for each tick; the recent-directories strip, the picker directory
  chooser, and the `Ctrl-N` action re-queried goose as well. All of those
  now read from the cache, so picker interactions are noticeably snappier
  on large session lists and put no further load on the goose database
  while the picker is open. The cache is a single tempfile in
  `$TMPDIR` (default `/tmp`) and is removed on shell exit. `honk --list`,
  `honk --json`, and `honk -r <fragment>` are unaffected and still
  query goose directly.

## [0.1.0] - 2026-08-20

### Added
- Initial public release of Honk as an independent third-party companion
  to goose.
- Interactive picker with fuzzy search across session name, id, and
  working directory.
- Resume (`Enter`), fork (`Ctrl-F`), new session (`Ctrl-N`), export
  (`Ctrl-E`), and delete (`Ctrl-D`) actions.
- Toggle between cwd-scoped and all-sessions view (`Ctrl-A`).
- Non-interactive forms: `honk --list`, `honk --json`, `honk -r <fragment>`.
- Live preview pane with session metadata and the last N messages.
- Environment overrides for limit, archived flag, cwd filter, working
  directory, resume tail, and preview cap.
- Smoke test suite that uses a fake `goose` binary against a temporary
  sqlite database, so it does not need a real goose installation.
- Install script (`install.sh`) that symlinks `honk` into a directory
  on `$PATH` (defaults to `~/bin` if it exists, otherwise `~/.local/bin`).
