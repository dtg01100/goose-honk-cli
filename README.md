# Honk

> **Independent third-party project:** This is a community-built companion to
> [goose](https://github.com/aaif-goose/goose), not an official goose extension,
> plugin, or bundled component. It is not authored, maintained, endorsed, or
> supported by the goose project, AAIF, or Block. It uses the local goose CLI
> and session data, but that does not imply official support or affiliation.

This repository is `goose-honk-cli`, and the installed command is `honk`.

A terminal-native fuzzy launcher for [goose](https://github.com/aaif-goose/goose) sessions.

Goose can resume a session, but finding the right one usually means remembering
its name, ID, and working directory. Honk puts the common session actions in
one fzf picker and shows a live metadata preview for the highlighted session.

## Features

- Search session names, IDs, and working directories in one fuzzy picker.
- Resume, fork, create, export, or delete sessions without nested menus.
- Preview session metadata (name, working directory, provider, model,
  created/updated timestamps, message count, accumulated cost) for the
  highlighted row.
- Pick the provider/model for the next launch from inside the picker with
  **Ctrl-P** (mirrors the Goose Desktop app's per-session model selector).
- Filter to sessions below the current directory by default; use **Ctrl-A** to
  show all sessions and press it again to return to the filtered view.
- Use `--list` and `--json` for non-interactive output, and `-r` for
  fragment-based resume.
- Install as a symlink from any checkout; no daemon, telemetry, or build step.

## Relationship to goose

This project is intentionally a separate, composable CLI: it queries
goose session list and hands resume, fork, export, and delete operations back to
goose. It does not replace or patch the goose binary.

The [goose project](https://github.com/aaif-goose/goose) is an independent
open-source project now stewarded through the Agentic AI Foundation (AAIF). The
maintainers have discussed a fuzzy session picker in
[goose issue #9915](https://github.com/aaif-goose/goose/issues/9915) and
currently prefer composable tools such as jq and fzf over embedding one picker
in goose. This project follows that approach without claiming to be part of the
official product.

If the functionality is eventually accepted upstream, the preferred path is
likely a native Rust change in the goose CLI using its session manager, not a
Bash wrapper. See [UPSTREAM.md](UPSTREAM.md) for the proposed path and the
official contribution constraints.

## Requirements

Install these before using the interactive picker:

- Bash 4 or newer
- `goose` 1.40 or newer on `$PATH`
- [fzf](https://github.com/junegunn/fzf) 0.40 or newer
- [jq](https://jqlang.github.io/jq/)
- GNU `readlink -f` (or an equivalent that resolves symlinks) for installs
  made from a symlinked checkout

Honk only talks to goose through the public CLI: `goose session list
--format json` for the picker rows and `goose session --resume` /
`--fork` / `export` / `remove` for the actions. It does not read the
goose SQLite sessions database, so any goose release that changes the
storage layer is automatically compatible.

Honk is designed for Linux, macOS, and WSL. The session list and action
commands are provided by the goose CLI; Honk does not replace the goose
session database or its TUI.

## Quick start

From a checkout of this repository:

```sh
./install.sh
hash -r
honk --help
honk
```

The installer prefers `$HOME/bin` when it already exists, otherwise it uses
`$HOME/.local/bin`. It is safe to run again and will replace a previous symlink.
To choose another directory:

```sh
./install.sh /path/to/a/PATH-directory
```

The destination must not already contain a non-symlink file named `honk`.
To uninstall, remove only the symlink created by the installer, or run
`./tools/uninstall.sh` to check the installer's default locations:

rm ~/.local/bin/honk   # or: rm ~/bin/honk

## Usage

```sh
honk                         # interactive picker
honk -r CI                   # fuzzy-resume a matching session
honk --list                  # pretty text listing
honk --json                  # one JSON object per line
honk --working-dir ~/p      # restrict results to ~/p and its children
honk -w ~/p                  # short form of --working-dir
honk --all                   # include sessions outside the cwd subtree
honk --no-cwd                # alias for --all
honk --archived              # include archived sessions
honk --limit 100             # cap the result count (default: 50)
honk --provider anthropic --model claude-3-5-sonnet-latest   # override for the next launch
honk --version               # print honk version and exit
honk --help                  # full usage
```

### Picker keys

| Key | Action |
| --- | --- |
| `Enter` | Resume the selected session in its original `working_dir` |
| `Ctrl-F` | Fork the selected session with goose’s `--fork` mode |
| `Ctrl-N` | Start a new session in the selected session’s directory |
| `Ctrl-E` | Export the session JSON to `./<id>.json` |
| `Ctrl-D` | Delete the session after a `y/N` confirmation |
| `Ctrl-A` | Toggle the cwd-only/all-sessions filter |
| `Ctrl-P` | Pick provider/model for the next launch (mirrors the Goose Desktop app's per-session model selector) |
| `Esc` / `Ctrl-C` | Cancel |

Search fields are name, ID, and working directory. The `goose` session list is
queried for metadata; the preview pane reads from the same snapshot the picker
rendered its rows from, so it never re-queries goose (or its SQLite database)
on every cursor move. Resume and fork call goose using the selected session ID;
once goose takes over, the user can scroll back inside the TUI to read the
full conversation.

### Picking a model for one launch

The picker has a **Ctrl-P** binding that opens a small fzf sub-picker to
choose a provider/model for the next launch (resume, fork, or new session).
It's a one-time, in-picker override — set it once and the next `Enter` (or
`Ctrl-F` / `Ctrl-N`) launches goose with `--provider NAME --model NAME`
appended. The override is reflected in the picker prompt (e.g.
`goose [anthropic/claude-3-5-sonnet-latest] ›`).

The same override is also available non-interactively via two new flags
and env vars:

```sh
honk --provider anthropic --model claude-3-5-sonnet-latest   # CLI
HONK_PROVIDER=anthropic HONK_MODEL=claude-3-5-sonnet-latest honk -r release   # env
```

Resolution order: CLI flag > env var > sub-picker choice (last only valid
for the current picker invocation). When neither is set, honk uses the
goose default — no change to existing behavior.

## Configuration

Environment variables provide useful defaults; matching command line
options override them:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HONK_LIMIT` | `50` | Maximum sessions to request |
| `HONK_ASCENDING` | `0` | Set to `1` to request ascending order from goose |
| `HONK_ARCHIVED` | `0` | Include archived sessions when set to `1` |
| `HONK_PWD_ONLY` | `1` | Filter to the cwd subtree; set to `0` for all sessions |
| `HONK_WORKDIR` | current directory | Override the cwd filter base |
| `HONK_FZF_TIMEOUT` | `600` | Picker idle timeout in seconds |
| `HONK_PROVIDER` | unset | Override provider for the next launch (passed to `goose session --provider`); see `--provider` |
| `HONK_MODEL` | unset | Override model for the next launch (passed to `goose session --model`); see `--model` |

For example:

```sh
HONK_LIMIT=200 HONK_PWD_ONLY=0 honk
```

## How it works

- `honk` is a Bash entrypoint that resolves the project root and sources the
  independent helpers in `lib/`.
- `lib/list.sh` gets newline-delimited JSON from `goose session list`, then
  applies directory and archive filters with jq. It also exports
  `honk_provider_candidates` / `honk_model_candidates`, which derive the
  picker sub-picker input (the **Ctrl-P** menu) from the cached session list
  plus a static fallback list of providers documented in `goose session
  --help`.
- `lib/preview.sh` renders the fzf preview pane for the highlighted row from
  the cached `goose session list` snapshot. It only reads metadata fields, so
  the preview is decoupled from goose's private SQLite schema and any goose
  release can change the storage layer without breaking it.
- `lib/actions.sh` performs resume, fork, new-session, export, and confirmed
  delete operations.
- `lib/sql/queries.sql` documents the public `goose session list --format json`
  shape that honk consumes. The queries in it are reference only — none
  are executed at runtime.

Honk does not intentionally send session data over the network. All
state-changing actions are delegated to goose. Be careful with `Ctrl-D`:
deletion is performed only after the confirmation prompt.

## Development

Run the checks from a checkout:

```sh
make doctor     # verify runtime requirements (bash >=4, fzf >=0.40, jq, goose)
make check      # Bash syntax and ShellCheck
make test       # non-destructive smoke tests
```

For interactive debugging of the picker (dump the rows that would be
piped to fzf), use `tools/debug-picker.sh` directly; its output goes to
`/tmp/honk-debug-rows.tsv` by default.

The smoke tests inject a temporary fake `goose` command, so they do not need
an active goose installation or touch real sessions. They do use jq, which is
also a runtime dependency.

## Troubleshooting

- **Interactive picker exits immediately:** run it from a TTY and make sure
  `fzf` is installed and on `$PATH`.
- **No sessions are listed:** run `goose session list --format json` directly
  and check that the same user owns the goose data directory.
- **Install says another file is in the way:** remove the existing non-symlink
  `honk` or choose a different destination.
- **The new command is not found:** run `hash -r` and check that the selected
  install directory is in `$PATH`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development conventions and the
pull-request checklist. Please read [SECURITY.md](SECURITY.md) before
reporting a vulnerability.

For the longer-term goal of contributing this functionality to goose proper,
see [UPSTREAM.md](UPSTREAM.md).

## License

[MIT](LICENSE) — Copyright © 2026 David LaFreniere.
