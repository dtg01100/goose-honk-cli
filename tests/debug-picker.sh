#!/usr/bin/env bash
# Debugging companion for the picker. Runs gander's row-building logic and dumps
# the exact rows that would be piped to fzf, plus captures what fzf would
# receive on stdin.

set -euo pipefail

GG_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
GG_LIB="$GG_ROOT/lib"

# shellcheck disable=SC1091
source "$GG_LIB/list.sh"

OUT="${1:-/tmp/gander-debug-rows.tsv}"
LIMIT="${GG_LIMIT:-50}"
PWD_ONLY="${GG_PWD_ONLY:-1}"
WORKDIR="${GG_WORKDIR:-$PWD}"

printf '=== gander debug ===\n' >&2
printf 'PWD         = %s\n' "$PWD" >&2
printf 'WORKDIR     = %s\n' "$WORKDIR" >&2
printf 'PWD_ONLY    = %s\n' "$PWD_ONLY" >&2
printf 'LIMIT       = %s\n' "$LIMIT" >&2
printf 'gander out  = %s\n' "$OUT" >&2

export GG_LIMIT GG_PWD_ONLY GG_WORKDIR

# Build the same rows gander builds for the picker.
{
    printf '  \033[1m▶  New session here\033[0m  \033[2m— %s\033[0m\t__NEW_HERE__\t—\t—\t—\n' "$PWD"

    gg_list_json | jq -r '
        . as $s
        | ((.working_dir // "") as $wd
           | if ($wd == env.PWD or ($wd | startswith(env.PWD + "/")))
             then "." + ($wd | ltrimstr(env.PWD))
             else $wd end) as $rel
        | [
            "  " + (($s.name // "(unnamed)") | .[0:50]) +
                "  \u001b[2m" + $rel + "\u001b[0m" +
                "   \u001b[2m" + ($s.message_count // 0 | tostring) + " msgs  $" +
                ($s.accumulated_cost // 0 | tostring) + "  " + ($s.updated_at // "") + "\u001b[0m",
            $s.id, "—", "—", "—"
          ]
        | @tsv
    '

    printf '  \u001b[2m▶  New session in another directory…  (pick one)\u001b[0m\t__PICK_DIR__\t—\t—\t—\n'

    gg_list_json | jq -r '.working_dir' \
        | awk '!seen[$0]++' | head -6 | while IFS= read -r wd; do
            [[ -z "$wd" ]] && continue
            [[ "$wd" == "$PWD" ]] && continue
            printf '    \u001b[2m→ new in  %s\u001b[0m\t__NEW_AT__%s\t—\t—\t—\n' "$wd" "$wd"
        done
} > "$OUT"

printf 'rows built  = %s\n' "$(wc -l <"$OUT")" >&2
printf 'first 3:    =\n' >&2
head -3 "$OUT" | cat -v >&2
printf 'show as fzf would (col 1 only, --with-nth=1):\n' >&2
awk -F'\t' '{print $1}' "$OUT" | head -3 | cat -v >&2
