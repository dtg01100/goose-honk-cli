#!/usr/bin/env bash
# lib/actions.sh — actual actions triggered from the picker.
#
# Each helper takes a session id and whatever else it needs. Actions that
# require an interactive session (resume/fork) do `cd` then `exec goose`
# so the wrapper is replaced by the goose TTY.

set -euo pipefail

[[ -n "${HONK_LIB_ACTIONS_LOADED:-}" ]] && return 0
HONK_LIB_ACTIONS_LOADED=1

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/list.sh"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/preview.sh"

# Resolve a session's working_dir. Returns empty string if unknown.
honk_session_working_dir() {
    local sid="$1"
    goose session list -f json -l 500 2>/dev/null \
        | jq -r --arg id "$sid" '.[] | select(.id == $id) | .working_dir' \
        || true
}

# Echo the tail of the conversation before handing off to goose, so the user
# sees precisely what was last said. Reuses the preview renderer; the tail
# stays in the terminal scrollback once goose's TUI takes over.
#
# Tunable via env:
#   HONK_RESUME_PREVIEW  (default 1; set to 0 to skip)
#   HONK_RESUME_TAIL     number of messages to show (default 4)
honk_show_session_tail() {
    local sid="$1"
    [[ "${HONK_RESUME_PREVIEW:-1}" != "1" ]] && return 0
    local limit="${HONK_RESUME_TAIL:-4}"
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        echo "honk: HONK_RESUME_TAIL must be a non-negative integer; using 4" >&2
        limit=4
    fi
    printf '\n\033[2m── last %s messages ────────────────────────────\033[0m\n' "$limit"
    HONK_PREVIEW_MSG_LIMIT="$limit" honk_render_messages "$sid" || true
    printf '\033[2m──────────────────────────────────────────────────\033[0m\n\n'
}

# Resume a session, cd-ing into its original working_dir first so any files
# the user references inside goose resolve naturally.
#
# Note: shift the session id off $@ first — callers pass the id as the first
# argument, and goose would otherwise see it twice (once via --session-id,
# once positionally, which clap rejects as an unrecognized subcommand).
honk_action_resume() {
    local sid="$1"
    shift
    local wd
    wd=$(honk_session_working_dir "$sid")
    if [[ -z "$wd" || ! -d "$wd" ]]; then
        printf 'honk: cannot resolve working_dir for session %s; resuming from %s\n' "$sid" "$PWD" >&2
        exec goose session --resume --session-id "$sid" "$@"
    fi
    printf 'honk: resuming session %s in %s\n' "$sid" "$wd" >&2
    cd "$wd"
    honk_show_session_tail "$sid"
    exec goose session --resume --session-id "$sid" "$@"
}

# Fork a session — same as resume, but with --fork so we branch into a copy.
honk_action_fork() {
    local sid="$1"
    shift
    local wd
    wd=$(honk_session_working_dir "$sid")
    if [[ -z "$wd" || ! -d "$wd" ]]; then
        exec goose session --resume --fork --session-id "$sid" "$@"
    fi
    printf 'honk: forking session %s (new session starts in %s)\n' "$sid" "$wd" >&2
    cd "$wd"
    honk_show_session_tail "$sid"
    exec goose session --resume --fork --session-id "$sid" "$@"
}

# Start a brand new session in the working_dir of the selected row.
# The caller passes an optional session name; we prompt if missing.
honk_action_new() {
    local wd="${1:-$PWD}"
    local name="${2:-}"
    if [[ -z "$name" ]]; then
        read -r -p "name for new session in $wd: " name </dev/tty || true
    fi
    if [[ -z "$name" ]]; then
        echo "honk: aborting — empty session name" >&2
        return 1
    fi
    cd "$wd"
    exec goose session --name "$name"
}

# Export a session to a JSON file in the current directory.
honk_action_export() {
    local sid="$1"
    local target="${2:-./${sid}.json}"
    # goose session export takes -o/--output for the destination file.
    goose session export --session-id "$sid" --output "$target"
    printf 'honk: exported %s → %s\n' "$sid" "$target" >&2
}

# Delete a session after a confirmation prompt.
honk_action_delete() {
    local sid="$1"
    local confirm
    read -r -p "delete session $sid? [y/N] " confirm </dev/tty || true
    case "$confirm" in
        y|Y|yes|YES) ;;
        *)           echo "honk: aborting delete" >&2; return 1 ;;
    esac
    goose session remove --session-id "$sid"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    action="${1:-}"
    shift || true
    case "$action" in
        resume) honk_action_resume "$@" ;;
        fork)   honk_action_fork   "$@" ;;
        new)    honk_action_new    "$@" ;;
        export) honk_action_export "$@" ;;
        delete) honk_action_delete "$@" ;;
        *)      echo "usage: actions.sh {resume|fork|new|export|delete} <session_id> [args]" >&2
                exit 2 ;;
    esac
fi
