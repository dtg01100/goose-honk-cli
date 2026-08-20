#!/usr/bin/env bash
# install.sh — symlink ./gander somewhere on $PATH.
#
# Usage:
#   ./install.sh                 # default: ~/bin if it exists, else ~/.local/bin
#   ./install.sh ~/bin           # explicit destination
#   ./install.sh /usr/local/bin  # any writable PATH directory
#
# Idempotent: re-running is safe.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/gander"

if [[ ! -x "$SCRIPT" ]]; then
    echo "install.sh: $SCRIPT is not executable; chmod +x first." >&2
    exit 1
fi

# Default destination: prefer ~/bin (already on PATH on most distros); fall
# back to ~/.local/bin (XDG-style).
if [[ $# -eq 0 ]]; then
    if [[ -d "$HOME/bin" ]]; then
        dest="$HOME/bin"
    else
        dest="$HOME/.local/bin"
        mkdir -p "$dest"
    fi
else
    if [[ -z "${1:-}" ]]; then
        echo "install.sh: destination directory cannot be empty" >&2
        exit 2
    fi
    dest="$1"
    mkdir -p "$dest"
fi

link="$dest/gander"
if [[ -e "$link" && ! -L "$link" ]]; then
    echo "install.sh: $link already exists and is not a symlink; leaving it alone." >&2
    echo "  Remove it manually if you want to install here: rm $link" >&2
    exit 1
fi

ln -sfn "$SCRIPT" "$link"

echo "✓ installed: $link -> $SCRIPT"
echo
# Choose the right PATH tip depending on where we installed.
case "$dest" in
    "$HOME/bin")
        echo "$HOME/bin is already on PATH (most distros ship it that way)."
        ;;
    "$HOME/.local/bin")
        echo "Make sure $dest is on your PATH. For bash, add to ~/.bashrc if needed:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
    *)
        echo "Make sure $dest is on your PATH."
        ;;
esac
echo
echo "Then run:"
echo "    hash -r  # pick up the new binary"
echo "    gander --help"
