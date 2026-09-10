#!/usr/bin/env bash
# tools/uninstall.sh — remove the symlink created by ./install.sh.
#
# Looks for a `honk` symlink in the same default locations the installer
# prefers, plus anything passed on the command line. Refuses to remove a
# non-symlink file so we never delete something the user actually owns.
#
# Usage:
#   ./tools/uninstall.sh                 # try ~/bin and ~/.local/bin
#   ./tools/uninstall.sh /custom/dir     # also check this directory

set -euo pipefail

dirs=()
[[ -d "$HOME/bin" ]]          && dirs+=("$HOME/bin")
[[ -d "$HOME/.local/bin" ]]   && dirs+=("$HOME/.local/bin")
for d in "$@"; do
    [[ -d "$d" ]] && dirs+=("$d")
done

if (( ${#dirs[@]} == 0 )); then
    echo "uninstall: no candidate directories to check" >&2
    exit 1
fi

removed=0
for d in "${dirs[@]}"; do
    link="$d/honk"
    if [[ -e "$link" ]]; then
        if [[ -L "$link" ]]; then
            target=$(readlink "$link")
            rm -f "$link"
            printf '✓ removed %s -> %s\n' "$link" "$target"
            removed=1
        else
            printf 'skipping %s — not a symlink (run "rm %s" manually if you really want to)\n' \
                "$link" "$link" >&2
        fi
    fi
done

if (( !removed )); then
    echo "uninstall: no honk symlink found in: ${dirs[*]}" >&2
    echo "  If you installed somewhere else, pass that directory as an argument." >&2
    exit 1
fi
