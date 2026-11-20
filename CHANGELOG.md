# Changelog

All notable changes to Honk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- The fzf preview pane no longer renders message bodies, and the
  pre-resume / pre-fork "conversation tail" is gone. Both features
  read goose's private `messages.content_json` schema directly (with
  per-part text/thinking/tool extraction, truncation, role-label
  coloring, and malformed-JSON handling), which silently broke on any
  goose release that reshaped the messages table. The picker now shows
  session metadata only — name, working directory, created/updated
  timestamps, message count, accumulated cost — sourced from the same
  `goose session list --format json` snapshot the picker already uses,
  so the preview stays decoupled from the storage layer. The
  accompanying knobs (`HONK_RESUME_PREVIEW`, `HONK_RESUME_TAIL`,
  `HONK_PREVIEW_TEXT_CAP`) and the message-related fragments in
  `lib/sql/queries.sql` are also removed.
- The `--grep` / `--no-grep` CLI flags, the `HONK_GREP` env var, the
  `Ctrl-G` keybinding, the `honk_apply_grep` and
  `honk_grep_session_ids` helpers, `honk_db_path`, and the
  schema-touching portion of `lib/sql/queries.sql` are removed. The
  grep filter was the last honk feature that read goose's private
  `messages` table directly; with it gone, honk only depends on
  documented public interfaces (`goose session list --format json` and
  the `goose session --resume` / `--fork` / `export` / `remove`
  subcommands). Any goose release can change the storage layer or
  the messages table shape without affecting honk.
- `sqlite3` is no longer a runtime dependency (including in CI).
- The unused `honk_is_under()` helper is removed; the jq subtree filter
  already implements the same check.

### Added
- Per-launch provider/model override via `--provider NAME` / `--model NAME`
  on the honk CLI, matching `HONK_PROVIDER` / `HONK_MODEL` env vars, and a
  new **Ctrl-P** picker binding that opens a nested fzf sub-picker to pick
  a provider (from the cached session list, sorted by frequency, plus a
  small static fallback for discoverability) and a model (from the cached
  models for that provider). The override applies to the next launch and
  is reflected in the picker prompt (e.g.
  `goose [anthropic/claude-3-5-sonnet-latest] ›`). Honk does not know or
  enumerate every (provider, model) pair — it only reads the documented
  `provider_name` and `model_config.model_name` fields off the public
  `goose session list --format json` shape, and passes the chosen values
  through `goose session`'s own `--provider` / `--model` flags.
- The metadata preview pane now shows `provider:` and `model:` lines for
  each session, so the user can see what model a previous session used
  before resuming it (mirrors Goose Desktop's persistent model indicator).
- The picker supports an optional `--query` initial-search argument,
  used by both the Ctrl-A and Ctrl-P reopens to restore the user's query.
- `-w DIR`, `-V`, and `-h` are documented in the `--help` output and README.
- The `--flag=value` form is accepted for every flag. The value is ignored
  for boolean flags; value-taking flags (`-r`/`--resume`, `--working-dir`
  /`-w`, `--limit`, `--provider`, `--model`, `--query`) apply the same
  non-empty validation as the space-separated form.

### Changed
- The fzf preview pane is narrower (45% instead of 55%) since the
  metadata-only preview needs less horizontal space than a
  conversation tail.
- The preview header gains a `last msg:` line that surfaces
  `last_message_at` from the session metadata (when present).
- The header comment in `lib/list.sh` and the README table now spell
  out the `HONK_ASCENDING=0|1` contract instead of "unset".
- `honk_resolve_fragment` checks `-t 1 && -t 2` (stdout + stderr) instead
  of `-t 0`, matching `honk_pick`'s tty guard.
- Row building now lives in `honk_picker_rows` in `lib/list.sh`, shared
  by the picker and `tools/debug-picker.sh` so the debug view cannot drift.
- The session id is now part of fzf's searchable display column; fzf's
  `--with-nth=1` previously restricted matching to name/path/metadata.
- The picker's tty guard runs before the goose query, so a non-tty
  invocation reports the tty problem instead of a missing-goose error.
- `tools/doctor.sh` enforces the documented goose >= 1.40 requirement.
- `Ctrl-E` refuses to overwrite an existing `./<id>.json`; pass an explicit
  target path to export somewhere else.

### Fixed
- `jq -r '.field'` without a `// ""` fallback emitted the literal string
  `null` for sessions whose `working_dir`, `created_at`, or `updated_at`
  was missing or null. The preview header, recent-dirs strip, directory
  picker, and `honk_session_working_dir` now all coalesce to empty strings.
- `HONK_ASCENDING` was treated as truthy whenever the env var was
  non-empty, so `HONK_ASCENDING=0` silently enabled ascending order.
  Only `1` is on now; other values fail with a clear error.
- The argument parser accepted only space-separated values. All value-taking
  flags now accept both forms, including the previously missing
  `--resume=<fragment>`.
- A trailing slash in `HONK_WORKDIR` / `--working-dir` (e.g. `/tmp/demo/`)
  matched no sessions at that exact directory. The workdir is normalized
  before the jq subtree filter runs.
- The argument parser silently dropped extra positional arguments
  (`honk foo bar` resolved `bar`); it now reports the extra argument.
- `honk_resolve_fragment`'s multi-match disambiguation called
  `honk_action_resume` even when the user pressed Esc on the fzf picker;
  it now bails cleanly when no row was selected.
- Ctrl-A dropped the user's search query on reopen even though Ctrl-P
  preserved it; both reopens now forward `--query`.
- The picker exported `HONK_PWD="$PWD"` to fzf but nothing read it; the
  dead env-var pass is removed.
- The comment above the `__PICK_DIR__` arm of Ctrl-N now spells out its
  `$PWD` fallback instead of incorrectly claiming it matched Enter.

## [0.2.0] - 2026-08-20

### Added
- `--version` flag reports the current honk version. When the checkout is a
  git working tree, the version is derived from `git describe --always
  --dirty`, so development builds self-identify (e.g. `0.2.0-3-g4f2a1b-dirty`).
  Source tarballs and non-git checkouts fall back to the baked-in release
  tag (`0.2.0`).
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
