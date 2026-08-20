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
#   HONK_ASCENDING (default 0)
#   HONK_ARCHIVED  (default 0; set to 1 to include archived sessions)
#   HONK_PWD_ONLY  (default 1; set to 0 to include all sessions)
#   HONK_WORKDIR   (override the filter; default: $PWD)

set -euo pipefail

# Avoid double-sourcing guard
[[ -n "${HONK_LIB_LIST_LOADED:-}" ]] && return 0
HONK_LIB_LIST_LOADED=1

honk_is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Apply the message-content grep filter to a raw NDJSON session list
# (the shape honk_list_json emits). Returns the filtered NDJSON on
# stdout. Returns 1 if the grep query itself fails (e.g. sqlite3 is
# missing or the DB is unreadable).
#
# The grep pass is applied on top of whatever the caller already
# produced — fresh fetch from goose, cached snapshot, etc. — so the
# filter is honored uniformly regardless of cache state.
honk_apply_grep() {
    local raw="$1"
    if [[ -z "${HONK_GREP:-}" ]]; then
        printf '%s\n' "$raw"
        return 0
    fi
    local match_ids
    match_ids=$(honk_grep_session_ids "${HONK_GREP}") || return 1
    # NDJSON of session IDs → JSON array of strings. `-s` slurps,
    # `map(select(. != ""))` drops any blank lines from a final
    # newline. An empty grep result yields `[]`, which `index()` never
    # matches — the picker ends up empty, which is the right answer
    # for "no message contains this query".
    match_ids=$(printf '%s' "$match_ids" | jq -R . | jq -s 'map(select(. != ""))')
    printf '%s\n' "$raw" | jq -r --argjson ids "$match_ids" \
        'select(.id as $id | $ids | index($id))'
}

# Look up session IDs whose messages contain $1 (case-insensitive
# substring match against the JSON content of all message parts).
# Emits NDJSON of session IDs on stdout; one per line. Empty stdout
# means no matches.
#
# The query is escaped for SQL string-literal embedding (single quotes
# doubled) and for LIKE-pattern embedding (%, _, \ escaped with
# backslash — the same character the SQL ESCAPE clause uses), so a
# user's query containing quotes or LIKE wildcards is safe.
#
# Requires sqlite3. Returns 1 if sqlite3 is missing or the DB is
# unreadable; callers should treat that as a hard error so a user who
# explicitly asked for content search is told why it didn't work.
honk_grep_session_ids() {
    local query="$1"
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "honk: grep requires sqlite3" >&2
        return 1
    fi
    local db
    db=$(honk_db_path)
    [[ -r "$db" ]] || { echo "honk: cannot read goose DB at $db" >&2; return 1; }
    # Escape order matters: backslash first, then % and _, so the
    # backslashes we introduce for the LIKE wildcards don't get
    # double-escaped by the backslash rule.
    local q
    q=$(printf '%s' "$query" \
        | sed -e "s/'/''/g" \
              -e 's/\\/\\\\/g' \
              -e 's/%/\\%/g' \
              -e 's/_/\\_/g')
    sqlite3 "$db" <<SQL
SELECT DISTINCT session_id FROM messages WHERE content_json LIKE '%${q}%' ESCAPE '\' COLLATE NOCASE
SQL
}

# Resolve the goose sessions DB path. Honor $GOOSE_SHARED_SESSION_DIR if the
# user has one, but otherwise derive from goose info.
honk_db_path() {
    # Prefer goose's own idea of the path. If `goose info` ever changes shape,
    # we fall back to the well-known XDG location.
    local path
    if path=$(goose info 2>/dev/null | awk -F': *' '/Sessions DB/ {print $2; exit}'); then
        path="${path//[[:space:]]/}"
        if [[ -n "$path" && -r "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    fi
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/goose/sessions/sessions.db"
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
    # The grep filter is applied on top of either path so HONK_GREP
    # works uniformly.
    if [[ -n "${HONK_LIST_CACHE:-}" && -r "${HONK_LIST_CACHE}" ]]; then
        honk_apply_grep "$(cat "${HONK_LIST_CACHE}")"
        return 0
    fi

    local limit="${HONK_LIMIT:-50}"
    local ascending="${HONK_ASCENDING:-}"
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
    command -v goose >/dev/null 2>&1 || {
        echo "honk: goose is required to list sessions" >&2
        return 1
    }

    local args=( -f json -l "$limit" )
    [[ -n "$ascending" ]] && args+=( --ascending )

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
    # Sort updated_at desc if not already (goose default is desc).
    if [[ -z "$ascending" ]]; then
        # goose already returns desc — keep stable.
        :
    fi
    jq_filter+=" | @json"

    # Apply the cwd/archive filters in jq, then layer the grep filter
    # on top via honk_apply_grep — the grep hits sqlite separately so
    # the jq filter chain stays clean and the same grep pass can be
    # applied to cached lists.
    honk_apply_grep "$(printf '%s\n' "$raw" | jq "${jq_args[@]}" "$jq_filter")"
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
