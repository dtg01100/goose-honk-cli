#!/usr/bin/env bash
# lib/preview.sh — render the fzf preview pane for a selected session.
#
# Invoked by fzf as:  preview.sh <session_id>
#
# Scope: this renders the session's *metadata* (name, working_dir,
# created/updated timestamps, message_count, accumulated_cost) only.
# Earlier versions also rendered message bodies by hitting goose's
# SQLite database directly, but that ties us to the private schema
# (`messages.content_json`, the JSON-part taxonomy, the message id /
# timestamp ordering) and breaks on any goose release that reshapes
# it. The metadata we render here comes from the same `goose session
# list --format json` snapshot the picker already consumes, so the
# preview pane stays decoupled from the storage layer.
#
# Requirements: `jq` for shaping the cached JSON.

set -euo pipefail

[[ -n "${HONK_LIB_PREVIEW_LOADED:-}" ]] && return 0
HONK_LIB_PREVIEW_LOADED=1

# Pull core lib for honk_list_json (used to read the cached snapshot).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/list.sh"

# Render the metadata block. The metadata is rendered with light ANSI
# styling when stdout is a tty (fzf picks up the colors and renders
# them in the preview pane on terminals that support it).
honk_preview_header() {
    local id="$1" meta_json="$2"
    # Use // "" fallbacks so missing/null fields render as empty (not the
    # literal string "null" that `jq -r` emits for null/missing values).
    local name working_dir created updated msg_count cost last_message_at
    local provider_name model_name
    name=$(printf '%s' "$meta_json"       | jq -r '.name              // "(unnamed)"')
    working_dir=$(printf '%s' "$meta_json" | jq -r '.working_dir       // ""')
    created=$(printf '%s' "$meta_json"     | jq -r '.created_at        // ""')
    updated=$(printf '%s' "$meta_json"     | jq -r '.updated_at        // ""')
    last_message_at=$(printf '%s' "$meta_json" | jq -r '.last_message_at // ""')
    msg_count=$(printf '%s' "$meta_json"   | jq -r '.message_count     // 0')
    cost=$(printf '%s' "$meta_json"        | jq -r '.accumulated_cost  // 0')
    # provider_name / model_config.model_name are part of the public
    # `goose session list --format json` shape. Older sessions may not
    # have them; // "" makes those fields render empty rather than "null".
    provider_name=$(printf '%s' "$meta_json" | jq -r '.provider_name           // ""')
    model_name=$(printf '%s' "$meta_json"    | jq -r '.model_config.model_name  // ""')

    printf '\033[1m%s\033[0m  \033[2m(id: %s)\033[0m\n' "$name" "$id"
    printf '  \033[2mworking_dir:\033[0m %s\n'  "$working_dir"
    printf '  \033[2mprovider:\033[0m    %s\n'   "$provider_name"
    printf '  \033[2mmodel:\033[0m       %s\n'   "$model_name"
    printf '  \033[2mcreated:\033[0m    %s\n'    "$created"
    printf '  \033[2mupdated:\033[0m    %s\n'    "$updated"
    if [[ -n "$last_message_at" ]]; then
        printf '  \033[2mlast msg:\033[0m   %s\n'  "$last_message_at"
    fi
    printf '  \033[2mmessages:\033[0m   %s   \033[2mcost:\033[0m $%s\n' "$msg_count" "$cost"
    printf '\n\033[2m(message bodies are not shown — resume the session to read the full conversation)\033[0m\n'
}

# Main entrypoint — prints the preview for one session id.
honk_preview() {
    local sid="${1:-}"
    if [[ -z "$sid" ]]; then
        printf '\033[2m(select a session to preview)\033[0m\n'
        return 0
    fi

    # Pull metadata from the same snapshot the picker rendered its rows
    # from. honk_pick writes that snapshot to $HONK_LIST_CACHE; when the
    # picker is open this lookup is a file read instead of another goose
    # session list roundtrip. fzf invokes this script on every keystroke,
    # so the cache is what keeps the preview pane responsive.
    #
    # honk_list_json emits NDJSON (one object per line) rather than a JSON
    # array, so we `select(.id == $id)` per line instead of `.[] | select'.
    local meta
    meta=$(honk_list_json 2>/dev/null \
        | jq -r --arg id "$sid" 'select(.id == $id)') || true

    if [[ -n "$meta" ]]; then
        honk_preview_header "$sid" "$meta"
    else
        # Selected the synthetic "new session" row, or DB unavailable.
        printf '\033[2m(start a new session — press Enter to choose a name)\033[0m\n'
        return 0
    fi
}

# If executed (not sourced), treat the first arg as a session id.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    honk_preview "$@"
fi
