#!/usr/bin/env bash
# Smoke tests for Honk — verify the CLI surface without doing anything destructive.
#
# We fake `goose` by injecting a shim earlier on PATH that emits canned JSON
# for `session list` and a noop for everything else.

set -euo pipefail

# Defensively clear any HONK_* env vars leaked into this shell (e.g. from
# running inside a resumed goose session started via honk). The tests below
# rely on the documented defaults and on cwd/$PWD; leaked vars would silently
# change the cwd filter, the grep filter, the picker cache, etc.
while IFS= read -r var; do
    unset "$var"
done < <(env | awk -F= '/^HONK_/ {print $1}')

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
out=$("$ROOT/honk" --help 2>&1)
[[ "$out" == *"USAGE"* ]] || fail "--help missing USAGE"
pass "--help works"

# Test: --version reports the version and exits cleanly. The version is
# derived from git describe when the checkout is a git working tree, so
# accept any non-empty output that starts with "honk ".
out=$("$ROOT/honk" --version 2>&1)
[[ "$out" == honk\ * ]] || fail "--version should print 'honk <version>'. Got: $out"
[[ -n "${out#honk }" ]] || fail "--version should print a non-empty version. Got: $out"
# Must exit 0; if it doesn't, the version flag is broken.
"$ROOT/honk" --version >/dev/null 2>&1 || fail "--version should exit 0"
pass "--version prints the version"

# Test: --version is also accepted as a short flag.
out=$("$ROOT/honk" -V 2>&1)
[[ "$out" == honk\ * ]] || fail "-V should print 'honk <version>'. Got: $out"
pass "--version short flag (-V) works"

# Test: --list with cwd filter excluding /tmp/demo (when cwd is /var)
out=$(cd /var && "$ROOT/honk" --list 2>&1)
# With pwd_only=1 (default), rows in /tmp/demo should NOT appear when PWD is /var.
if [[ "$out" == *"demo one"* ]]; then
    fail "cwd filter should hide /tmp/demo when PWD is /var. Got: $out"
fi
pass "--list with cwd filter hides off-tree sessions"

# Test: cwd filter is a subtree match, not a prefix match. From /tmp/demo,
# /tmp/demo must match exactly, but the prefix sibling /tmp/demo-sibling and
# the parent /tmp must both be excluded.
out=$(HONK_WORKDIR=/tmp/demo "$ROOT/honk" --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "session in /tmp/demo should appear when PWD=/tmp/demo. Got: $out"
if [[ "$out" == *"demo sibling"* ]]; then
    fail "prefix sibling /tmp/demo-sibling must not match subtree /tmp/demo. Got: $out"
fi
if [[ "$out" == *"demo two"* ]]; then
    fail "session in /tmp must not appear when PWD=/tmp/demo. Got: $out"
fi
pass "cwd filter matches subtree, not prefix"

# Test: --list pads the name column so working_dirs align (pad() fix).
out=$(cd /tmp && "$ROOT/honk" --all --list 2>&1)
col_one=$(printf '%s\n' "$out" | grep 'demo one' | grep -bo '/tmp/demo' | head -1 | cut -d: -f1)
col_sib=$(printf '%s\n' "$out" | grep 'demo sibling' | grep -bo '/tmp/demo' | head -1 | cut -d: -f1)
[[ -n "$col_one" && "$col_one" == "$col_sib" ]] \
    || fail "--list should align the working_dir column (got demo one @$col_one, demo sibling @$col_sib). Got: $out"
pass "--list aligns the working_dir column"

# Test: --all overrides filter
out=$(cd /var && "$ROOT/honk" --all --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "--all should include /tmp/demo. Got: $out"
[[ "$out" == *"demo two"* ]] || fail "--all should include /tmp. Got: $out"
[[ "$out" == *"demo sibling"* ]] || fail "--all should include /tmp/demo-sibling. Got: $out"
pass "--all includes everything"

# Test: documented environment defaults are honored.
out=$(cd /var && HONK_PWD_ONLY=0 HONK_LIMIT=2 "$ROOT/honk" --list 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^abc123\|^def456' || true)
[[ "$n" -eq 2 ]] || fail "HONK_PWD_ONLY=0 and HONK_LIMIT=2 should emit 2 sessions, got $n: $out"
pass "environment defaults are honored"

# Test: invalid numeric options fail before querying goose.
if "$ROOT/honk" --limit 0 --list >/dev/null 2>&1; then
    fail "--limit 0 should be rejected"
fi
pass "invalid --limit is rejected"

# Test: --json emits 3 objects (run under /tmp so cwd filter lets them through)
out=$(cd /tmp && "$ROOT/honk" --json 2>&1)
n=$(printf '%s' "$out" | grep -c '^{')
[[ "$n" -eq 3 ]] || fail "--json should emit 3 objects under /tmp, got $n"
pass "--json emits correct number of objects"

# Test: -r with an unambiguous fragment resolves and resumes the right session.
# stdin is /dev/null so any multi-match fallback can't hang on fzf.
out=$(cd /tmp && "$ROOT/honk" -r "demo one" </dev/null 2>&1 || true)
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
out=$(cd /tmp && "$ROOT/honk" -r demo </dev/null 2>&1 || true)
[[ "$out" == *"matches multiple sessions"* ]] || fail "-r 'demo' should report multiple matches. Got: $out"
pass "-r ambiguous fragment reports multiple matches without a tty"

# Test: Honk --limit 1 --all emits exactly 1 row.
out=$(cd /tmp && "$ROOT/honk" --all --limit 1 --list 2>&1)
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

    # Test: preview preserves literal `|` characters in message bodies. The
    # sqlite-to-format pipeline used to use `|` as a column separator and
    # `IFS='|' read` to split the role label from the body, so a body like
    # `a | b | c` would be shredded into three pieces. The fake `goose`
    # doesn't know about pipe123, so seed the metadata through the cache
    # (which the picker uses anyway) and let sqlite provide the body.
    sqlite3 "$dbdir/sessions.db" <<'SQL'
INSERT INTO messages VALUES
    ('pipe123', 'assistant', '[{"type":"text","text":"pipe payload: a | b | c"}]', '2026-08-20T16:55:00Z', 3),
    ('pipe123', 'user',      '[{"type":"text","text":"echo a | b"}]',                '2026-08-20T16:50:00Z', 4);
SQL
    pipe_cache=$(mktemp "${TMPDIR:-/tmp}/honk-pipe.XXXXXX.json")
    printf '%s\n' \
        '{"id":"pipe123","name":"pipe test","working_dir":"/tmp","updated_at":"2026-08-20T16:55:00Z","message_count":2,"accumulated_cost":0,"archived_at":null,"last_message_at":"2026-08-20T16:55:00Z"}' \
        > "$pipe_cache"
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" HONK_LIST_CACHE="$pipe_cache" \
        bash "$ROOT/lib/preview.sh" pipe123 2>&1 || true)
    rm -f "$pipe_cache"
    [[ "$out" == *"pipe payload: a | b | c"* ]] \
        || fail "preview mangled body containing |. Got: $out"
    [[ "$out" == *"echo a | b"* ]] \
        || fail "preview mangled user body containing |. Got: $out"
    # Regression sanity: the role label must still be present and not
    # absorbed into the body.
    [[ "$out" == *"▸ assistant"* ]] \
        || fail "preview missing assistant role label. Got: $out"
    [[ "$out" == *"▸ user"* ]] \
        || fail "preview missing user role label. Got: $out"
    pass "preview preserves literal '|' in message bodies"

    # Test: honk_list_json honors HONK_LIST_CACHE. When the cache is set
    # and readable, honk_list_json reads from it instead of round-tripping
    # to goose. Stub the cache with a known session and verify it
    # round-trips through the list filter unchanged.
    cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-cache.XXXXXX.json")
    printf '%s\n' \
        '{"id":"cached1","name":"from cache","working_dir":"/tmp","updated_at":"2026-08-20T16:00:00Z","message_count":0,"accumulated_cost":0,"archived_at":null,"last_message_at":"2026-08-20T16:00:00Z"}' \
        > "$cache_file"
    out=$(HONK_LIST_CACHE="$cache_file" HONK_PWD_ONLY=0 \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" | head -1)
    [[ "$out" == *"\"from cache\""* ]] \
        || fail "HONK_LIST_CACHE should short-circuit goose. Got: $out"
    # The fake goose should not have been invoked at all — the cache is
    # only read from, never written to. Confirm the cache file timestamp
    # did not change.
    before=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file")
    sleep 1
    out=$(HONK_LIST_CACHE="$cache_file" HONK_PWD_ONLY=0 \
        bash -c 'source "$1/lib/list.sh"; honk_list_json > /dev/null' _ "$ROOT")
    after=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file")
    [[ "$before" == "$after" ]] \
        || fail "HONK_LIST_CACHE should be read-only; the file was rewritten"
    rm -f "$cache_file"
    pass "honk_list_json honors HONK_LIST_CACHE"

    # Test: honk_session_working_dir uses the cache too. It used to call
    # `goose session list -f json -l 500` directly with a hardcoded limit,
    # which could miss the session on a long list. After the change, it
    # reads from honk_list_json (and therefore the cache).
    cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-cache.XXXXXX.json")
    printf '%s\n' \
        '{"id":"abc123","name":"from cache","working_dir":"/tmp/demo"}' \
        > "$cache_file"
    out=$(HONK_LIST_CACHE="$cache_file" \
        bash -c 'source "$1/lib/actions.sh"; honk_session_working_dir abc123' _ "$ROOT")
    [[ "$out" == "/tmp/demo" ]] \
        || fail "honk_session_working_dir should read from cache. Got: $out"
    rm -f "$cache_file"
    pass "honk_session_working_dir reads from the cache"

    # Test: resume echoes the conversation tail before handing off to goose.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" HONK_RESUME_TAIL=4 bash -c '
        source "$1/lib/actions.sh"
        honk_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ "$out" == *"last 4 messages"* ]] || fail "resume tail header missing. Got: $out"
    [[ "$out" == *"hello line two"* ]] || fail "resume tail missing the last message. Got: $out"
    [[ "$out" == *"hello user"* ]] || fail "resume tail missing earlier message. Got: $out"

    # Invalid tail values fall back to the documented default.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" HONK_RESUME_TAIL=bad bash -c '
        source "$1/lib/actions.sh"
        honk_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ "$out" == *"using 4"* ]] || fail "invalid HONK_RESUME_TAIL should fall back to 4. Got: $out"
    pass "invalid resume tail falls back to the default"

    # HONK_RESUME_PREVIEW=0 must suppress the tail entirely.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" HONK_RESUME_PREVIEW=0 bash -c '
        source "$1/lib/actions.sh"
        honk_show_session_tail abc123
    ' _ "$ROOT" 2>&1 || true)
    [[ -z "$out" ]] || fail "HONK_RESUME_PREVIEW=0 should suppress the tail. Got: $out"
    pass "resume echoes the conversation tail (and can be disabled)"

    # Seed an extra session whose messages contain a unique token so we
    # can verify grep filtering end-to-end. The fake goose doesn't know
    # about it, so we go through the HONK_LIST_CACHE path that the
    # picker uses in practice.
    sqlite3 "$dbdir/sessions.db" <<'SQL'
INSERT INTO messages VALUES
    ('grep1', 'user', '[{"type":"text","text":"this is a uniquetoken message"}]', '2026-08-20T17:00:00Z', 100),
    ('grep1', 'assistant', '[{"type":"text","text":"reply with uniquetoken"}]', '2026-08-20T17:00:01Z', 101);
SQL
    grep_cache=$(mktemp "${TMPDIR:-/tmp}/honk-grep.XXXXXX.json")
    printf '%s\n' \
        '{"id":"abc123","name":"demo one","working_dir":"/tmp/demo"}' \
        '{"id":"grep1","name":"grep target","working_dir":"/tmp/grep"}' \
        > "$grep_cache"

    # Test: HONK_GREP filters session list to IDs whose messages match.
    # When the cache is set, honk_list_json reads from it instead of
    # goose, so we just need the IDs in the cache and the messages in
    # sqlite. Only "grep1" has messages containing "uniquetoken".
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="uniquetoken" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 1 ]] || fail "HONK_GREP=uniquetoken should match 1 session, got $n: $out"
    [[ "$out" == *"grep1"* ]] || fail "HONK_GREP=uniquetoken should match grep1. Got: $out"
    [[ "$out" != *"abc123"* ]] || fail "HONK_GREP=uniquetoken should NOT match abc123. Got: $out"
    pass "HONK_GREP filters by message content"

    # Test: case-insensitive match. The default is COLLATE NOCASE so
    # "UNIQUETOKEN" should match the same sessions as "uniquetoken".
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="UNIQUETOKEN" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    [[ "$out" == *"grep1"* ]] || fail "HONK_GREP=UNIQUETOKEN should case-insensitively match grep1. Got: $out"
    pass "HONK_GREP is case-insensitive"

    # Test: no matches → empty output (and the picker would just show
    # nothing rather than crashing).
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="definitely_not_in_any_message" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 0 ]] || fail "HONK_GREP=missing should match nothing, got $n: $out"
    pass "HONK_GREP returns empty when no matches"

    # Test: empty HONK_GREP disables the filter (same semantics as
    # unset). All sessions in the cache should pass through.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 2 ]] || fail "HONK_GREP='' should match all 2 sessions, got $n: $out"
    pass "empty HONK_GREP disables the filter"

    # Test: query with LIKE wildcards is escaped so '%' or '_' do not
    # silently match every session. The SQL `LIKE` pattern treats them
    # as the literal characters typed by the user.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="%" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 0 ]] || fail "HONK_GREP=% should NOT match (wildcard escaped), got $n: $out"
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cache" HONK_GREP="_" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 0 ]] || fail "HONK_GREP=_ should NOT match (wildcard escaped), got $n: $out"
    pass "HONK_GREP escapes LIKE wildcards in the query"

    # Test: queries containing SQL single quotes are escaped. The
    # escape uses sqlite's standard '' doubling, so the query still
    # matches any string containing the literal apostrophe.
    sqlite3 "$dbdir/sessions.db" <<'SQL'
INSERT INTO messages VALUES
    ('quote1', 'user', '[{"type":"text","text":"it''s a test"}]', '2026-08-20T17:05:00Z', 200);
SQL
    quote_cache=$(mktemp "${TMPDIR:-/tmp}/honk-quote.XXXXXX.json")
    printf '%s\n' \
        '{"id":"quote1","name":"quote target","working_dir":"/tmp/quote"}' \
        > "$quote_cache"
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$quote_cache" HONK_GREP="it's" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1)
    [[ "$out" != *"syntax error"* ]] || fail "HONK_GREP with quote should not crash. Got: $out"
    [[ "$out" == *"quote1"* ]] || fail "HONK_GREP=\"it's\" should match quote1. Got: $out"
    rm -f "$quote_cache"

    # Test: grep failures (no sqlite3) surface as a clear error, not a
    # silent empty list. Skip when sqlite3 is here but pretend it isn't
    # by pointing at a non-existent DB.
    mkdir -p "$TMP/no-sqlite"
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/no-sqlite" \
        HONK_GREP="anything" \
        bash -c 'source "$1/lib/list.sh"; honk_list_json' _ "$ROOT" 2>&1 || true)
    [[ "$out" == *"goose DB"* || "$out" == *"sqlite3"* ]] \
        || fail "HONK_GREP with missing DB should error clearly. Got: $out"
    pass "HONK_GREP surfaces a clear error when the DB is unreadable"

    rm -f "$grep_cache"

    # Test: --grep CLI flag is parsed and honored end-to-end through
    # the main honk entrypoint. The fake goose doesn't know about
    # grep1, so we pre-populate the cache (the same path the picker
    # uses) and let sqlite provide the message bodies. The grep
    # filter is applied on top of the cache regardless of where the
    # list came from.
    grep_cli_cache=$(mktemp "${TMPDIR:-/tmp}/honk-grep-cli.XXXXXX.json")
    printf '%s\n' \
        '{"id":"abc123","name":"demo one","working_dir":"/tmp/demo"}' \
        '{"id":"grep1","name":"grep target","working_dir":"/tmp/grep"}' \
        > "$grep_cli_cache"
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cli_cache" \
        "$ROOT/honk" --grep uniquetoken --all --json 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 1 ]] || fail "--grep uniquetoken should match 1 session. Got: $n: $out"
    [[ "$out" == *"grep1"* ]] || fail "--grep uniquetoken should match grep1. Got: $out"
    pass "--grep CLI flag filters by message content"

    # Test: --no-grep CLI flag clears the filter so the full list
    # (modulo other filters) passes through.
    out=$(cd /tmp && XDG_DATA_HOME="$TMP/data" \
        HONK_LIST_CACHE="$grep_cli_cache" \
        "$ROOT/honk" --grep uniquetoken --no-grep --all --json 2>&1)
    n=$(printf '%s\n' "$out" | grep -c '^{' || true)
    [[ "$n" -eq 2 ]] || fail "--no-grep should restore the full list (2 sessions). Got: $n: $out"
    rm -f "$grep_cli_cache"
    pass "--no-grep clears the grep filter"
else
    echo "skipping preview/tail tests (sqlite3 not installed)"
fi

# Regression: invoking the interactive picker without a tty must not crash
# with "cache: unbound variable" from the EXIT trap. The picker sets up a
# `mktemp` cache as a function-local variable in honk_pick(); if the trap
# string references that local, bash dereferences it after the function
# returns and `set -u` aborts the script. Run honk with stdin/stdout
# redirected so the tty guard inside honk_pick fires, and confirm exit
# code is 1 (the documented "no tty" failure) — not 2 and not a set -u crash.
out=$(bash "$ROOT/honk" </dev/null >/dev/null 2>&1; echo "rc=$?")
[[ "$out" == "rc=1" ]] \
    || fail "non-tty picker should exit 1 cleanly; got: $out"
err=$(bash "$ROOT/honk" </dev/null 2>&1; echo "rc=$?")
[[ "$err" == *"interactive picker needs a tty"* ]] \
    || fail "non-tty picker should print tty guidance; got: $err"
[[ "$err" != *"unbound variable"* ]] \
    || fail "non-tty picker must not trip set -u in its EXIT trap; got: $err"
pass "non-tty picker exits cleanly without crashing the EXIT trap"

# Regression: honk_pick creates an empty tempfile with mktemp() and then
# writes the session list into it with the first call to honk_list_json.
# An earlier version exported HONK_LIST_CACHE *before* that first call, so
# honk_list_json short-circuited to the empty (but readable) mktemp file,
# skipped the goose roundtrip entirely, and left the cache — and therefore
# the entire picker — empty: only the synthetic "new session" rows showed
# up. End-to-end through honk_pick: the picker populates the cache before
# its tty guard fires, so we patch the EXIT trap to preserve the cache and
# assert that it actually contains session JSON after the run. The buggy
# version leaves the cache at zero bytes.
captured=$(mktemp "${TMPDIR:-/tmp}/honk-pick-cache.XXXXXX.json")
# Copy the project into a tmp dir so the patched honk can find its lib/.
# Patch honk_pick's EXIT trap to copy the cache to $captured before
# removing it. The trap string is stable across versions; using @
# as the sed delimiter keeps the `||` in the replacement from colliding
# with the separator.
work=$(mktemp -d "${TMPDIR:-/tmp}/honk-pick.XXXXXX")
cp "$ROOT/honk" "$work/honk"
cp -r "$ROOT/lib" "$work/lib"
sed "s@trap 'rm -f \"\\\${HONK_LIST_CACHE:-}\"' EXIT@trap 'cp \"\\\${HONK_LIST_CACHE:-}\" \"${captured}\" 2>/dev/null || true; rm -f \"\\\${HONK_LIST_CACHE:-}\"' EXIT@" \
    "$work/honk" > "$work/honk.tmp"
mv "$work/honk.tmp" "$work/honk"
chmod +x "$work/honk"
HONK_PWD_ONLY=0 bash "$work/honk" </dev/null >/dev/null 2>&1 || true
rm -rf "$work"
cache_bytes=$(wc -c <"$captured" 2>/dev/null || echo 0)
n=$(grep -c '^{' "$captured" 2>/dev/null || true)
[[ "$cache_bytes" -gt 1 ]] \
    || fail "honk_pick should populate its cache; got $cache_bytes bytes (picker was empty under the bug)"
[[ "$n" -ge 1 ]] \
    || fail "honk_pick cache should contain at least one session JSON object; got $n: $(cat "$captured")"
rm -f "$captured"
pass "honk_pick populates the picker cache end-to-end"

printf '\n\033[1mall smoke tests passed\033[0m\n'
