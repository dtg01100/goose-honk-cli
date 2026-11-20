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

# Resolve a session's working_dir. Returns empty string if unknown.
# Uses honk_list_json so it shares the picker's cached snapshot when one
# is available (set via $HONK_LIST_CACHE). honk_list_json emits NDJSON
# (one object per line), so we `select(.id == $id)` per line instead of
# `.[] | select(.id == $id)`.
#
# `// ""` ensures a missing/null working_dir renders as empty (not the
# literal string "null" that `jq -r` would emit), so callers' `[[ -z
# "$wd" ]]` guards stay correct for sessions without a working_dir.
honk_session_working_dir() {
    local sid="$1"
    honk_list_json 2>/dev/null \
        | jq -r --arg id "$sid" 'select(.id == $id) | .working_dir // ""' \
        || true
}

# Append --provider/--model to the given argv nameref when $HONK_PROVIDER
# / $HONK_MODEL are set. Both env vars are honored independently: setting
# only one appends the corresponding flag, setting neither appends nothing.
#
# Used by honk_action_resume / honk_action_fork / honk_action_new so the
# override logic stays in one place. The picker's Ctrl-P sub-picker sets
# these env vars for the picker invocation; the hun CLI exposes them as
# `--provider` / `--model` flags with matching env vars, and the values
# are passed through to `goose session --resume` / `--fork` / `--name`
# via its own `--provider` / `--model` flags (documented in `goose session
# --help` as "Override the GOOSE_PROVIDER environment variable for this
# run"), making the override a per-invocation setting.
#
# Usage:
#   local -a pm=()
#   honk_pm_args pm
#   exec goose session --resume --session-id "$sid" "${pm[@]}" "$@"
honk_pm_args() {
    local -n out=$1
    [[ -n "${HONK_PROVIDER:-}" ]] && out+=( --provider "$HONK_PROVIDER" )
    [[ -n "${HONK_MODEL:-}" ]]    && out+=( --model    "$HONK_MODEL" )
    # The trailing `: ` is required: with `set -e` enabled (the default in
    # honk and most callers), the function's return value becomes the
    # status of its last command. When neither env var is set, the last
    # `[[ -n "" ]]` returns 1, which would otherwise cause `set -e` to
    # abort the action helper before it reaches the `exec goose` line.
    # The no-op ensures honk_pm_args always returns success.
    :
}

# Resume a session, cd-ing into its original working_dir first so any files
# the user references inside goose resolve naturally.
#
# Note: shift the session id off $@ first — callers pass the id as the first
# argument, and goose would otherwise see it twice (once via --session-id,
# once positionally, which clap rejects as an unrecognized subcommand).
#
# Earlier versions echoed a conversation tail before handing off to goose.
# That read the goose SQLite schema directly (`messages.content_json`),
# which broke whenever goose reshaped its private storage. The metadata
# summary in the fzf preview pane is enough for a user to pick the right
# session; once goose takes over, the user can scroll back inside the TUI.
honk_action_resume() {
    local sid="$1"
    shift
    local wd
    wd=$(honk_session_working_dir "$sid")
    local -a pm=()
    honk_pm_args pm
    if [[ -z "$wd" || ! -d "$wd" ]]; then
        printf 'honk: cannot resolve working_dir for session %s; resuming from %s\n' "$sid" "$PWD" >&2
        exec goose session --resume --session-id "$sid" "${pm[@]}" "$@"
    fi
    printf 'honk: resuming session %s in %s\n' "$sid" "$wd" >&2
    cd "$wd" || { echo "honk: cannot cd to $wd" >&2; return 1; }
    exec goose session --resume --session-id "$sid" "${pm[@]}" "$@"
}

# Fork a session — same as resume, but with --fork so we branch into a copy.
honk_action_fork() {
    local sid="$1"
    shift
    local wd
    wd=$(honk_session_working_dir "$sid")
    local -a pm=()
    honk_pm_args pm
    if [[ -z "$wd" || ! -d "$wd" ]]; then
        exec goose session --resume --fork --session-id "$sid" "${pm[@]}" "$@"
    fi
    printf 'honk: forking session %s (new session starts in %s)\n' "$sid" "$wd" >&2
    cd "$wd" || { echo "honk: cannot cd to $wd" >&2; return 1; }
    exec goose session --resume --fork --session-id "$sid" "${pm[@]}" "$@"
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
    cd "$wd" || { echo "honk: cannot cd to $wd" >&2; return 1; }
    local -a pm=()
    honk_pm_args pm
    exec goose session --name "$name" "${pm[@]}"
}

# Export a session to a JSON file in the current directory.
honk_action_export() {
    local sid="$1"
    local target="${2:-./${sid}.json}"
    # Ctrl-E always targets ./<id>.json; don't silently clobber an earlier
    # export. Pass an explicit second argument to choose another path.
    if [[ -e "$target" ]]; then
        echo "honk: export target already exists: $target (choose another path)" >&2
        return 1
    fi
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
