#!/usr/bin/env bash
# lib/preview.sh — render the fzf preview pane for a selected session.
#
# Invoked by fzf as:  preview.sh <session_id>
#
# Strategy: the picker rows were built from `goose session list --format json`,
# but that output doesn't carry the message bodies we want to show in the
# preview. So we hit sqlite directly here.
#
# Requirements: `sqlite3` CLI, `jq` for any final shaping.

set -euo pipefail

[[ -n "${GG_LIB_PREVIEW_LOADED:-}" ]] && return 0
GG_LIB_PREVIEW_LOADED=1

# Pull core lib for gg_db_path.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/list.sh"

# Maximum number of messages to render in the preview tail.
GG_PREVIEW_MSG_LIMIT="${GG_PREVIEW_MSG_LIMIT:-8}"
if ! [[ "$GG_PREVIEW_MSG_LIMIT" =~ ^[0-9]+$ ]]; then
    echo "gander: GG_PREVIEW_MSG_LIMIT must be a non-negative integer; using 8" >&2
    GG_PREVIEW_MSG_LIMIT=8
fi

# Maximum total bytes of text to render; we truncate last-message text so the
# preview doesn't blow up on very long assistant turns.
GG_PREVIEW_TEXT_CAP="${GG_PREVIEW_TEXT_CAP:-200}"
if ! [[ "$GG_PREVIEW_TEXT_CAP" =~ ^[0-9]+$ ]]; then
    echo "gander: GG_PREVIEW_TEXT_CAP must be a non-negative integer; using 200" >&2
    GG_PREVIEW_TEXT_CAP=200
fi

# Use ANSI dim/bold for nice formatting when stdout is a tty (fzf will pick
# up the colors and render them in the preview pane on terminals that
# support it).
gg_preview_header() {
    local id="$1" meta_json="$2"
    printf '\033[1m%s\033[0m  \033[2m(id: %s)\033[0m\n' \
        "$(printf '%s' "$meta_json" | jq -r '.name // "(unnamed)"')" \
        "$id"
    printf '  \033[2mworking_dir:\033[0m %s\n'  "$(printf '%s' "$meta_json" | jq -r '.working_dir')"
    printf '  \033[2mcreated:\033[0m    %s\n'    "$(printf '%s' "$meta_json" | jq -r '.created_at')"
    printf '  \033[2mupdated:\033[0m    %s\n'    "$(printf '%s' "$meta_json" | jq -r '.updated_at')"
    printf '  \033[2mmessages:\033[0m   %s   \033[2mcost:\033[0m $%s\n' \
        "$(printf '%s' "$meta_json" | jq -r '.message_count // 0')" \
        "$(printf '%s' "$meta_json" | jq -r '.accumulated_cost // 0')"
    printf '\n\033[1m── last %s messages ────────────────────────────\033[0m\n' \
        "$GG_PREVIEW_MSG_LIMIT"
}

# Emits rows of "<role_label>|<body>" on stdout for the selected session.
gg_render_messages_rows() {
    local sid="$1"
    if ! command -v sqlite3 >/dev/null 2>&1; then
        printf '\033[2m(sqlite3 is required for message previews)\033[0m\n'
        return 0
    fi
    local db
    db=$(gg_db_path)
    [[ -r "$db" ]] || { printf '\033[2m(no goose DB accessible at %s)\033[0m\n' "$db"; return 0; }

    # Sanitize the session id for SQL-string literal embedding: it's a goose
    # internal key (e.g. "20260820_9"), so we trust it, but we still double
    # any single quotes to be safe.
    local sid_escaped
    sid_escaped=$(printf "%s" "$sid" | sed "s/'/''/g")

    sqlite3 -separator '|' "$db" <<SQL
WITH ranked AS (
    SELECT m.role, m.content_json, m.created_timestamp
    FROM messages AS m
    WHERE m.session_id = '${sid_escaped}'
    ORDER BY m.created_timestamp DESC, m.id DESC
    LIMIT ${GG_PREVIEW_MSG_LIMIT}
)
SELECT
    CASE role
        WHEN 'user'      THEN '▸ user'
        WHEN 'assistant' THEN '▸ assistant'
        ELSE                '▸ ' || role
    END AS role_label,
    trim(
        coalesce((
            SELECT group_concat(
                CASE json_extract(value, '\$.type')
                    WHEN 'text'    THEN substr(json_extract(value, '\$.text'), 1, ${GG_PREVIEW_TEXT_CAP})
                    WHEN 'thinking' THEN '(thinking) ' || substr(json_extract(value, '\$.thinking'), 1, ${GG_PREVIEW_TEXT_CAP})
                    WHEN 'toolRequest'  THEN '[tool:' || coalesce(json_extract(value, '\$.name'), '?') || ']'
                    WHEN 'toolResponse' THEN '[tool-result]'
                    WHEN 'image'    THEN '[image]'
                    ELSE '[other]'
                END, char(10))
            FROM json_each(ranked.content_json)
        ), '')
    ) AS body
FROM ranked;
SQL
}

# Pretty-prints rows emitted by gg_render_messages_rows.
#
# sqlite emits one physical line per embedded newline, so a multi-part body
# arrives as a "▸ role|part1" line followed by bare continuation lines. Read
# them as one record: anything not starting with a "▸ " label continues the
# current body instead of being dropped.
gg_format_message_rows() {
    local label="" body="" first rest
    gg_flush_message() {
        [[ -z "$body" ]] && return
        printf '\n\033[1;36m%s\033[0m\n' "$label"
        printf '%s' "$body" | fold -s -w 90 | sed 's/^/  /'
    }
    while IFS='|' read -r first rest; do
        if [[ "$first" == "▸ "* ]]; then
            gg_flush_message
            label="$first"
            body="${rest:-}"
        else
            # Continuation line of a multi-part body.
            body+=$'\n'"$first"
            [[ -n "${rest:-}" ]] && body+='|'"$rest"
        fi
    done
    gg_flush_message
}

gg_render_messages() {
    gg_render_messages_rows "$@" | gg_format_message_rows
}

# Main entrypoint — prints the full preview for one session id.
gg_preview() {
    local sid="${1:-}"
    if [[ -z "$sid" ]]; then
        printf '\033[2m(select a session to preview)\033[0m\n'
        return 0
    fi

    # Pull metadata cheaply — goose session list is already cached, and for a
    # single id it's fast enough.
    local meta
    meta=$(goose session list -f json -l 500 2>/dev/null \
        | jq -r --arg id "$sid" '.[] | select(.id == $id)') || true

    if [[ -n "$meta" ]]; then
        gg_preview_header "$sid" "$meta"
    else
        # Selected the synthetic "new session" row, or DB unavailable.
        printf '\033[2m(start a new session — press Enter to choose a name)\033[0m\n'
        return 0
    fi

    gg_render_messages "$sid"
}

# If executed (not sourced), treat the first arg as a session id.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    gg_preview "$@"
fi
