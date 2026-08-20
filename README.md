# gander

> **Independent third-party project:** This is a community-built companion to
> [goose](https://github.com/aaif-goose/goose), not an official goose extension,
> plugin, or bundled component. It is not authored, maintained, endorsed, or
> supported by the goose project, AAIF, or Block. It uses the local goose CLI
> and session data, but that does not imply official support or affiliation.

A terminal-native fuzzy launcher for [goose](https://github.com/aaif-goose/goose) sessions.

Goose can resume a session, but finding the right one usually means remembering
its name, ID, and working directory. Gander puts the common session actions in
one fzf picker and shows a live preview of the conversation tail.

## Features

- Search session names, IDs, and working directories in one fuzzy picker.
- Resume, fork, create, export, or delete sessions without nested menus.
- Preview session metadata and the last few messages before resuming.
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
- The `sqlite3` CLI for message-body previews
- GNU `readlink -f` (or an equivalent that resolves symlinks) for installs
  made from a symlinked checkout

Gander is designed for Linux, macOS, and WSL. The session list and action
commands are provided by the goose CLI; gander does not replace the goose
session database or its TUI.

## Quick start

From a checkout of this repository:

```sh
./install.sh
hash -r
gander --help
gander
```

The installer prefers `$HOME/bin` when it already exists, otherwise it uses
`$HOME/.local/bin`. It is safe to run again and will replace a previous symlink.
To choose another directory:

```sh
./install.sh /path/to/a/PATH-directory
```

The destination must not already contain a non-symlink file named `gander`.
To uninstall, remove only the symlink created by the installer:

```sh
rm ~/.local/bin/gander   # or: rm ~/bin/gander
```

## Usage

```sh
gander                         # interactive picker
gander -r CI                   # fuzzy-resume a matching session
gander --list                  # pretty text listing
gander --json                  # one JSON object per line
gander --working-dir ~/p      # restrict results to ~/p and its children
gander --all                   # include sessions outside the cwd subtree
gander --no-cwd                # alias for --all
gander --archived              # include archived sessions
gander --limit 100             # cap the result count (default: 50)
gander --help
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
| `Esc` / `Ctrl-C` | Cancel |

Search fields are name, ID, and working directory. The `goose` session list is
queried for metadata; the message preview reads the goose SQLite database
directly. Resume and fork call goose using the selected session ID, and the
conversation tail is echoed before handoff so it remains visible after goose
exits.

## Configuration

Environment variables provide useful defaults; matching command line
options override them:

| Variable | Default | Purpose |
| --- | --- | --- |
| `GG_LIMIT` | `50` | Maximum sessions to request |
| `GG_ASCENDING` | unset | Add goose’s ascending-order option when set |
| `GG_ARCHIVED` | `0` | Include archived sessions when set to `1` |
| `GG_PWD_ONLY` | `1` | Filter to the cwd subtree; set to `0` for all sessions |
| `GG_WORKDIR` | current directory | Override the cwd filter base |
| `GG_RESUME_PREVIEW` | `1` | Set to `0` to skip the pre-resume tail |
| `GG_RESUME_TAIL` | `4` | Number of messages to echo before resume/fork |
| `GG_PREVIEW_TEXT_CAP` | `200` | Per-part text length in the fzf preview |
| `GG_FZF_TIMEOUT` | `600` | Picker idle timeout in seconds |

For example:

```sh
GG_LIMIT=200 GG_PWD_ONLY=0 gander
GG_RESUME_PREVIEW=0 gander -r release
```

## How it works

- `gander` is a Bash entrypoint that resolves the project root and sources the
  independent helpers in `lib/`.
- `lib/list.sh` gets newline-delimited JSON from `goose session list`, then
  applies directory and archive filters with jq.
- `lib/preview.sh` reads message bodies from goose’s SQLite sessions database
  and formats the latest messages for fzf’s preview pane.
- `lib/actions.sh` performs resume, fork, new-session, export, and confirmed
  delete operations.
- `lib/sql/queries.sql` contains readable reference queries for the preview
  and metadata data model.

Gander does not intentionally send session data over the network. It reads
the local goose database for previews and delegates state-changing actions to
goose. Be careful with `Ctrl-D`: deletion is performed only after the
confirmation prompt.

## Development

Run the checks from a checkout:

```sh
make check       # Bash syntax and ShellCheck
make test        # non-destructive smoke tests
```

The smoke tests inject a temporary fake `goose` command, so they do not need
an active goose installation or touch real sessions. They do use jq and
sqlite3, which are also runtime dependencies.

## Troubleshooting

- **Interactive picker exits immediately:** run it from a TTY and make sure
  `fzf` is installed and on `$PATH`.
- **No sessions are listed:** run `goose session list --format json` directly
  and check that the same user owns the goose data directory.
- **Preview is empty:** install `sqlite3`; gander falls back to metadata-only
  previews when the database or CLI is unavailable.
- **Install says another file is in the way:** remove the existing non-symlink
  `gander` or choose a different destination.
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
