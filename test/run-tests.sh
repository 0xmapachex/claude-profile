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

printf '\n%d passed, %d failed\n' "$passes" "$fails"
exit "$((fails > 0))"
