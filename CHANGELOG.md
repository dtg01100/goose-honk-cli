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
- `sqlite3` is no longer a runtime dependency.

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
  through `goose session`'s own `--provider` / `--model` flags (documented
  as "Override the GOOSE_PROVIDER environment variable for this run").
  Goose itself handles the provider/model compatibility check; if the user
  picks an unsupported pair, goose rejects it at exec time.
- The metadata preview pane now shows `provider:` and `model:` lines for
  each session, so the user can see what model a previous session used
  before resuming it (mirrors Goose Desktop's persistent model indicator).
- The picker supports an optional `--query` initial-search argument
  (currently used internally by the Ctrl-P reopen to restore the user's
  search query across the model-picker transition).

### Changed
- The fzf preview pane is narrower (45% instead of 55%) since the
  metadata-only preview needs less horizontal space than a
  conversation tail.
- The preview header gains a `last msg:` line that surfaces
  `last_message_at` from the session metadata (when present), so users
  still get a quick "how recently was this session active" signal
  without reading message bodies.

### Added
- `-w DIR` is now documented in the `--help` output and README as the
  short form of `--working-dir`.
- The `-V` and `-h` short flags are now documented in the `--help`
  output alongside their long forms (`--version`, `--help`).
- The `--flag=value` form is now accepted for every flag (boolean or
  value-taking) so users don't need to remember which flags accept `=`
  and which don't. The value is ignored for boolean flags (`--all`,
  `--archived`, `--no-cwd`, `--no-grep`, `--help`, `--version`,
  `--list`, `--json`); for value-taking flags (`-r`, `--working-dir`,
  `-w`, `--limit`, `--grep`) the same non-empty validation as the
  space-separated form applies.

### Changed
- The header comment in `lib/list.sh` and the README table now spell
  out the `HONK_ASCENDING=0|1` contract instead of "unset".
- `honk_resolve_fragment` now checks for an interactive terminal with
  `-t 1 && -t 2` (stdout + stderr) instead of `-t 0` (stdin), so the
  picker is offered when stdout is a tty even if stdin has been
  redirected, and refused when stdout has been piped even if stdin is
  a tty. This matches `honk_pick`'s tty guard.
- The preview pane and pre-resume tail now color role labels by role so
  the user can scan a conversation tail at a glance. User turns render
  in bold green (`\033[1;32m`), assistant turns in bold cyan
  (`\033[1;36m`), and any other role (tool, system, future roles) falls
  back to dim cyan (`\033[2;36m`). Previously every `▸ role` label used
  the same bold cyan, making user and assistant turns visually
  indistinguishable. The labels themselves remain plain text; the color
  is applied via ANSI escapes only and is honored by terminals that
  support it (fzf's preview pane, the resume tail's stdout).

### Fixed
- `jq -r '.field'` without a `// ""` fallback emitted the literal string
  `null` for sessions whose `working_dir`, `created_at`, or `updated_at`
  was missing or null. The preview header rendered `null` next to
  `working_dir:` instead of an empty value, the recent-dirs strip in the
  picker offered `__NEW_AT__null` as a row, the `__PICK_DIR__` directory
  picker offered `null` as a target, and `honk_session_working_dir`
  returned `null` instead of empty (breaking the documented `[[ -z "$wd"
  ]]` guard downstream). All four call sites now coalesce missing/null
  values to empty strings.
- `HONK_ASCENDING` was treated as truthy whenever the env var was
  non-empty, so `HONK_ASCENDING=0` and `HONK_ASCENDING=false` silently
  enabled ascending order. The new contract treats only `1` as on and
  rejects anything else with a clear error message. The header comment
  in `lib/list.sh` and the README table now document the contract.
- The argument parser only accepted the space-separated form
  (`--limit 10`, `--grep foo`, `--working-dir /tmp`, `-w /tmp`) and
  rejected the `--flag=value` form as "unknown flag". Both forms now
  work for every flag that takes a value (`-r`, `--working-dir`/`-w`,
  `--limit`, `--grep`); an empty value via `=` is rejected with the
  same "needs an argument" error as the space-separated form.
- The preview pane leaked sqlite's "malformed JSON" stderr warning
  into the rendered preview when a message's `content_json` column
  wasn't valid JSON (a real-data possibility if a partial row lands in
  the DB after a crash or schema change). The fix pins `2>/dev/null`
  on the sqlite invocation so the row is silently dropped (the
  surrounding `coalesce(…, '')` keeps the query valid) and the warning
  never reaches the preview.
- `honk_db_path` stripped ALL whitespace from the path returned by
  `goose info`, which corrupted any session DB path containing a space
  (e.g. under `/home/me/My Projects/...`). The fix uses awk's
  trailing-only strip (`gsub(/[[:space:]]+$/, "")`) so leading/trailing
  padding from `goose info` is trimmed but internal spaces survive.
- The picker exported `HONK_PWD="$PWD"` to fzf on every invocation but
  nothing read it. The dead env-var pass is removed.
- The argument parser silently dropped extra positional arguments
  (`honk foo bar` resolved `bar` and ignored `foo`). The parser now
  reports `honk: unexpected extra argument` so users catch typos
  instead of resolving the wrong session.
- `honk_resolve_fragment`'s multi-match disambiguation called
  `honk_action_resume` even when the user pressed Esc on the fzf
  picker, which left an empty `--session-id` for goose to error on.
  The picker now bails cleanly when no row was selected.
- The comment above the `__PICK_DIR__` arm of Ctrl-N claimed the
  behavior was "same as Enter", which is misleading: Enter opens the
  directory picker while Ctrl-N silently falls back to `$PWD`. The
  comment now spells out the fallback.
- The preview pane and pre-resume tail silently truncated long `text`
  and `thinking` parts at `HONK_PREVIEW_TEXT_CAP` (default 200 bytes)
  with no visual marker, so the user could not tell whether they were
  reading the full message or just the first N bytes. The SQL renderer
  now compares the source length against the cap and appends a `…` to
  any part that was actually cut, while parts that fit inside the cap
  render verbatim with no marker. The marker is appended in SQL rather
  than in the formatter so the truncation signal survives any later
  folding, wrapping, or piping of the body.

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
