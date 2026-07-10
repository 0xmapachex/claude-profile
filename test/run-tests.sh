#!/usr/bin/env bash
# test suite for claude-profile. Requires node. No network, no real claude.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
wrapper="$repo/bin/claude-profile"
usage_tool="$repo/bin/claude-profile-usage"

fails=0
passes=0

check() {
  local desc="$1"; shift
  if "$@"; then
    passes=$((passes+1))
  else
    fails=$((fails+1))
    printf 'FAIL: %s\n' "$desc"
  fi
}

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    passes=$((passes+1))
  else
    fails=$((fails+1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

file_contains() { grep -qF -- "$2" "$1" 2>/dev/null; }

check_status() { [[ "$(cat "$TESTTMP/status")" == "$1" ]]; }

new_env() {
  TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-profile-test.XXXXXX")"
  export CLAUDE_PROFILES_ROOT="$TESTTMP/profiles"
  export CLAUDE_PROFILE_SOURCE_CONFIG="$TESTTMP/source-config"
  export CLAUDE_PROFILE_CLAUDE_BIN="$here/stub-claude"
  export CLAUDE_PROFILE_SHORTCUTS=0
  export CLAUDE_PROFILE_SET_TERMINAL_TITLE=0
  export CLAUDE_PROFILE_SET_CLAUDE_COLOR=0
  export STUB_RECORD_FILE="$TESTTMP/record"
  mkdir -p "$CLAUDE_PROFILE_SOURCE_CONFIG"
  unset CLAUDE_SECURESTORAGE_CONFIG_DIR 2>/dev/null || true
}

run_wrapper() {
  ( "$wrapper" "$@" ) >"$TESTTMP/out" 2>"$TESTTMP/errout"
  printf '%s' "$?" > "$TESTTMP/status"
}

# --- test: bare launch of a sub-less profile (today's behavior) ---
new_env
run_wrapper personal
check "smoke: launch exit 0" check_status 0
check "smoke: config dir is profile dir" file_contains "$STUB_RECORD_FILE" "CLAUDE_CONFIG_DIR=$CLAUDE_PROFILES_ROOT/personal"
check "smoke: securestorage env untouched without subs" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=__unset__"
check "smoke: skip-permissions flag passed" file_contains "$STUB_RECORD_FILE" "argv=--dangerously-skip-permissions"

# --- test: --add-sub creates slot, meta, active, journal; launch exports env ---
new_env
run_wrapper --add-sub personal alice
check "add-sub: exit 0" check_status 0
pdir="$CLAUDE_PROFILES_ROOT/personal"
check "add-sub: slot dir created" test -d "$pdir/.subscriptions/alice"
check "add-sub: active file names slot" file_contains "$pdir/.subscriptions/active" "alice"
check "add-sub: meta storageDir is slot dir" file_contains "$pdir/.subscriptions/alice/meta.json" "\"storageDir\": \"$pdir/.subscriptions/alice\""
check "add-sub: journal has switch event" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"switch","sub":"alice","from":null'
check "add-sub: launch exported securestorage env" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$pdir/.subscriptions/alice"
check "add-sub: journal has launch event" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"launch","sub":"alice"'

# --- test: duplicate --add-sub is refused ---
run_wrapper --add-sub personal alice
check "add-sub dup: exit 2" check_status 2
check "add-sub dup: message" file_contains "$TESTTMP/errout" "subscription already exists: alice"

# --- test: bare launch of profile with subs exports env and journals ---
: > "$STUB_RECORD_FILE"
run_wrapper personal
check "launch with sub: env exported" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$pdir/.subscriptions/alice"

# --- test: inherited securestorage env never leaks into a sub-less profile ---
new_env
export CLAUDE_SECURESTORAGE_CONFIG_DIR="/somewhere/stale"
run_wrapper personal
check "sub-less launch: inherited env cleared" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=__unset__"
unset CLAUDE_SECURESTORAGE_CONFIG_DIR

# --- test: invalid sub name rejected ---
new_env
run_wrapper --add-sub personal 'Bad Name'
check "add-sub invalid name: exit 2" check_status 2

# --- test: first --add-sub adopts an existing login ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
mkdir -p "$pdir"
printf '{"loggedIn":true,"authMethod":"claude.ai","email":"gus.tavo@example.com"}\n' > "$pdir/stub-auth.json"
run_wrapper --add-sub personal bob
check "adopt: adopted slot exists" test -d "$pdir/.subscriptions/gus.tavo"
check "adopt: adopted storageDir is profile dir" file_contains "$pdir/.subscriptions/gus.tavo/meta.json" "\"storageDir\": \"$pdir\""
check "adopt: adopted email recorded" file_contains "$pdir/.subscriptions/gus.tavo/meta.json" '"email": "gus.tavo@example.com"'
check "adopt: new slot is active" file_contains "$pdir/.subscriptions/active" "bob"
check "adopt: journal adopted first" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"switch","sub":"gus.tavo","from":null'
check "adopt: journal switched to new" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"switch","sub":"bob","from":"gus.tavo"'

# --- test: adoption falls back to sub1 when email is null ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
mkdir -p "$pdir"
printf '{"loggedIn":true,"authMethod":"claude.ai","email":null}\n' > "$pdir/stub-auth.json"
run_wrapper --add-sub personal bob
check "adopt null email: sub1 slot" test -d "$pdir/.subscriptions/sub1"

# --- test: no adoption when logged out ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal bob
check_eq "no adopt when logged out: single slot" "bob" "$(find "$pdir/.subscriptions" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"

printf '\n%d passed, %d failed\n' "$passes" "$fails"
exit "$((fails > 0))"
