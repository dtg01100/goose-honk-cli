#!/usr/bin/env bash
# smoke tests for gander — verifies CLI surface without doing anything destructive.
#
# We fake `goose` by injecting a shim earlier on PATH that emits canned JSON
# for `session list` and a noop for everything else.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a fake `goose` binary that lives in TMP/goose.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/goose" <<'EOS'
#!/usr/bin/env bash
# Parse out -l N from args to honor a request for limit.
LIMIT=500
ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"
    case "$arg" in
        -l|--limit)        i=$((i+1)); LIMIT="${ARGS[$i]:-500}" ;;
    esac
    i=$((i+1))
done
case "${1:-} ${2:-}" in
    "session list")
        if [[ "${*:3}" == *"--format"* || "${*:3}" == *"-f json"* ]]; then
            full='[
  {"id":"abc123","name":"demo one","working_dir":"/tmp/demo","updated_at":"2026-08-20T16:50:00Z","created_at":"2026-08-20T16:30:00Z","message_count":4,"accumulated_cost":0.01,"archived_at":null,"last_message_at":"2026-08-20T16:50:00Z"},
  {"id":"def456","name":"demo two","working_dir":"/tmp","updated_at":"2026-08-20T15:00:00Z","created_at":"2026-08-20T10:00:00Z","message_count":12,"accumulated_cost":0.42,"archived_at":null,"last_message_at":"2026-08-20T15:00:00Z"},
  {"id":"xyz789","name":"demo sibling","working_dir":"/tmp/demo-sibling","updated_at":"2026-08-20T14:00:00Z","created_at":"2026-08-20T09:00:00Z","message_count":2,"accumulated_cost":0.05,"archived_at":null,"last_message_at":"2026-08-20T14:00:00Z"}
]'
            echo "$full" | jq -r --argjson l "$LIMIT" '.[0:$l] | tostring' 2>/dev/null \
                || jq -c --argjson l "$LIMIT" '.[]' <<<"$full" | head -"$LIMIT" | jq -s .
        else
            echo "Available sessions:"
            echo "abc123 - demo one - 2026-08-20 16:50:00 UTC - /tmp/demo"
            echo "def456 - demo two - 2026-08-20 15:00:00 UTC - /tmp"
        fi
        ;;
    *) echo "(fake goose) $*" ;;
esac
EOS
chmod +x "$TMP/bin/goose"

export PATH="$TMP/bin:$PATH"

pass() { printf '\033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1"; exit 1; }

# Test: --help
out=$("$ROOT/gander" --help 2>&1)
[[ "$out" == *"USAGE"* ]] || fail "--help missing USAGE"
pass "--help works"

# Test: --list with cwd filter excluding /tmp/demo (when cwd is /var)
out=$(cd /var && "$ROOT/gander" --list 2>&1)
# With pwd_only=1 (default), rows in /tmp/demo should NOT appear when PWD is /var.
if [[ "$out" == *"demo one"* ]]; then
    fail "cwd filter should hide /tmp/demo when PWD is /var. Got: $out"
fi
pass "--list with cwd filter hides off-tree sessions"

# Test: cwd filter is a subtree match, not a prefix match. From /tmp/demo,
# /tmp/demo must match exactly, but the prefix sibling /tmp/demo-sibling and
# the parent /tmp must both be excluded.
out=$(GG_WORKDIR=/tmp/demo "$ROOT/gander" --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "session in /tmp/demo should appear when PWD=/tmp/demo. Got: $out"
if [[ "$out" == *"demo sibling"* ]]; then
    fail "prefix sibling /tmp/demo-sibling must not match subtree /tmp/demo. Got: $out"
fi
if [[ "$out" == *"demo two"* ]]; then
    fail "session in /tmp must not appear when PWD=/tmp/demo. Got: $out"
fi
pass "cwd filter matches subtree, not prefix"

# Test: --list pads the name column so working_dirs align (pad() fix).
out=$(cd /tmp && "$ROOT/gander" --all --list 2>&1)
col_one=$(printf '%s\n' "$out" | grep 'demo one' | grep -bo '/tmp/demo' | head -1 | cut -d: -f1)
col_sib=$(printf '%s\n' "$out" | grep 'demo sibling' | grep -bo '/tmp/demo' | head -1 | cut -d: -f1)
[[ -n "$col_one" && "$col_one" == "$col_sib" ]] \
    || fail "--list should align the working_dir column (got demo one @$col_one, demo sibling @$col_sib). Got: $out"
pass "--list aligns the working_dir column"

# Test: --all overrides filter
out=$(cd /var && "$ROOT/gander" --all --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "--all should include /tmp/demo. Got: $out"
[[ "$out" == *"demo two"* ]] || fail "--all should include /tmp. Got: $out"
[[ "$out" == *"demo sibling"* ]] || fail "--all should include /tmp/demo-sibling. Got: $out"
pass "--all includes everything"

# Test: documented environment defaults are honored.
out=$(cd /var && GG_PWD_ONLY=0 GG_LIMIT=2 "$ROOT/gander" --list 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^abc123\|^def456' || true)
[[ "$n" -eq 2 ]] || fail "GG_PWD_ONLY=0 and GG_LIMIT=2 should emit 2 sessions, got $n: $out"
pass "environment defaults are honored"

# Test: invalid numeric options fail before querying goose.
if "$ROOT/gander" --limit 0 --list >/dev/null 2>&1; then
    fail "--limit 0 should be rejected"
fi
pass "invalid --limit is rejected"

# Test: --json emits 3 objects (run under /tmp so cwd filter lets them through)
out=$(cd /tmp && "$ROOT/gander" --json 2>&1)
n=$(printf '%s' "$out" | grep -c '^{')
[[ "$n" -eq 3 ]] || fail "--json should emit 3 objects under /tmp, got $n"
pass "--json emits correct number of objects"

# Test: -r with an unambiguous fragment resolves and resumes the right session.
# stdin is /dev/null so any multi-match fallback can't hang on fzf.
out=$(cd /tmp && "$ROOT/gander" -r "demo one" </dev/null 2>&1 || true)
[[ "$out" == *"abc123"* ]] || fail "-r 'demo one' should resolve to abc123. Got: $out"
# Regression: the session id must appear exactly once in the resume argv. A
# duplicate positional id makes clap reject it as an unrecognized subcommand
# (goose: "error: unrecognized subcommand '<id>'").
goose_line=$(printf '%s\n' "$out" | grep 'fake goose' || true)
n=$(printf '%s' "$goose_line" | grep -o 'abc123' | wc -l)
[[ "$n" -eq 1 ]] || fail "resume argv contains the session id $n times (should be 1): $goose_line"
pass "-r unambiguous fragment resumes the right session"

# Test: -r with an ambiguous fragment and no tty reports the ambiguity instead
# of silently dropping the pick.
out=$(cd /tmp && "$ROOT/gander" -r demo </dev/null 2>&1 || true)
[[ "$out" == *"matches multiple sessions"* ]] || fail "-r 'demo' should report multiple matches. Got: $out"
pass "-r ambiguous fragment reports multiple matches without a tty"

# Test: gander --limit 1 --all emits exactly 1 row.
out=$(cd /tmp && "$ROOT/gander" --all --limit 1 --list 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^abc123\|^def456' || true)
[[ "$n" -eq 1 ]] || fail "--limit 1 --list should emit 1 session row, got $n: $out"
pass "--limit caps the result count"

# Test: preview renders every part of a multi-part message. sqlite emits the
# body across multiple physical lines (one per embedded newline); the formatter
# must rejoin them instead of dropping everything after the first line.
if command -v sqlite3 >/dev/null 2>&1; then
    dbdir="$TMP/data/goose/sessions"
    mkdir -p "$dbdir"
    sqlite3 "$dbdir/sessions.db" <<'SQL'
CREATE TABLE messages (
    session_id TEXT,
    role TEXT,
    content_json TEXT,
    created_timestamp TEXT,
    id INTEGER
);
INSERT INTO messages VALUES
    ('abc123', 'assistant', '[{"type":"text","text":"hello line one"},{"type":"text","text":"hello line two"}]', '2026-08-20T16:50:00Z', 1),
    ('abc123', 'user',     '[{"type":"text","text":"hello user"}]', '2026-08-20T16:40:00Z', 2);
SQL
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" bash "$ROOT/lib/preview.sh" abc123 2>&1 || true)
    [[ "$out" == *"hello line one"* ]] || fail "preview missing first part. Got: $out"
    [[ "$out" == *"hello line two"* ]] || fail "preview dropped the second part of a multi-part message. Got: $out"
    [[ "$out" == *"hello user"* ]] || fail "preview missing user message. Got: $out"
    [[ "$out" == *'cost:'* && "$out" != *'\$'* ]] \
        || fail "preview header should print cost as \$ (no backslash). Got: $out"
    pass "preview renders multi-part messages and header cost"

    # Test: resume echoes the conversation tail before handing off to goose.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" GG_RESUME_TAIL=4 bash -c '
        source "$1/lib/actions.sh"
        gg_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ "$out" == *"last 4 messages"* ]] || fail "resume tail header missing. Got: $out"
    [[ "$out" == *"hello line two"* ]] || fail "resume tail missing the last message. Got: $out"
    [[ "$out" == *"hello user"* ]] || fail "resume tail missing earlier message. Got: $out"

    # Invalid tail values fall back to the documented default.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" GG_RESUME_TAIL=bad bash -c '
        source "$1/lib/actions.sh"
        gg_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ "$out" == *"using 4"* ]] || fail "invalid GG_RESUME_TAIL should fall back to 4. Got: $out"
    pass "invalid resume tail falls back to the default"

    # GG_RESUME_PREVIEW=0 must suppress the tail entirely.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" GG_RESUME_PREVIEW=0 bash -c '
        source "$1/lib/actions.sh"
        gg_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ -z "$out" ]] || fail "GG_RESUME_PREVIEW=0 should suppress the tail. Got: $out"
    pass "resume echoes the conversation tail (and can be disabled)"
else
    echo "skipping preview/tail tests (sqlite3 not installed)"
fi

printf '\n\033[1mall smoke tests passed\033[0m\n'
