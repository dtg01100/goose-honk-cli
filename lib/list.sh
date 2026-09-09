#!/usr/bin/env bash
# lib/list.sh — fetch + transform goose session list for fzf.
#
# Public API (sourceable):
#   honk_list_json            → prints newline-delimited JSON, one object per session
#   honk_list_fzf             → prints fzf-friendly rows (TSV-ish), id first
#   honk_list_pretty          → pretty human-readable table
#
# Tunable via env:
#   HONK_LIMIT     (default 50)
#   HONK_ASCENDING (default 0; set to 1 to request ascending order from goose)
#   HONK_ARCHIVED  (default 0; set to 1 to include archived sessions)
#   HONK_PWD_ONLY  (default 1; set to 0 to include all sessions)
#   HONK_WORKDIR   (override the filter; default: $PWD)
#
# Honk only reads the public `goose session list --format json` shape
# (the documented `--format json` output). It does not touch the
# goose SQLite sessions database; a future goose release can change
# the storage layer freely without affecting the picker.

set -euo pipefail

# Avoid double-sourcing guard
[[ -n "${HONK_LIB_LIST_LOADED:-}" ]] && return 0
HONK_LIB_LIST_LOADED=1

honk_is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Subtree match: does $1 (a session working_dir) live at or under $2 (a base)?
# Returns 0 (true) or 1 (false). Both arguments must be absolute paths.
honk_is_under() {
    local target="${1%/}" base="${2%/}"
    [[ -z "$base" ]] && return 0
    case "$target" in
        "$base"|"$base"/*) return 0 ;;
        *)                  return 1 ;;
    esac
}

# Emit newline-delimited JSON for every session after applying filters.
# Uses `goose session list --format json` as the data source so we stay
# decoupled from goose's sqlite schema.
#
# If $HONK_LIST_CACHE is set and points to a readable file, the cached JSON
# is emitted verbatim instead of re-querying goose. honk_pick writes that
# cache once per interactive invocation, so the row builder, fzf's preview
# pane (which fires on every keystroke), and the action helpers all share
# a single goose session list roundtrip.
honk_list_json() {
    # Hot path: read from the cache. This is the dominant case for the
    # interactive picker — everything except the initial fetch goes this
    # way. Falls through to the live fetch if the cache is missing or
    # unreadable so a stale $HONK_LIST_CACHE never blocks a real query.
    if [[ -n "${HONK_LIST_CACHE:-}" && -r "${HONK_LIST_CACHE}" ]]; then
        cat "${HONK_LIST_CACHE}"
        return 0
    fi

    local limit="${HONK_LIMIT:-50}"
    local ascending="${HONK_ASCENDING:-0}"
    local pwd_only="${HONK_PWD_ONLY:-1}"
    local workdir="${HONK_WORKDIR:-$PWD}"

    if ! honk_is_positive_integer "$limit"; then
        echo "honk: HONK_LIMIT must be a positive integer" >&2
        return 2
    fi
    if [[ "$pwd_only" != 0 && "$pwd_only" != 1 ]]; then
        echo "honk: HONK_PWD_ONLY must be 0 or 1" >&2
        return 2
    fi
    if [[ "${HONK_ARCHIVED:-0}" != 0 && "${HONK_ARCHIVED:-0}" != 1 ]]; then
        echo "honk: HONK_ARCHIVED must be 0 or 1" >&2
        return 2
    fi
    if [[ "$ascending" != 0 && "$ascending" != 1 ]]; then
        echo "honk: HONK_ASCENDING must be 0 or 1" >&2
        return 2
    fi
    command -v goose >/dev/null 2>&1 || {
        echo "honk: goose is required to list sessions" >&2
        return 1
    }

    local args=( -f json -l "$limit" )
    [[ "$ascending" == "1" ]] && args+=( --ascending )

    local raw
    raw=$(goose session list "${args[@]}" 2>/dev/null) || {
        echo "honk: failed to query goose session list" >&2
        return 1
    }

    # jq filter:
    #   - drop array wrap, emit one object per line
    #   - optional cwd subtree filter (if HONK_PWD_ONLY=1)
    #   - optionally drop archived sessions
    # jq args: -r for raw output; pass the workdir as a bound variable so
    # paths containing quotes or jq operators can't corrupt the filter.
    # The jq program is a literal passed to jq; shell expansion is intentional.
    # shellcheck disable=SC2016
    local jq_args=( -r )
    local jq_filter='.[]'
    if [[ "$pwd_only" == "1" ]]; then
        jq_args+=( --arg workdir "$workdir" )
        # Subtree match (at-or-under), mirroring honk_is_under: exact equality or
        # base + "/" prefix. Null-safe, and "startswith" here is literal
        # string matching, so a cwd of /tmp/foo no longer admits /tmp/foobar.
        # This assignment intentionally appends a literal jq program.
        # shellcheck disable=SC2016
        jq_filter+=' | (.working_dir // "") as $wd
                    | select($workdir == "/" or $wd == $workdir or ($wd | startswith($workdir + "/")))'
    fi
    if [[ "${HONK_ARCHIVED:-0}" != "1" ]]; then
        jq_filter+=" | select(.archived_at == null)"
    fi
    # goose already returns newest-first by default; HONK_ASCENDING toggles
    # the --ascending flag above and we don't re-sort here.
    jq_filter+=" | @json"

    printf '%s\n' "$raw" | jq "${jq_args[@]}" "$jq_filter"
}

# Format rows for fzf's input: TAB-separated columns that we can color/sort.
# Columns: <id>\t<name>\t<working_dir>\t<updated_at>\t<cost>\t<msgs>
honk_list_fzf() {
    honk_list_json | jq -r '
        [
            .id,
            (.name // "" | if . == "" then "(unnamed)" else . end),
            (.working_dir // ""),
            (.updated_at // ""),
            ((.accumulated_cost // 0) | tostring),
            ((.message_count // 0) | tostring),
            (.last_message_at // "")
        ]
        | @tsv
    '
}

# Pretty, two-line-per-session display for `honk --list`.
honk_list_pretty() {
    honk_list_json | jq -r '
        def fmt_date: sub("T"; " ") | sub("Z$"; "");
        # Pad s to n chars (never negative); " *" repeats a string n times.
        def pad(n; s): s + (" " * ([0, n - (s | length)] | max));
        "\(.id)  " + pad(40; .name // "(unnamed)") +
        "  " + ((.working_dir // "") | tostring) +
        "\n        updated: " + ((.updated_at // "") | fmt_date) +
        "   msgs: " + (.message_count // 0 | tostring) +
        "   cost: $" + ((.accumulated_cost // 0) | tostring)
    '
}

# ---- picker candidate extractors (Ctrl-P sub-picker inputs) ----
#
# These read from the same cached `goose session list --format json`
# snapshot the picker already maintains, so they don't add any new
# goose roundtrips and don't depend on the SQLite storage layer.
# Both return one item per line on stdout, ready to pipe into fzf.

# Build the provider sub-picker list. Emits providers in two sections:
#   1. Providers seen in the cached session list, sorted by descending
#      frequency (most-used first).
#   2. A small static fallback of providers documented in goose's
#      `goose session --help` output (anthropic, claude-code, …), for
#      discoverability — a user who has never used a provider can still
#      find it in the sub-picker.
# Duplicates are removed (cache entries win). If $HONK_PROVIDER is set,
# the current value is tagged with a " (current)" suffix so the user
# can see what's already in effect.
honk_provider_candidates() {
    local current="${HONK_PROVIDER:-}"
    local -A seen
    local p

    # Cache-derived, most-used first.
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        if [[ "$p" == "$current" ]]; then
            printf '%s (current)\n' "$p"
        else
            printf '%s\n' "$p"
        fi
    done < <(honk_list_json | jq -r '.provider_name // empty' \
        | sort | uniq -c | sort -rn \
        | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')

    # Static fallback for discoverability (per goose --help). Alphabetical.
    # Users with custom providers can set HONK_PROVIDER or pass --provider
    # on the command line — those values are not enumerated here because
    # we have no stable way to enumerate custom providers without depending
    # on private config formats.
    for p in anthropic claude-code databricks gemini-cli ollama openai; do
        [[ -n "${seen[$p]:-}" ]] && continue
        seen[$p]=1
        if [[ "$p" == "$current" ]]; then
            printf '%s (current)\n' "$p"
        else
            printf '%s\n' "$p"
        fi
    done
}

# Build the model sub-picker list for a given provider. Emits models
# in descending frequency order from the cached session list, filtered
# to sessions whose provider_name == $1. The current override (if set
# via $HONK_MODEL) is tagged with " (current)". Emits nothing if no
# models have been recorded for that provider — the caller should fall
# back to goose's default model in that case rather than blocking the
# picker on an empty list.
honk_model_candidates() {
    local provider="$1"
    local current="${HONK_MODEL:-}"
    local -A seen
    local m

    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        [[ -n "${seen[$m]:-}" ]] && continue
        seen[$m]=1
        if [[ "$m" == "$current" ]]; then
            printf '%s (current)\n' "$m"
        else
            printf '%s\n' "$m"
        fi
    done < <(honk_list_json | jq -r --arg p "$provider" \
        'select(.provider_name == $p) | .model_config.model_name // empty' \
        | sort | uniq -c | sort -rn \
        | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
}
