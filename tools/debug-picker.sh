#!/usr/bin/env bash
# Debugging companion for the picker. Runs honk's row-building logic and dumps
# the exact rows that would be piped to fzf, plus captures what fzf would
# receive on stdin.

set -euo pipefail

HONK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HONK_LIB="$HONK_ROOT/lib"

# shellcheck disable=SC1091
source "$HONK_LIB/list.sh"

OUT="${1:-/tmp/honk-debug-rows.tsv}"
LIMIT="${HONK_LIMIT:-50}"
PWD_ONLY="${HONK_PWD_ONLY:-1}"
WORKDIR="${HONK_WORKDIR:-$PWD}"

printf '=== honk debug ===\n' >&2
printf 'PWD         = %s\n' "$PWD" >&2
printf 'WORKDIR     = %s\n' "$WORKDIR" >&2
printf 'PWD_ONLY    = %s\n' "$PWD_ONLY" >&2
printf 'LIMIT       = %s\n' "$LIMIT" >&2
printf 'honk out  = %s\n' "$OUT" >&2

export HONK_LIMIT HONK_PWD_ONLY HONK_WORKDIR

# Same row builder honk uses (shared helper in lib/list.sh, so this view
# can't drift from the real picker).
honk_picker_rows > "$OUT"

printf 'rows built  = %s\n' "$(wc -l <"$OUT")" >&2
printf 'first 3:    =\n' >&2
head -3 "$OUT" | cat -v >&2
printf 'show as fzf would (col 1 only, --with-nth=1):\n' >&2
awk -F'\t' '{print $1}' "$OUT" | head -3 | cat -v >&2
