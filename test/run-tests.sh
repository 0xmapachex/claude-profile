#!/usr/bin/env bash
# test suite for claude-profile. Requires node. No network, no real claude.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
wrapper="$repo/bin/claude-profile"
usage_tool="$repo/bin/claude-profile-usage"

fails=0
passes=0

test_root="$(mktemp -d "${TMPDIR:-/tmp}/claude-profile-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

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
  TESTTMP="$(mktemp -d "$test_root/case.XXXXXX")"
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

# --- test: reserved sub names rejected (collide with control files) ---
run_wrapper --add-sub personal active
check "reserved name active: exit 2" check_status 2
check "reserved name active: message" file_contains "$TESTTMP/errout" "reserved"
run_wrapper --add-sub personal switch-log.jsonl
check "reserved name switch-log: exit 2" check_status 2

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

# --- switch tests ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob     # active: bob

run_wrapper --switch personal alice
check "switch by name: exit 0" check_status 0
check "switch by name: active updated" file_contains "$pdir/.subscriptions/active" "alice"
check "switch by name: journal" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"switch","sub":"alice","from":"bob"'
check "switch by name: message" file_contains "$TESTTMP/out" "switched personal: bob"

run_wrapper --switch personal
check "rotate: exit 0" check_status 0
check "rotate: wrapped to bob" file_contains "$pdir/.subscriptions/active" "bob"

run_wrapper --switch personal bob
check "same-target: exit 0" check_status 0
check "same-target: no-op message" file_contains "$TESTTMP/out" "bob already active"

run_wrapper --switch personal ghost
check "missing target: exit 2" check_status 2
check "missing target: hint" file_contains "$TESTTMP/errout" "subscription does not exist: ghost"

new_env
run_wrapper --add-sub personal only
run_wrapper --switch personal
check "single sub rotate: exit 2" check_status 2
check "single sub rotate: hint names --add-sub" file_contains "$TESTTMP/errout" "--add-sub"

# --- healing: dangling active repaired at launch ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
printf 'ghost\n' > "$pdir/.subscriptions/active"
: > "$STUB_RECORD_FILE"
run_wrapper personal
check "heal: active repointed" file_contains "$pdir/.subscriptions/active" "alice"
check "heal: warned" file_contains "$TESTTMP/errout" "active subscription missing"
check "heal: launch used healed slot" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$pdir/.subscriptions/alice"

# --- subs listing ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob
printf '{"loggedIn":true,"email":"alice@x.com"}\n' > "$pdir/.subscriptions/alice/stub-auth.json"

run_wrapper --subs personal
check "subs: exit 0" check_status 0
check "subs: bob marked active" file_contains "$TESTTMP/out" "* bob"
check "subs: alice email backfilled in output" file_contains "$TESTTMP/out" "alice@x.com"
check "subs: alice email saved to meta" file_contains "$pdir/.subscriptions/alice/meta.json" '"email": "alice@x.com"'

new_env
run_wrapper --init personal
run_wrapper --subs personal
check "subs empty: helpful message" file_contains "$TESTTMP/out" "no subscriptions"

# --- remove-sub ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob    # active: bob

run_wrapper --remove-sub personal alice
check "remove inactive: exit 0" check_status 0
check "remove inactive: slot gone" test ! -d "$pdir/.subscriptions/alice"
check "remove inactive: in trash" bash -c "ls '$CLAUDE_PROFILES_ROOT/.trash' | grep -q '^personal-sub-alice-'"
check "remove inactive: active untouched" file_contains "$pdir/.subscriptions/active" "bob"

run_wrapper --remove-sub personal bob
check "remove last: active cleared" test ! -e "$pdir/.subscriptions/active"
check "remove last: message" file_contains "$TESTTMP/out" "no subscriptions remain"

# active repoint when removing the active of two
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob    # active: bob
run_wrapper --remove-sub personal bob
check "remove active: repointed to alice" file_contains "$pdir/.subscriptions/active" "alice"
check "remove active: journaled" file_contains "$pdir/.subscriptions/switch-log.jsonl" '"event":"switch","sub":"alice","from":"bob"'

# purge uses security with hashed service name; refused for adopted slots
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
fake_security="$TESTTMP/fake-security"
cat > "$fake_security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SECURITY_LOG:?}"
EOF
chmod 755 "$fake_security"
export CLAUDE_PROFILE_SECURITY_BIN="$fake_security"
export FAKE_SECURITY_LOG="$TESTTMP/security.log"

run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob
expected_service="$(node -e '
const crypto = require("crypto");
const dir = process.argv[1].normalize("NFC");
process.stdout.write("Claude Code-credentials-" + crypto.createHash("sha256").update(dir).digest("hex").substring(0, 8));
' "$pdir/.subscriptions/alice")"
run_wrapper --remove-sub personal alice --purge
check "purge: security called with hashed service" file_contains "$FAKE_SECURITY_LOG" "$expected_service"

new_env
export CLAUDE_PROFILE_SECURITY_BIN="$fake_security"
pdir="$CLAUDE_PROFILES_ROOT/personal"
mkdir -p "$pdir"
printf '{"loggedIn":true,"email":"gus@x.com"}\n' > "$pdir/stub-auth.json"
run_wrapper --add-sub personal bob   # adopts "gus" first
run_wrapper --remove-sub personal gus --purge
check "purge adopted: refused" check_status 2
check "purge adopted: message" file_contains "$TESTTMP/errout" "refusing --purge"
unset CLAUDE_PROFILE_SECURITY_BIN FAKE_SECURITY_LOG

# --- doctor + support detection ---
new_env
run_wrapper --add-sub personal alice
run_wrapper --doctor
check "doctor: supported line" file_contains "$TESTTMP/out" "securestorage env: supported"
check "doctor: profile sub count" file_contains "$TESTTMP/out" "profile personal: 1 subscription(s), active: alice"

# unsupported stub (a REAL cli build without the env var) → launch warning + doctor line
cat > "$TESTTMP/stub-unsupported" <<'EOF'
#!/usr/bin/env bash
# CLAUDE_CONFIG_DIR
{ printf 'argv=%s\n' "$*"; } > "${STUB_RECORD_FILE:?}"
EOF
chmod 755 "$TESTTMP/stub-unsupported"
export CLAUDE_PROFILE_CLAUDE_BIN="$TESTTMP/stub-unsupported"
run_wrapper personal
check "unsupported: launch warns" file_contains "$TESTTMP/errout" "does not support CLAUDE_SECURESTORAGE_CONFIG_DIR"
run_wrapper --doctor
check "unsupported: doctor reports" file_contains "$TESTTMP/out" "securestorage env: NOT supported"

# --add-sub refuses to create subscriptions under an unsupported claude
run_wrapper --add-sub personal bravo
check "unsupported add-sub: exit 2" check_status 2
check "unsupported add-sub: message" file_contains "$TESTTMP/errout" "does not support"
check "unsupported add-sub: no slot created" test ! -d "$CLAUDE_PROFILES_ROOT/personal/.subscriptions/bravo"

# wrapper/shim stub (neither marker) → NO launch warning, doctor undetermined
cat > "$TESTTMP/stub-wrapper" <<'EOF'
#!/usr/bin/env bash
{ printf 'argv=%s\n' "$*"; } > "${STUB_RECORD_FILE:?}"
EOF
chmod 755 "$TESTTMP/stub-wrapper"
export CLAUDE_PROFILE_CLAUDE_BIN="$TESTTMP/stub-wrapper"
run_wrapper personal
check "wrapper: no false launch warning" bash -c "! grep -qF 'does not support CLAUDE_SECURESTORAGE_CONFIG_DIR' '$TESTTMP/errout'"
run_wrapper --doctor
check "wrapper: doctor undetermined" file_contains "$TESTTMP/out" "securestorage env: undetermined"

# PATH scan: find_claude_bin must skip wrappers and pick the real cli further down PATH
pdir="$CLAUDE_PROFILES_ROOT/personal"
mkdir -p "$TESTTMP/pathA" "$TESTTMP/pathB"
cp "$TESTTMP/stub-wrapper" "$TESTTMP/pathA/claude"
cp "$here/stub-claude" "$TESTTMP/pathB/claude"
unset CLAUDE_PROFILE_CLAUDE_BIN
: > "$STUB_RECORD_FILE"
saved_path="$PATH"
PATH="$TESTTMP/pathA:$TESTTMP/pathB:$PATH" run_wrapper personal
PATH="$saved_path"
check "path scan: launch used real cli, not wrapper" file_contains "$STUB_RECORD_FILE" "CLAUDE_SECURESTORAGE_CONFIG_DIR=$pdir/.subscriptions/alice"
check "path scan: no false warning" bash -c "! grep -qF 'does not support CLAUDE_SECURESTORAGE_CONFIG_DIR' '$TESTTMP/errout'"

# help text
export CLAUDE_PROFILE_CLAUDE_BIN="$here/stub-claude"
run_wrapper --help
check "help: --add-sub documented" file_contains "$TESTTMP/out" "add-sub"
check "help: --switch documented" file_contains "$TESTTMP/out" "switch"

# --- usage attribution ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice

mkdir -p "$pdir/projects/proj"
cat > "$pdir/.subscriptions/switch-log.jsonl" <<'EOF'
{"ts":"2026-07-01T00:00:00Z","event":"switch","sub":"alice","from":null}
{"ts":"2026-07-02T00:00:00Z","event":"switch","sub":"bob","from":"alice"}
EOF
mkdir -p "$pdir/.subscriptions/bob"
cat > "$pdir/projects/proj/session.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-06-30T12:00:00Z","requestId":"r0","message":{"id":"m0","usage":{"input_tokens":10,"output_tokens":1}}}
{"type":"assistant","timestamp":"2026-07-01T12:00:00Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":5,"cache_read_input_tokens":200}}}
{"type":"assistant","timestamp":"2026-07-01T12:00:00Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":5,"cache_read_input_tokens":200}}}
{"type":"assistant","timestamp":"2026-07-02T12:00:00Z","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":300,"output_tokens":70}}}
{"type":"assistant","timestamp":"2026-07-02T00:00:00.500Z","requestId":"r3","message":{"id":"m3","usage":{"input_tokens":7,"output_tokens":0}}}
EOF
printf '{"loggedIn":true,"email":"alice@x.com"}\n' > "$pdir/.subscriptions/alice/stub-auth.json"

# fake ccusage on PATH
mkdir -p "$TESTTMP/bin"
cat > "$TESTTMP/bin/ccusage" <<'EOF'
#!/usr/bin/env bash
printf '{"totals":{"totalTokens":736,"inputTokens":410,"outputTokens":121,"cacheCreationTokens":5,"cacheReadTokens":200,"totalCost":10},"daily":[{"date":"2026-07-02","totalTokens":736}]}\n'
EOF
chmod 755 "$TESTTMP/bin/ccusage"

PATH="$TESTTMP/bin:$PATH" "$usage_tool" daily --json >"$TESTTMP/usage.json" 2>"$TESTTMP/errout"

usage_field() { node -e '
const rows = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = rows.find(r => r.profile === process.argv[2] && (r.sub ?? "") === (process.argv[3] ?? ""));
process.stdout.write(row ? String(row[process.argv[4]]) : "MISSING");
' "$TESTTMP/usage.json" "$@"; }

check_eq "usage: alice tokens (dedup applied)" "355" "$(usage_field personal alice totalTokens)"
check_eq "usage: bob tokens (switch-second msg included)" "377" "$(usage_field personal bob totalTokens)"
check_eq "usage: pre-subscriptions bucket" "11" "$(usage_field personal '(pre-subscriptions)' totalTokens)"
check_eq "usage: alice status active" "active" "$(usage_field personal alice status)"
check_eq "usage: bob status stored" "stored" "$(usage_field personal bob status)"
check_eq "usage: cost apportioned to bob" "5.07" "$(node -e '
const rows = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = rows.find(r => r.profile === "personal" && r.sub === "bob");
process.stdout.write(row ? row.totalCost.toFixed(2) : "MISSING");
' "$TESTTMP/usage.json")"

# --json accepted with the period omitted
PATH="$TESTTMP/bin:$PATH" "$usage_tool" --json >"$TESTTMP/usage-nop.json" 2>/dev/null
check "usage: --json without period works" node -e '
const rows = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.exit(Array.isArray(rows) && rows.length > 0 ? 0 : 1);
' "$TESTTMP/usage-nop.json"

# --since passthrough must not crash and must filter our per-sub token rows
PATH="$TESTTMP/bin:$PATH" "$usage_tool" daily --json --since 20260702 >"$TESTTMP/usage-since.json" 2>"$TESTTMP/errout"
check "usage: --since run exits 0" test -s "$TESTTMP/usage-since.json"
usage_field2() { node -e '
const rows = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = rows.find(r => r.profile === process.argv[2] && (r.sub ?? "") === (process.argv[3] ?? ""));
process.stdout.write(row ? String(row[process.argv[4]]) : "MISSING");
' "$TESTTMP/usage-since.json" "$@"; }
check_eq "usage: --since filters alice to 0" "0" "$(usage_field2 personal alice totalTokens)"
check_eq "usage: --since keeps bob window" "377" "$(usage_field2 personal bob totalTokens)"

# --- symlinked active file is replaced, not written through ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob
target="$TESTTMP/evil-target"
printf 'x\n' > "$target"
rm -f "$pdir/.subscriptions/active"
ln -s "$target" "$pdir/.subscriptions/active"
run_wrapper --switch personal alice
check "symlink active: target untouched" file_contains "$target" "x"
check "symlink active: replaced with real file" bash -c "[[ ! -L '$pdir/.subscriptions/active' ]] && grep -qF alice '$pdir/.subscriptions/active'"

printf '\n%d passed, %d failed\n' "$passes" "$fails"
exit "$((fails > 0))"
