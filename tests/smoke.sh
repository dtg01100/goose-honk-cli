#!/usr/bin/env bash
# Smoke tests for Honk — verify the CLI surface without doing anything destructive.
#
# We fake `goose` by injecting a shim earlier on PATH that emits canned JSON
# for `session list` and a noop for everything else.

set -euo pipefail

# Defensively clear any HONK_* env vars leaked into this shell (e.g. from
# running inside a resumed goose session started via honk). The tests below
# rely on the documented defaults and on cwd/$PWD; leaked vars would silently
# change the cwd filter, the picker cache, etc.
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
  {"id":"abc123","name":"demo one","working_dir":"/tmp/demo","updated_at":"2026-08-20T16:50:00Z","created_at":"2026-08-20T16:30:00Z","message_count":4,"accumulated_cost":0.01,"archived_at":null,"last_message_at":"2026-08-20T16:50:00Z","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}},
  {"id":"def456","name":"demo two","working_dir":"/tmp","updated_at":"2026-08-20T15:00:00Z","created_at":"2026-08-20T10:00:00Z","message_count":12,"accumulated_cost":0.42,"archived_at":null,"last_message_at":"2026-08-20T15:00:00Z","provider_name":"openai","model_config":{"model_name":"gpt-4o"}},
  {"id":"xyz789","name":"demo sibling","working_dir":"/tmp/demo-sibling","updated_at":"2026-08-20T14:00:00Z","created_at":"2026-08-20T09:00:00Z","message_count":2,"accumulated_cost":0.05,"archived_at":null,"last_message_at":"2026-08-20T14:00:00Z","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}
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

# Test: -w is the documented short form of --working-dir. The fake
# goose always populates working_dir, so we just verify the same
# subtree match applies whether the flag is long or short.
out=$(cd /tmp && "$ROOT/honk" -w /tmp/demo --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "-w /tmp/demo should match demo one. Got: $out"
if [[ "$out" == *"demo sibling"* ]]; then
    fail "-w /tmp/demo must not match sibling /tmp/demo-sibling. Got: $out"
fi
if [[ "$out" == *"demo two"* ]]; then
    fail "-w /tmp/demo must not match /tmp. Got: $out"
fi
pass "-w short form of --working-dir works"

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

# Test: the `--flag=value` form must work alongside the space-separated
# form. The argument parser used to reject `--limit=10` and similar as
# "unknown flag" because the case arms only matched the bare `--limit`,
# not `--limit=…`. Modern CLI conventions expect both forms to work.
out=$(cd /tmp && "$ROOT/honk" --limit=2 --all --list 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^abc123\|^def456\|^xyz789' || true)
[[ "$n" -eq 2 ]] || fail "--limit=2 --list should emit 2 sessions, got $n: $out"
out=$("$ROOT/honk" -w=/tmp/demo --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "-w=/tmp/demo should match demo one. Got: $out"
if [[ "$out" == *"demo sibling"* ]]; then
    fail "-w=/tmp/demo must not match /tmp/demo-sibling. Got: $out"
fi
if [[ "$out" == *"demo two"* ]]; then
    fail "-w=/tmp/demo must not match /tmp. Got: $out"
fi
# Empty value via the = form should be rejected just like the
# space-separated form.
out=$("$ROOT/honk" --limit= --list 2>&1) || true
[[ "$out" == *"--limit needs an argument"* ]] \
    || fail "--limit= (empty) should be rejected. Got: $out"
pass "--flag=value syntax works for --limit, -w"

# Test: boolean flags also accept the `--flag=value` form for symmetry
# with value-taking flags. The value is ignored (the flag is still
# treated as boolean). This covers --archived, --all, --no-cwd,
# --help, --version, --list, --json.
out=$(cd /var && "$ROOT/honk" --archived=1 --all=yes --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "--archived=1 --all=yes should include /tmp/demo. Got: $out"
out=$(cd /var && "$ROOT/honk" --no-cwd=1 --archived=true --list 2>&1)
[[ "$out" == *"demo one"* ]] || fail "--no-cwd=1 --archived=true should include /tmp/demo. Got: $out"
out=$("$ROOT/honk" --help=anything 2>&1)
[[ "$out" == *"USAGE"* ]] || fail "--help=anything should still print help. Got: $out"
out=$("$ROOT/honk" --version=anything 2>&1)
[[ "$out" == honk\ * ]] || fail "--version=anything should still print version. Got: $out"
out=$(cd /tmp && "$ROOT/honk" --list=anything 2>&1)
[[ "$out" == *"demo one"* ]] || fail "--list=anything should still list. Got: $out"
out=$(cd /tmp && "$ROOT/honk" --json=anything 2>&1)
n=$(printf '%s' "$out" | grep -c '^{' || true)
[[ "$n" -eq 3 ]] || fail "--json=anything should still emit 3 objects. Got: $n: $out"
pass "--flag=value syntax works for boolean flags"

# Test: multiple positional arguments on the command line must be
# rejected instead of silently picking the last one. Before the fix,
# `honk foo bar` resolved 'bar' and ignored 'foo'.
out=$("$ROOT/honk" foo bar 2>&1) || true
[[ "$out" == *"unexpected extra argument"* ]] \
    || fail "multiple positional args should be rejected. Got: $out"
pass "multiple positional args are rejected"

# Test: invalid HONK_ASCENDING values fail before querying goose. The
# flag used to be honored whenever the env var was non-empty (so
# `HONK_ASCENDING=0` and `HONK_ASCENDING=false` would silently enable
# ascending order); the new contract treats only `1` as on and rejects
# anything else with a clear error.
out=$(HONK_ASCENDING=2 "$ROOT/honk" --list 2>&1) || true
[[ "$out" == *"HONK_ASCENDING must be 0 or 1"* ]] \
    || fail "invalid HONK_ASCENDING should print a clear error. Got: $out"
# The non-zero exit code is also part of the contract; a caller that
# redirects the error to /dev/null still sees a failure.
if HONK_ASCENDING=2 "$ROOT/honk" --list >/dev/null 2>&1; then
    fail "HONK_ASCENDING=2 should be rejected"
fi
pass "invalid HONK_ASCENDING is rejected"

# HONK_ASCENDING=0 must not silently enable ascending (regression for
# the old `[[ -n "$ascending" ]]` check).
out=$(cd /tmp && HONK_ASCENDING=0 "$ROOT/honk" --json 2>&1)
[[ -n "$out" ]] || fail "HONK_ASCENDING=0 should still produce output"
if [[ "$out" == *"syntax error"* ]]; then
    fail "HONK_ASCENDING=0 must not pass --ascending to goose. Got: $out"
fi
pass "HONK_ASCENDING=0 does not enable ascending order"

# Test: --json emits 3 objects (run under /tmp so cwd filter lets them through)
out=$(cd /tmp && "$ROOT/honk" --json 2>&1)
n=$(printf '%s' "$out" | grep -c '^{')
[[ "$n" -eq 3 ]] || fail "--json should emit 3 objects under /tmp, got $n"
pass "--json emits correct number of objects"

# Test: -r with an unambiguous fragment resolves and resumes the right session.
# stdin is /dev/null so any multi-match fallback can't hang on fzf.
out=$(cd /tmp && "$ROOT/honk" -r "demo one" </dev/null 2>&1) || true
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
out=$(cd /tmp && "$ROOT/honk" -r demo </dev/null 2>&1) || true
[[ "$out" == *"matches multiple sessions"* ]] || fail "-r 'demo' should report multiple matches. Got: $out"
pass "-r ambiguous fragment reports multiple matches without a tty"

# Test: Honk --limit 1 --all emits exactly 1 row.
out=$(cd /tmp && "$ROOT/honk" --all --limit 1 --list 2>&1)
n=$(printf '%s\n' "$out" | grep -c '^abc123\|^def456' || true)
[[ "$n" -eq 1 ]] || fail "--limit 1 --list should emit 1 session row, got $n: $out"
pass "--limit caps the result count"

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

# Regression: a session whose working_dir is missing or null in the
# session list must not surface as the literal string "null" in any
# downstream pipeline. `honk_session_working_dir` is the most
# security-sensitive consumer (it gates a `cd`), so it must return
# empty (not "null") so the `[[ -z "$wd" ]]` guard in the resume
# and fork actions still triggers the documented cwd fallback.
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-nullwd.XXXXXX.json")
printf '%s\n' \
    '{"id":"missing1","name":"missing working_dir"}' \
    '{"id":"explicit1","name":"explicit null","working_dir":null}' \
    > "$cache_file"
out=$(HONK_LIST_CACHE="$cache_file" \
    bash -c 'source "$1/lib/actions.sh"; honk_session_working_dir missing1' _ "$ROOT")
[[ -z "$out" ]] \
    || fail "honk_session_working_dir should return empty for missing working_dir (got: $out)"
[[ "$out" != "null" ]] \
    || fail "honk_session_working_dir must not return literal 'null' for missing working_dir"
out=$(HONK_LIST_CACHE="$cache_file" \
    bash -c 'source "$1/lib/actions.sh"; honk_session_working_dir explicit1' _ "$ROOT")
[[ -z "$out" ]] \
    || fail "honk_session_working_dir should return empty for null working_dir (got: $out)"
[[ "$out" != "null" ]] \
    || fail "honk_session_working_dir must not return literal 'null' for null working_dir"
rm -f "$cache_file"
pass "honk_session_working_dir returns empty (not 'null') for missing/null working_dir"

# Regression: the preview pane's header must not print the literal
# string "null" for sessions whose working_dir, created_at, or
# updated_at are missing or null. The fake goose emits working_dir
# for every session so we exercise this through a hand-crafted
# cache that omits those fields entirely.
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-preview-null.XXXXXX.json")
printf '%s\n' \
    '{"id":"nullmeta","name":"null meta"}' \
    > "$cache_file"
out=$(cd /tmp && HONK_LIST_CACHE="$cache_file" \
    bash "$ROOT/lib/preview.sh" nullmeta 2>&1) || true
rm -f "$cache_file"
if [[ "$out" == *"working_dir: null"* || "$out" == *"created:    null"* \
   || "$out" == *"updated:    null"* ]]; then
    fail "preview header must not render literal 'null' for missing fields. Got: $out"
fi
[[ "$out" == *"nullmeta"* ]] \
    || fail "preview header should still render the session name. Got: $out"
pass "preview header renders empty (not 'null') for missing metadata fields"

# Regression: invalid HONK_GREP / --grep arguments are rejected with a
# clear error so a user who fat-fingers the flag name catches the typo.
# The flag itself was removed in the same change, so we expect the parser
# to reject it as an unknown flag rather than silently swallow it.
out=$("$ROOT/honk" --grep foo --list 2>&1) || true
[[ "$out" == *"unknown flag"* ]] \
    || fail "removed --grep flag should be rejected as unknown. Got: $out"
out=$(cd /tmp && HONK_GREP=foo \
    "$ROOT/honk" --list 2>&1) || true
# HONK_GREP is a no-op now; --list should still produce output rather
# than a filter-related error.
[[ "$out" == *"demo one"* ]] \
    || fail "honk --list should ignore inherited HONK_GREP. Got: $out"
pass "removed --grep flag and HONK_GREP env var are rejected / ignored"

# Test: the metadata preview shows provider_name and the model from
# model_config.model_name, both of which are part of the public
# `goose session list --format json` shape. Empty values render as
# empty (not the literal "null" string from missing fields).
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-pm-meta.XXXXXX.json")
printf '%s\n' \
    '{"id":"pm1","name":"provider/model session","working_dir":"/tmp","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"},"accumulated_cost":0,"message_count":0,"created_at":"","updated_at":"","last_message_at":null}' \
    > "$cache_file"
out=$(cd /tmp && HONK_LIST_CACHE="$cache_file" \
    bash "$ROOT/lib/preview.sh" pm1 2>&1) || true
rm -f "$cache_file"
[[ "$out" == *"provider:"*"anthropic"* ]] \
    || fail "preview header should show provider. Got: $out"
[[ "$out" == *"model:"*"claude-3-5-sonnet-latest"* ]] \
    || fail "preview header should show model. Got: $out"
pass "preview header shows provider and model"

# Test: honk_provider_candidates emits providers sorted by frequency,
# with cache-derived entries first and a static fallback list (per
# goose's --help) appended. Duplicates are removed (cache wins).
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-pm-prov.XXXXXX.json")
printf '%s\n' \
    '{"id":"p1","name":"a","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    '{"id":"p2","name":"b","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    '{"id":"p3","name":"c","provider_name":"anthropic","model_config":{"model_name":"claude-3-opus-latest"}}' \
    '{"id":"p4","name":"d","provider_name":"openai","model_config":{"model_name":"gpt-4o"}}' \
    '{"id":"p5","name":"e","provider_name":"openai","model_config":{"model_name":"gpt-4o"}}' \
    > "$cache_file"
out=$(HONK_LIST_CACHE="$cache_file" \
    bash -c 'source "$1/lib/list.sh"; honk_provider_candidates' _ "$ROOT")
rm -f "$cache_file"
expected=$'anthropic\nopenai\nclaude-code\ndatabricks\ngemini-cli\nollama'
[[ "$out" == "$expected" ]] \
    || fail "provider candidates mismatch. Got: [$out] Expected: [$expected]"
pass "honk_provider_candidates lists providers by frequency with fallback"

# Test: honk_provider_candidates marks the current override with
# " (current)" so the picker can highlight what's already in effect.
# We deliberately do NOT pipe through `head -1` inside the command
# substitution: the bash subshell produces multiple lines, so `head -1`
# causes a SIGPIPE that escapes via `set -o pipefail` and kills the
# test script. We capture the full output and slice the first line
# with parameter expansion instead.
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-pm-curprov.XXXXXX.json")
printf '%s\n' \
    '{"id":"p1","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    > "$cache_file"
out=$(HONK_LIST_CACHE="$cache_file" HONK_PROVIDER=anthropic \
    bash -c 'source "$1/lib/list.sh"; honk_provider_candidates' _ "$ROOT")
first_line="${out%%$'\n'*}"
rm -f "$cache_file"
[[ "$first_line" == "anthropic (current)" ]] \
    || fail "current override should be marked. Got: [$out]"
pass "honk_provider_candidates marks the current override"

# Test: honk_model_candidates emits models for a given provider,
# sorted by descending frequency, with the current override marked.
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-pm-models.XXXXXX.json")
printf '%s\n' \
    '{"id":"m1","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    '{"id":"m2","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    '{"id":"m3","provider_name":"anthropic","model_config":{"model_name":"claude-3-opus-latest"}}' \
    '{"id":"m4","provider_name":"openai","model_config":{"model_name":"gpt-4o"}}' \
    > "$cache_file"
out=$(HONK_LIST_CACHE="$cache_file" \
    bash -c 'source "$1/lib/list.sh"; honk_model_candidates anthropic' _ "$ROOT")
rm -f "$cache_file"
expected=$'claude-3-5-sonnet-latest\nclaude-3-opus-latest'
[[ "$out" == "$expected" ]] \
    || fail "model candidates mismatch. Got: [$out] Expected: [$expected]"
pass "honk_model_candidates filters models by provider and sorts by frequency"

# Test: honk_model_candidates emits nothing for a provider with no
# recorded models in the cache; the caller is expected to fall back
# to goose's default model rather than blocking on an empty list.
cache_file=$(mktemp "${TMPDIR:-/tmp}/honk-pm-empty.XXXXXX.json")
printf '%s\n' \
    '{"id":"m1","provider_name":"anthropic","model_config":{"model_name":"claude-3-5-sonnet-latest"}}' \
    > "$cache_file"
out=$(HONK_LIST_CACHE="$cache_file" \
    bash -c 'source "$1/lib/list.sh"; honk_model_candidates databricks' _ "$ROOT")
rm -f "$cache_file"
[[ -z "$out" ]] \
    || fail "model candidates should be empty for unrecorded provider. Got: [$out]"
pass "honk_model_candidates returns empty for unrecorded provider"

# Test: --provider / --model CLI flags parse and are accepted on --list.
# We `cd /tmp` first so the cwd-only filter (HONK_PWD_ONLY=1, the default)
# admits the fake goose's /tmp/demo and /tmp working_dirs.
out=$(cd /tmp && "$ROOT/honk" --provider anthropic --model claude-3-5-sonnet-latest --list 2>&1)
[[ "$out" == *"demo one"* ]] \
    || fail "--provider/--model should not break --list. Got: $out"
# The =value form should also be accepted.
out=$(cd /tmp && "$ROOT/honk" --provider=anthropic --model=claude --list 2>&1)
[[ "$out" == *"demo one"* ]] \
    || fail "--provider= / --model= should not break --list. Got: $out"
pass "--provider and --model CLI flags are accepted"

# Test: HONK_PROVIDER and HONK_MODEL are appended to the goose exec
# when honk_action_resume runs. We use bash -x to capture the would-be
# exec line (the exec replaces the bash process before any real goose
# invocation, but the trace survives up to that point). We redirect
# stdout to /dev/null so the fake goose's "unhandled" noise doesn't
# pollute the trace.
trace=$(cd /tmp && HONK_PROVIDER=anthropic HONK_MODEL=claude-3-5-sonnet-latest \
    bash -x -c 'source "$1/lib/actions.sh"; honk_action_resume abc123' _ "$ROOT" 2>&1 1>/dev/null) || true
if ! grep -qF 'exec goose session --resume --session-id abc123 --provider anthropic --model claude-3-5-sonnet-latest' <<<"$trace"; then
    fail "HONK_PROVIDER/HONK_MODEL should append --provider/--model to resume. Trace: $trace"
fi
pass "HONK_PROVIDER and HONK_MODEL flow into honk_action_resume"

# Test: HONK_PROVIDER alone appends only --provider (no --model flag).
trace=$(cd /tmp && HONK_PROVIDER=anthropic \
    bash -x -c 'source "$1/lib/actions.sh"; honk_action_resume abc123' _ "$ROOT" 2>&1 1>/dev/null) || true
if ! grep -qF 'exec goose session --resume --session-id abc123 --provider anthropic' <<<"$trace"; then
    fail "HONK_PROVIDER alone should append --provider. Trace: $trace"
fi
if grep -qE -- '--model[[:space:]]' <<<"$trace"; then
    fail "HONK_PROVIDER alone should NOT append --model. Trace: $trace"
fi
pass "HONK_PROVIDER alone appends only --provider"

# Test: neither env var set means no --provider/--model flags added.
trace=$(cd /tmp && unset HONK_PROVIDER HONK_MODEL \
    bash -x -c 'source "$1/lib/actions.sh"; honk_action_resume abc123' _ "$ROOT" 2>&1 1>/dev/null) || true
if grep -qE -- '--provider[[:space:]]|--model[[:space:]]' <<<"$trace"; then
    fail "unset HONK_PROVIDER/HONK_MODEL should NOT append --provider/--model. Trace: $trace"
fi
pass "unset HONK_PROVIDER/HONK_MODEL add no override flags"

# Test: honk_action_fork picks up the same overrides as honk_action_resume.
trace=$(cd /tmp && HONK_PROVIDER=openai HONK_MODEL=gpt-4o \
    bash -x -c 'source "$1/lib/actions.sh"; honk_action_fork abc123' _ "$ROOT" 2>&1 1>/dev/null) || true
if ! grep -qF 'exec goose session --resume --fork --session-id abc123 --provider openai --model gpt-4o' <<<"$trace"; then
    fail "fork should forward --provider/--model. Trace: $trace"
fi
pass "honk_action_fork forwards provider/model overrides"

# Test: honk_action_new appends --provider/--model to `goose session --name`.
# We skip the interactive name prompt by passing the name as the second arg.
trace=$(cd /tmp && HONK_PROVIDER=anthropic HONK_MODEL=claude-3-5-sonnet-latest \
    bash -x -c 'source "$1/lib/actions.sh"; honk_action_new /tmp demo-name' _ "$ROOT" 2>&1 1>/dev/null) || true
if ! grep -qF 'exec goose session --name demo-name --provider anthropic --model claude-3-5-sonnet-latest' <<<"$trace"; then
    fail "new should forward --provider/--model. Trace: $trace"
fi
pass "honk_action_new forwards provider/model overrides"

# Test: --provider and --model on the honk CLI are passed through to
# the resolved resume (`honk -r`). bash -x traces the resume path,
# which exec's the goose session subcommand. The captured trace
# contains both the bash internals (where set -e is set, etc.) and
# the final `+ exec goose session --resume --session-id abc123
# --provider claude-cli --model haiku` line. We cd to /tmp so the
# cwd-only filter admits /tmp/demo, and quote the resume fragment
# so honk's positional parser sees exactly one argument.
trace=$(cd /tmp && PATH="$TMP/bin:$PATH" \
    HONK_PROVIDER=claude-cli HONK_MODEL=haiku \
    bash -x "$ROOT/honk" -r "demo one" </dev/null 2>&1) || true
if ! grep -qF -- '--provider claude-cli --model haiku' <<<"$trace"; then
    fail "-r should honor HONK_PROVIDER/HONK_MODEL end-to-end. Trace: $trace"
fi
pass "honk -r honors HONK_PROVIDER / HONK_MODEL end-to-end"

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
