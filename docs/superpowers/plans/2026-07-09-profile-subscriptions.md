# Multiple Subscriptions per Profile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one profile (shared history, MCPs, `--resume`) hold N login subscriptions, switchable with one command and no credential copying.

**Architecture:** A profile stays one `CLAUDE_CONFIG_DIR`. Each subscription is a slot directory under `<profile>/.subscriptions/<name>/`; at launch the wrapper exports `CLAUDE_SECURESTORAGE_CONFIG_DIR=<slot storage dir>` so Claude Code itself keeps that subscription's credentials in its own Keychain entry. Switching = rewriting the `active` file. A `switch-log.jsonl` journal lets `claude-profile-usage` attribute transcript tokens to subscriptions by time window. Spec: `docs/superpowers/specs/2026-07-09-profile-subscriptions-design.md`.

**Tech Stack:** bash (existing scripts), node >= 18 (already required), no new dependencies. Tests: plain bash runner + stub claude binary, wired into `npm test`.

## Global Constraints

- Only touch `bin/claude-profile`, `bin/claude-profile-usage`, `package.json`, `README.md`, and new files under `test/`. No new runtime dependencies.
- Subscription names use the same charset rule as profiles: `^[a-z0-9][a-z0-9._-]{0,79}$`.
- All new dirs `mkdir` under `umask 077`; slot dirs `chmod 700`; `meta.json` written mode `0600`.
- Journal timestamps: UTC ISO-8601 via `date -u +%Y-%m-%dT%H:%M:%SZ`.
- New CLI subcommands are **option-first**, matching the existing grammar: `claude-profile --add-sub <profile> <name>`, `--switch <profile> [name]`, `--subs <profile>`, `--remove-sub <profile> <name> [--purge]`. Anything after `claude-profile <profile>` keeps passing through to claude untouched.
- A profile with zero slots must behave **byte-identically** to today (env var never set; no journal writes).
- The wrapper never reads or writes credential material. The only credential-adjacent action is `--remove-sub --purge`'s `security delete-generic-password`.
- Every commit runs from repo root `/Users/gustavo/apps/claude-profile`; run `npm test` before each commit.

---

### Task 1: Test harness (stub claude + runner)

**Files:**
- Create: `test/stub-claude`
- Create: `test/run-tests.sh`
- Modify: `package.json` (test script)

**Interfaces:**
- Produces: `test/stub-claude` — fake claude honoring `auth status --json` (reads `<storage>/stub-auth.json`, else logged-out JSON) and recording launches to `$STUB_RECORD_FILE` with lines `argv=...`, `CLAUDE_CONFIG_DIR=...`, `CLAUDE_SECURESTORAGE_CONFIG_DIR=...` (literal `__unset__` when unset). Contains the literal string `CLAUDE_SECURESTORAGE_CONFIG_DIR` (marks it "supported") and must NOT contain `Session color set to`.
- Produces: `test/run-tests.sh` helpers used by every later task: `new_env` (fresh temp `CLAUDE_PROFILES_ROOT` + all wrapper knobs), `run_wrapper <args...>` (runs wrapper in subshell; fills `$TESTTMP/out`, `$TESTTMP/errout`, `$TESTTMP/status`), `check <desc> <cmd...>`, `check_eq <desc> <expected> <actual>`, `file_contains <file> <fixed-string>`.

- [ ] **Step 1: Write the stub**

`test/stub-claude`:

```bash
#!/usr/bin/env bash
# stub claude for tests. The literal name CLAUDE_SECURESTORAGE_CONFIG_DIR below
# also serves as the wrapper's support-detection marker.
set -euo pipefail

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  storage="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  if [[ -f "$storage/stub-auth.json" ]]; then
    cat "$storage/stub-auth.json"
  else
    printf '{"loggedIn":false,"authMethod":"none"}\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
  printf 'stub-claude 0.0.0\n'
  exit 0
fi

{
  printf 'argv=%s\n' "$*"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-}"
  printf 'CLAUDE_SECURESTORAGE_CONFIG_DIR=%s\n' "${CLAUDE_SECURESTORAGE_CONFIG_DIR-__unset__}"
} > "${STUB_RECORD_FILE:?STUB_RECORD_FILE not set}"
```

Then: `chmod 755 test/stub-claude`

- [ ] **Step 2: Write the runner with a smoke test of current behavior**

`test/run-tests.sh`:

```bash
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
```

Add this helper just under `file_contains` (used above):

```bash
check_status() { [[ "$(cat "$TESTTMP/status")" == "$1" ]]; }
```

Then: `chmod 755 test/run-tests.sh`

- [ ] **Step 3: Wire into npm test**

In `package.json` replace the scripts block:

```json
  "scripts": {
    "test": "bash -n bin/claude-profile bin/claude-profile-usage test/run-tests.sh && bash test/run-tests.sh"
  }
```

(Do not add `test/` to the `files` array — tests should not ship in the npm package.)

- [ ] **Step 4: Run and verify green**

Run: `npm test`
Expected: `4 passed, 0 failed`, exit 0. (These assert *current* behavior; they must pass before any wrapper change.)

- [ ] **Step 5: Commit**

```bash
git add test/stub-claude test/run-tests.sh package.json
git commit -m "test: add stub-claude harness and smoke tests"
```

---

### Task 2: Slot primitives, launch env selection, `--add-sub`

**Files:**
- Modify: `bin/claude-profile` (new helper block after `link_shared_item`; refactor tail of `main()` into `launch_profile`; new case arms)
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: existing `validate_profile`, `init_profile`, `profile_path`, `find_claude_bin`, `strip_auth_env`, `err`, `set_terminal_title`, `should_inject_color`, `ensure_profile_color`; stub/harness from Task 1.
- Produces (bash functions, used by Tasks 3–8):
  - `subs_root <profile_dir>` → prints `<profile_dir>/.subscriptions`
  - `slot_path <profile_dir> <sub>` → prints slot dir
  - `now_iso` → prints UTC ISO-8601 timestamp
  - `list_slots <profile_dir>` → newline-separated sorted slot names (empty if none)
  - `resolve_active_slot <profile_dir>` → active name, or empty if unset/dangling
  - `set_active_slot <profile_dir> <sub>`
  - `journal_append <profile_dir> <event> <sub> [from]` → appends `{"ts","event","sub","from"}` (from empty → `null`); on write failure warns and succeeds
  - `slot_storage_dir <profile_dir> <sub>` → `meta.json` `storageDir`, falling back to the slot dir
  - `write_slot_meta <slot_dir> <name> <storage_dir> [email]` → creates/updates `meta.json` (preserves `createdAt`, bumps `lastUsedAt`, sets `email` only if non-empty)
  - `validate_sub_name <name>`
  - `launch_profile <profile> [claude args...]` → the extracted launch path; exports `CLAUDE_SECURESTORAGE_CONFIG_DIR` when an active slot exists and appends a `launch` journal event
  - `add_sub <profile> <name>` → creates slot, activates it, journals; caller then launches
  - CLI: `claude-profile --add-sub <profile> <name>` (creates then launches)

- [ ] **Step 1: Write the failing tests**

Append to `test/run-tests.sh` before the final summary printf:

```bash
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: smoke tests pass; every new test FAILs (unknown option `--add-sub` exits 2, so the "exit 2" duplicate/invalid checks may coincidentally pass — the creation/env checks must fail).

- [ ] **Step 3: Implement**

In `bin/claude-profile`, insert after the `link_shared_item()` function:

```bash
subs_root() { printf '%s/.subscriptions\n' "$1"; }
slot_path() { printf '%s/.subscriptions/%s\n' "$1" "$2"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

validate_sub_name() {
  local sub="$1"
  if [[ -z "$sub" ]]; then
    err "subscription name is required"
    return 2
  fi
  if [[ ! "$sub" =~ ^[a-z0-9][a-z0-9._-]{0,79}$ ]]; then
    err "invalid subscription name: $sub"
    err "use 1-80 chars: lowercase letters, numbers, dot, underscore, dash; start with letter/number"
    return 2
  fi
}

list_slots() {
  local root
  root="$(subs_root "$1")"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort
}

resolve_active_slot() {
  local profile_dir="$1" active_file name
  active_file="$(subs_root "$profile_dir")/active"
  [[ -f "$active_file" && ! -L "$active_file" ]] || return 0
  name="$(cat "$active_file")"
  [[ -n "$name" && -d "$(slot_path "$profile_dir" "$name")" ]] || return 0
  printf '%s\n' "$name"
}

set_active_slot() {
  printf '%s\n' "$2" > "$(subs_root "$1")/active"
}

journal_append() {
  local profile_dir="$1" event="$2" sub="$3" from="${4:-}"
  local from_json="null"
  [[ -z "$from" ]] || from_json="\"$from\""
  printf '{"ts":"%s","event":"%s","sub":"%s","from":%s}\n' \
    "$(now_iso)" "$event" "$sub" "$from_json" \
    >> "$(subs_root "$profile_dir")/switch-log.jsonl" \
    || err "warning: journal write failed; usage attribution will have a gap"
}

write_slot_meta() {
  local slot_dir="$1" name="$2" storage_dir="$3" email="${4:-}"
  local node_bin
  node_bin="$(command -v node || true)"
  if [[ -z "$node_bin" ]]; then
    err "node is required to manage subscriptions"
    return 1
  fi
  "$node_bin" -e '
const fs = require("fs");
const [dst, name, storageDir, email, now] = process.argv.slice(1);
let meta = {};
try { meta = JSON.parse(fs.readFileSync(dst, "utf8")); } catch {}
meta.name = name;
meta.storageDir = storageDir;
if (email) meta.email = email;
if (!meta.createdAt) meta.createdAt = now;
meta.lastUsedAt = now;
fs.writeFileSync(dst, JSON.stringify(meta, null, 2) + "\n", { mode: 0o600 });
' "$slot_dir/meta.json" "$name" "$storage_dir" "$email" "$(now_iso)"
}

slot_storage_dir() {
  local profile_dir="$1" sub="$2" slot out=""
  slot="$(slot_path "$profile_dir" "$sub")"
  if [[ -f "$slot/meta.json" ]]; then
    out="$(node -e '
try {
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (typeof m.storageDir === "string" && m.storageDir) process.stdout.write(m.storageDir);
} catch {}
' "$slot/meta.json" 2>/dev/null || true)"
  fi
  printf '%s\n' "${out:-$slot}"
}

add_sub() {
  local profile="$1" sub="$2"
  validate_profile "$profile" || return $?
  validate_sub_name "$sub" || return $?

  local profile_dir
  profile_dir="$(init_profile "$profile")" || return $?

  umask 077
  mkdir -p "$(subs_root "$profile_dir")"
  chmod 700 "$(subs_root "$profile_dir")" 2>/dev/null || true

  local slot
  slot="$(slot_path "$profile_dir" "$sub")"
  if [[ -d "$slot" ]]; then
    err "subscription already exists: $sub"
    return 2
  fi

  local prev
  prev="$(resolve_active_slot "$profile_dir")"

  mkdir -p "$slot"
  chmod 700 "$slot"
  write_slot_meta "$slot" "$sub" "$slot" || return 1
  set_active_slot "$profile_dir" "$sub"
  journal_append "$profile_dir" switch "$sub" "$prev"
  printf 'created subscription %s in profile %s\n' "$sub" "$profile" >&2
  printf 'launching claude; run /login inside to attach this subscription\n' >&2
}
```

Refactor: replace everything in `main()` from `local profile="$1"` to the end (the current lines `local profile="$1"` … `exec "$claude_bin" "$@"`) with:

```bash
  local profile="$1"
  shift

  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  launch_profile "$profile" "$@"
```

and add above `main()`:

```bash
launch_profile() {
  local profile="$1"
  shift

  local profile_dir
  profile_dir="$(init_profile "$profile")" || return $?

  if [[ "${CLAUDE_PROFILE_SYNC_SETTINGS:-1}" != "0" ]]; then
    write_sanitized_settings "$source_config/settings.json" "$profile_dir/settings.json"
  fi

  local claude_bin
  claude_bin="$(find_claude_bin)" || {
    err "claude binary not found in PATH"
    return 127
  }

  strip_auth_env
  unset CLAUDE_SECURESTORAGE_CONFIG_DIR 2>/dev/null || true
  export CLAUDE_CONFIG_DIR="$profile_dir"

  local active=""
  active="$(resolve_active_slot "$profile_dir")"
  if [[ -n "$active" ]]; then
    export CLAUDE_SECURESTORAGE_CONFIG_DIR="$(slot_storage_dir "$profile_dir" "$active")"
    journal_append "$profile_dir" launch "$active"
  fi

  set_terminal_title "$profile" "$active"

  if should_inject_color "$claude_bin" "$@"; then
    set -- "/color $(ensure_profile_color "$profile_dir")" "$@"
  fi

  set -- "$@" --dangerously-skip-permissions

  exec "$claude_bin" "$@"
}
```

Update `set_terminal_title` to accept an optional subscription name:

```bash
set_terminal_title() {
  local profile="$1" sub="${2:-}"

  if [[ "${CLAUDE_PROFILE_SET_TERMINAL_TITLE:-1}" == "0" ]]; then
    return 0
  fi

  if [[ -t 1 ]]; then
    local title="${CLAUDE_PROFILE_TITLE_PREFIX:-claude:}$profile"
    [[ -z "$sub" ]] || title="$title ($sub)"
    title="${title//$'\033'/}"
    title="${title//$'\007'/}"
    printf '\033]0;%s\007' "$title"
  fi
}
```

Add the case arm in `main()` (alongside `--remove`):

```bash
    --add-sub|add-sub)
      shift || true
      if [[ $# -lt 2 ]]; then
        err "usage: claude-profile --add-sub <profile> <name>"
        return 2
      fi
      add_sub "$1" "$2" || return $?
      launch_profile "$1"
      return $?
      ;;
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass (smoke + Task 2 tests), exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: per-profile subscriptions via CLAUDE_SECURESTORAGE_CONFIG_DIR with --add-sub"
```

---

### Task 3: Auto-adopt an existing login on first `--add-sub`

**Files:**
- Modify: `bin/claude-profile`
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: Task 2 helpers; stub `auth status` (reads `<storage>/stub-auth.json`; for a profile with no env override the storage probed is the profile dir).
- Produces:
  - `auth_status_json <profile_dir> [storage_dir]` → prints claude's auth JSON; empty `storage_dir` probes with the env var explicitly unset (`env -u`)
  - `json_field <name>` → reads JSON on stdin, prints string/number/boolean field or nothing
  - `sanitize_sub_name <raw>` → lowercased, charset-filtered, ≤80 chars, leading `._-` stripped
  - `adopt_existing_login <profile_dir>` → creates an adopted slot (meta `storageDir` = profile dir) when the profile has a live login; silent no-op otherwise

- [ ] **Step 1: Write the failing tests**

Append to `test/run-tests.sh` before the summary:

```bash
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: the three adopt tests FAIL (no adopted slot is created); earlier tests still pass.

- [ ] **Step 3: Implement**

In `bin/claude-profile`, add after `slot_storage_dir()`:

```bash
auth_status_json() {
  local profile_dir="$1" storage_dir="${2:-}"
  local claude_bin
  claude_bin="$(find_claude_bin)" || return 1
  if [[ -n "$storage_dir" ]]; then
    CLAUDE_CONFIG_DIR="$profile_dir" CLAUDE_SECURESTORAGE_CONFIG_DIR="$storage_dir" \
      "$claude_bin" auth status --json 2>/dev/null
  else
    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$profile_dir" \
      "$claude_bin" auth status --json 2>/dev/null
  fi
}

json_field() {
  node -e '
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
  try {
    const v = JSON.parse(raw)[process.argv[1]];
    if (["string", "number", "boolean"].includes(typeof v)) process.stdout.write(String(v));
  } catch {}
});' "$1"
}

sanitize_sub_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cd 'a-z0-9._-' \
    | cut -c1-80 \
    | sed 's/^[._-]*//'
}

adopt_existing_login() {
  local profile_dir="$1"
  local status email name slot
  status="$(auth_status_json "$profile_dir" "")" || return 0
  [[ "$(printf '%s' "$status" | json_field loggedIn)" == "true" ]] || return 0
  email="$(printf '%s' "$status" | json_field email)"
  name="$(sanitize_sub_name "${email%%@*}")"
  [[ -n "$name" ]] || name="sub1"
  slot="$(slot_path "$profile_dir" "$name")"
  [[ -d "$slot" ]] && return 0
  mkdir -p "$slot"
  chmod 700 "$slot"
  write_slot_meta "$slot" "$name" "$profile_dir" "$email" || return 0
  set_active_slot "$profile_dir" "$name"
  journal_append "$profile_dir" switch "$name" ""
  printf 'adopted existing login as subscription %s\n' "$name" >&2
}
```

In `add_sub()`, insert immediately after the `mkdir -p "$(subs_root ...)"`/`chmod` pair and before the duplicate-slot check... **exactly here** (order matters — adoption must precede the duplicate check so `--add-sub personal gus.tavo` on an already-adoptable profile errors cleanly):

```bash
  if [[ -z "$(list_slots "$profile_dir")" ]]; then
    adopt_existing_login "$profile_dir"
  fi
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: auto-adopt existing login as first subscription"
```

---

### Task 4: `--switch` with rotation, plus active-slot healing at launch

**Files:**
- Modify: `bin/claude-profile`
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: Task 2/3 helpers.
- Produces:
  - `next_slot <newline-list> <current>` → next name in sorted cyclic order (first when current empty/last)
  - `switch_sub <profile> [target]` → validates, updates `active` + target `lastUsedAt`, journals `switch`, prints `switched <profile>: <old> → <new>`
  - `heal_active_slot <profile_dir>` → prints active name; when `active` is dangling but slots exist, repoints to first slot with a warning (used by `launch_profile` instead of bare `resolve_active_slot`)
  - CLI: `claude-profile --switch <profile> [name]`

- [ ] **Step 1: Write the failing tests**

Append before the summary:

```bash
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
```

Note: `file_contains ... -- "--add-sub"` — `file_contains` already uses `grep -qF --`, so pass the pattern as `"--add-sub"` without the extra `--` argument; write the check as:

```bash
check "single sub rotate: hint names --add-sub" file_contains "$TESTTMP/errout" "--add-sub"
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: switch/heal tests FAIL (unknown option `--switch`); prior tests pass.

- [ ] **Step 3: Implement**

Add to `bin/claude-profile` after `adopt_existing_login()`:

```bash
next_slot() {
  local slots="$1" current="$2" first next=""
  first="$(printf '%s\n' "$slots" | head -n1)"
  if [[ -n "$current" ]]; then
    next="$(printf '%s\n' "$slots" | awk -v c="$current" 'found { print; exit } $0 == c { found = 1 }')"
  fi
  printf '%s\n' "${next:-$first}"
}

switch_sub() {
  local profile="$1" target="${2:-}"
  validate_profile "$profile" || return $?

  local profile_dir
  profile_dir="$(profile_path "$profile")"
  if [[ ! -d "$profile_dir" ]]; then
    err "profile does not exist: $profile"
    return 2
  fi

  local slots count current
  slots="$(list_slots "$profile_dir")"
  count="$(printf '%s' "$slots" | grep -c . || true)"
  current="$(resolve_active_slot "$profile_dir")"

  if [[ -z "$target" ]]; then
    if (( count < 2 )); then
      err "profile $profile has $count subscription(s); add another with: claude-profile --add-sub $profile <name>"
      return 2
    fi
    target="$(next_slot "$slots" "$current")"
  fi

  validate_sub_name "$target" || return $?
  if [[ ! -d "$(slot_path "$profile_dir" "$target")" ]]; then
    err "subscription does not exist: $target (add with: claude-profile --add-sub $profile $target)"
    return 2
  fi

  if [[ "$target" == "$current" ]]; then
    printf '%s already active in %s\n' "$target" "$profile"
    return 0
  fi

  set_active_slot "$profile_dir" "$target"
  write_slot_meta "$(slot_path "$profile_dir" "$target")" "$target" "$(slot_storage_dir "$profile_dir" "$target")" || true
  journal_append "$profile_dir" switch "$target" "$current"
  printf 'switched %s: %s → %s\n' "$profile" "${current:-none}" "$target"
}

heal_active_slot() {
  local profile_dir="$1" active first
  active="$(resolve_active_slot "$profile_dir")"
  if [[ -n "$active" ]]; then
    printf '%s\n' "$active"
    return 0
  fi
  first="$(list_slots "$profile_dir" | head -n1)"
  [[ -n "$first" ]] || return 0
  err "warning: active subscription missing; using $first"
  set_active_slot "$profile_dir" "$first"
  printf '%s\n' "$first"
}
```

In `launch_profile()`, replace `active="$(resolve_active_slot "$profile_dir")"` with `active="$(heal_active_slot "$profile_dir")"`.

Add the case arm:

```bash
    --switch|switch)
      shift || true
      if [[ $# -lt 1 ]]; then
        err "usage: claude-profile --switch <profile> [name]"
        return 2
      fi
      switch_sub "$1" "${2:-}"
      return $?
      ;;
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: add --switch with rotation and active-slot healing"
```

---

### Task 5: `--subs` listing with email backfill

**Files:**
- Modify: `bin/claude-profile`
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: Task 2–4 helpers; stub auth (slot-level `stub-auth.json`).
- Produces:
  - `meta_field <slot_dir> <field>` → prints string field from `meta.json` or nothing
  - `backfill_email <profile_dir> <sub>` → probes auth for the slot's storage dir; on success saves email to meta and prints it
  - `list_subs_cmd <profile>` → table: `*` marker, name, email (`-` when unknown), lastUsedAt
  - CLI: `claude-profile --subs <profile>`

- [ ] **Step 1: Write the failing tests**

```bash
# --- subs listing ---
new_env
pdir="$CLAUDE_PROFILES_ROOT/personal"
run_wrapper --add-sub personal alice
run_wrapper --add-sub personal bob
mkdir -p "$pdir/.subscriptions/alice"
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
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: subs tests FAIL (unknown option); prior tests pass.

- [ ] **Step 3: Implement**

Add after `heal_active_slot()`:

```bash
meta_field() {
  [[ -f "$1/meta.json" ]] || return 0
  node -e '
try {
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const v = m[process.argv[2]];
  if (typeof v === "string") process.stdout.write(v);
} catch {}
' "$1/meta.json" "$2" 2>/dev/null || true
}

backfill_email() {
  local profile_dir="$1" sub="$2"
  local slot storage status email
  slot="$(slot_path "$profile_dir" "$sub")"
  storage="$(slot_storage_dir "$profile_dir" "$sub")"
  status="$(auth_status_json "$profile_dir" "$storage")" || return 0
  [[ "$(printf '%s' "$status" | json_field loggedIn)" == "true" ]] || return 0
  email="$(printf '%s' "$status" | json_field email)"
  [[ -n "$email" ]] || return 0
  write_slot_meta "$slot" "$sub" "$storage" "$email" >/dev/null 2>&1 || true
  printf '%s\n' "$email"
}

list_subs_cmd() {
  local profile="$1"
  validate_profile "$profile" || return $?

  local profile_dir
  profile_dir="$(profile_path "$profile")"
  if [[ ! -d "$profile_dir" ]]; then
    err "profile does not exist: $profile"
    return 2
  fi

  local active sub slot email marker any=0
  active="$(resolve_active_slot "$profile_dir")"
  while IFS= read -r sub; do
    [[ -n "$sub" ]] || continue
    any=1
    slot="$(slot_path "$profile_dir" "$sub")"
    email="$(meta_field "$slot" email)"
    [[ -n "$email" ]] || email="$(backfill_email "$profile_dir" "$sub")"
    marker=' '
    [[ "$sub" == "$active" ]] && marker='*'
    printf '%s %-20s %-30s %s\n' "$marker" "$sub" "${email:--}" "$(meta_field "$slot" lastUsedAt)"
  done <<EOF
$(list_slots "$profile_dir")
EOF
  if (( ! any )); then
    printf 'no subscriptions; profile uses its own login (add with: claude-profile --add-sub %s <name>)\n' "$profile"
  fi
}
```

Add the case arm:

```bash
    --subs|subs)
      shift || true
      list_subs_cmd "${1:-}"
      return $?
      ;;
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass. (`* bob` matches because the marker column is `*` + space + `%-20s` name — `printf '* %-20s'` yields `* bob                 `, and `grep -F "* bob"` finds it.)

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: add --subs listing with email backfill"
```

---

### Task 6: `--remove-sub` with trash and optional Keychain purge

**Files:**
- Modify: `bin/claude-profile`
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: Task 2–5 helpers; existing trash conventions (`$profiles_root/.trash`, timestamped names).
- Produces:
  - `purge_keychain_entry <storage_dir>` → darwin-only; computes service `Claude Code-credentials-<sha256(dir NFC)[0:8]>` and calls `${CLAUDE_PROFILE_SECURITY_BIN:-security} delete-generic-password -a <user> -s <service>`
  - `remove_sub <profile> <sub> [--purge]` → moves slot to trash as `<profile>-sub-<name>-<timestamp>`, repoints/clears `active`, journals when active changed; `--purge` refused for adopted slots (storageDir ≠ slot dir)
  - CLI: `claude-profile --remove-sub <profile> <name> [--purge]`
  - Env knob (tests): `CLAUDE_PROFILE_SECURITY_BIN`

- [ ] **Step 1: Write the failing tests**

```bash
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
cat > "$TESTTMP/fake-security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SECURITY_LOG:?}"
EOF
chmod 755 "$TESTTMP/fake-security"
export CLAUDE_PROFILE_SECURITY_BIN="$TESTTMP/fake-security"
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
export CLAUDE_PROFILE_SECURITY_BIN="$TESTTMP/fake-security"
pdir="$CLAUDE_PROFILES_ROOT/personal"
mkdir -p "$pdir"
printf '{"loggedIn":true,"email":"gus@x.com"}\n' > "$pdir/stub-auth.json"
run_wrapper --add-sub personal bob   # adopts "gus" first
run_wrapper --remove-sub personal gus --purge
check "purge adopted: refused" check_status 2
check "purge adopted: message" file_contains "$TESTTMP/errout" "refusing --purge"
unset CLAUDE_PROFILE_SECURITY_BIN FAKE_SECURITY_LOG
```

Note the darwin guard: on macOS these purge tests exercise the fake binary; `purge_keychain_entry` must consult `CLAUDE_PROFILE_SECURITY_BIN` **before** the darwin guard so the fake also runs on Linux CI. Implement the override check first, as shown below.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: remove-sub tests FAIL (unknown option); prior tests pass.

- [ ] **Step 3: Implement**

Add after `list_subs_cmd()`:

```bash
purge_keychain_entry() {
  local storage_dir="$1"
  local security_bin="${CLAUDE_PROFILE_SECURITY_BIN:-}"
  if [[ -z "$security_bin" ]]; then
    [[ "$(uname)" == "Darwin" ]] || return 0
    security_bin="security"
  fi
  local service account
  service="$(node -e '
const crypto = require("crypto");
const dir = process.argv[1].normalize("NFC");
process.stdout.write("Claude Code-credentials-" + crypto.createHash("sha256").update(dir).digest("hex").substring(0, 8));
' "$storage_dir")"
  account="${USER:-claude-code-user}"
  "$security_bin" delete-generic-password -a "$account" -s "$service" >/dev/null 2>&1
}

remove_sub() {
  local profile="$1" sub="$2" purge="${3:-}"
  validate_profile "$profile" || return $?
  validate_sub_name "$sub" || return $?

  local profile_dir slot
  profile_dir="$(profile_path "$profile")"
  slot="$(slot_path "$profile_dir" "$sub")"
  if [[ ! -d "$slot" ]]; then
    err "subscription does not exist: $sub"
    return 2
  fi

  local storage
  storage="$(slot_storage_dir "$profile_dir" "$sub")"
  if [[ "$purge" == "--purge" ]]; then
    if [[ "$storage" != "$slot" ]]; then
      err "refusing --purge: subscription $sub uses the profile's own credential store"
      return 2
    fi
    purge_keychain_entry "$storage" || err "warning: keychain purge failed (entry may not exist)"
  elif [[ -n "$purge" ]]; then
    err "unknown option: $purge"
    return 2
  fi

  local timestamp trash_dir trash_path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  trash_dir="$profiles_root/.trash"
  umask 077
  mkdir -p "$trash_dir"
  chmod 700 "$trash_dir" 2>/dev/null || true
  trash_path="$trash_dir/$profile-sub-$sub-$timestamp"
  mv "$slot" "$trash_path"

  if [[ -z "$(resolve_active_slot "$profile_dir")" ]]; then
    local next
    next="$(list_slots "$profile_dir" | head -n1)"
    if [[ -n "$next" ]]; then
      set_active_slot "$profile_dir" "$next"
      journal_append "$profile_dir" switch "$next" "$sub"
      printf 'active subscription now %s\n' "$next"
    else
      rm -f "$(subs_root "$profile_dir")/active"
      printf 'no subscriptions remain; profile uses its own login\n'
    fi
  fi
  printf 'moved subscription %s to %s\n' "$sub" "$trash_path"
}
```

Add the case arm:

```bash
    --remove-sub|remove-sub)
      shift || true
      if [[ $# -lt 2 ]]; then
        err "usage: claude-profile --remove-sub <profile> <name> [--purge]"
        return 2
      fi
      remove_sub "$1" "$2" "${3:-}"
      return $?
      ;;
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: add --remove-sub with trash and optional keychain purge"
```

---

### Task 7: `--doctor` support detection, launch warning, help text

**Files:**
- Modify: `bin/claude-profile` (`usage()`, `doctor()`, `launch_profile()`)
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: everything prior.
- Produces:
  - `supports_securestorage_env <claude_bin>` → `grep -aqs -- 'CLAUDE_SECURESTORAGE_CONFIG_DIR' <bin>`
  - `doctor` gains: `securestorage env: supported|NOT supported...` line and a `profile <name>: N subscription(s), active: <sub>` line per profile with slots
  - `launch_profile` warns to stderr when subs exist but the installed claude lacks support
  - `usage()` documents the four new subcommands

- [ ] **Step 1: Write the failing tests**

```bash
# --- doctor + support detection ---
new_env
run_wrapper --add-sub personal alice
run_wrapper --doctor
check "doctor: supported line" file_contains "$TESTTMP/out" "securestorage env: supported"
check "doctor: profile sub count" file_contains "$TESTTMP/out" "profile personal: 1 subscription(s), active: alice"

# unsupported stub → launch warning + doctor line
cat > "$TESTTMP/stub-unsupported" <<'EOF'
#!/usr/bin/env bash
{ printf 'argv=%s\n' "$*"; } > "${STUB_RECORD_FILE:?}"
EOF
chmod 755 "$TESTTMP/stub-unsupported"
export CLAUDE_PROFILE_CLAUDE_BIN="$TESTTMP/stub-unsupported"
run_wrapper personal
check "unsupported: launch warns" file_contains "$TESTTMP/errout" "does not support CLAUDE_SECURESTORAGE_CONFIG_DIR"
run_wrapper --doctor
check "unsupported: doctor reports" file_contains "$TESTTMP/out" "securestorage env: NOT supported"

# help text
export CLAUDE_PROFILE_CLAUDE_BIN="$here/stub-claude"
run_wrapper --help
check "help: --add-sub documented" file_contains "$TESTTMP/out" "add-sub"
check "help: --switch documented" file_contains "$TESTTMP/out" "switch"
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: doctor/warning tests FAIL; help test may pass only after usage() is updated — confirm the doctor ones fail.

- [ ] **Step 3: Implement**

Add near `supports_session_color()`:

```bash
supports_securestorage_env() {
  grep -aqs -- 'CLAUDE_SECURESTORAGE_CONFIG_DIR' "$1"
}
```

In `launch_profile()`, inside the `if [[ -n "$active" ]]` block, after the `export`:

```bash
    if ! supports_securestorage_env "$claude_bin"; then
      err "warning: installed claude does not support CLAUDE_SECURESTORAGE_CONFIG_DIR; subscriptions are inert for this launch"
    fi
```

In `doctor()`, after the session-color block inside the `if claude_bin=...` branch:

```bash
    if supports_securestorage_env "$claude_bin"; then
      printf 'securestorage env: supported (per-subscription credentials active)\n'
    else
      printf 'securestorage env: NOT supported by installed claude; subscriptions are inert\n'
    fi
```

At the end of `doctor()`:

```bash
  local p pd count active
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    pd="$(profile_path "$p")"
    count="$(list_slots "$pd" | grep -c . || true)"
    if (( count > 0 )); then
      active="$(resolve_active_slot "$pd")"
      printf 'profile %s: %s subscription(s), active: %s\n' "$p" "$count" "${active:--}"
    fi
  done <<EOF
$(list_profiles)
EOF
```

In `usage()`, add to the Usage list (after the `--sync-settings` line):

```text
  claude-profile --add-sub <profile> <name>
  claude-profile --switch <profile> [name]
  claude-profile --subs <profile>
  claude-profile --remove-sub <profile> <name> [--purge]
```

and append a paragraph before the auth-env paragraph:

```text
A profile can hold multiple login subscriptions. --add-sub creates one and
launches claude for /login; --switch changes which one the next launch uses
(no argument rotates). History, MCPs, and --resume are shared across a
profile's subscriptions; each subscription keeps its own credentials.
```

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile test/run-tests.sh
git commit -m "feat: doctor support detection and launch warning for securestorage env"
```

---

### Task 8: Per-subscription usage attribution in `claude-profile-usage`

**Files:**
- Modify: `bin/claude-profile-usage`
- Test: `test/run-tests.sh`

**Interfaces:**
- Consumes: journal format `{"ts","event","sub","from"}`; slot layout from Task 2; transcript line shape `{"type":"assistant","timestamp":"...","requestId":"...","message":{"id":"...","usage":{"input_tokens":N,"output_tokens":N,"cache_creation_input_tokens":N,"cache_read_input_tokens":N}}}`.
- Produces:
  - `sub_token_rows <profile_dir> <since_iso>` → bash function printing a JSON array `[{sub, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, messages}]`, deduped by `message.id:requestId`, bucketed by journal windows, `(pre-subscriptions)` for pre-journal usage
  - CLI flag: `--json` (after the period argument) → machine-readable rows instead of `console.table`
  - Output rows for a profile with subs: `<profile>/<sub>` rows (status `active`/`stored`, tokens exact, `Est. cost` = profile ccusage cost × token share) plus the existing `<profile>` total row

- [ ] **Step 1: Write the failing tests**

```bash
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
EOF
printf '{"loggedIn":true,"email":"alice@x.com"}\n' > "$pdir/.subscriptions/alice/stub-auth.json"

# fake ccusage on PATH
mkdir -p "$TESTTMP/bin"
cat > "$TESTTMP/bin/ccusage" <<'EOF'
#!/usr/bin/env bash
printf '{"totals":{"totalTokens":736,"inputTokens":410,"outputTokens":121,"cacheCreationTokens":5,"cacheReadTokens":200,"totalCost":10},"daily":[{"date":"2026-07-02","totalTokens":736}]}\n'
EOF
chmod 755 "$TESTTMP/bin/ccusage"

usage_json="$(PATH="$TESTTMP/bin:$PATH" CLAUDE_PROFILES_ROOT="$CLAUDE_PROFILES_ROOT" CLAUDE_PROFILE_CLAUDE_BIN="$here/stub-claude" "$usage_tool" daily --json 2>"$TESTTMP/errout")"
printf '%s' "$usage_json" > "$TESTTMP/usage.json"

usage_field() { node -e '
const rows = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = rows.find(r => r.profile === process.argv[2] && (r.sub ?? "") === (process.argv[3] ?? ""));
process.stdout.write(row ? String(row[process.argv[4]]) : "MISSING");
' "$TESTTMP/usage.json" "$@"; }

check_eq "usage: alice tokens (dedup applied)" "355" "$(usage_field personal alice totalTokens)"
check_eq "usage: bob tokens" "370" "$(usage_field personal bob totalTokens)"
check_eq "usage: pre-subscriptions bucket" "11" "$(usage_field personal '(pre-subscriptions)' totalTokens)"
check_eq "usage: alice status active" "active" "$(usage_field personal alice status)"
check_eq "usage: bob status stored" "stored" "$(usage_field personal bob status)"
check "usage: cost apportioned to bob" bash -c '
v="$(node -e "
const rows = JSON.parse(require(\"fs\").readFileSync(process.argv[1], \"utf8\"));
const row = rows.find(r => r.profile === \"personal\" && r.sub === \"bob\");
process.stdout.write(row ? row.totalCost.toFixed(2) : \"MISSING\");
" "$1")"
[[ "$v" == "5.03" ]]' _ "$TESTTMP/usage.json"
```

Attribution math for the fixture: alice window `2026-07-01T00Z ≤ ts < 2026-07-02T00Z` gets m1 once (100+50+5+200 = 355; the duplicate line is dropped by the `m1:r1` dedup key); bob window from `2026-07-02T00Z` gets m2 (300+70 = 370); m0 predates the journal → `(pre-subscriptions)` bucket (10+1 = 11). Cost: bob share = 370/736 × $10 = $5.027 → `5.03`.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash test/run-tests.sh`
Expected: usage tests FAIL (`--json` unknown / rows missing); prior tests pass.

- [ ] **Step 3: Implement**

In `bin/claude-profile-usage`:

1. Accept `--json` right after the period in `main()`:

```bash
  local as_json=0
  if [[ "${1:-}" == "--json" ]]; then
    as_json=1
    shift || true
  fi
```

(placed after the `case "$period"` block's `shift`.)

2. Add helper functions after `run_ccusage_json()`:

```bash
list_slots() {
  local root="$1/.subscriptions"
  [[ -d "$root" ]] || return 0
  find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort
}

active_slot() {
  local f="$1/.subscriptions/active" name
  [[ -f "$f" ]] || return 0
  name="$(cat "$f")"
  [[ -n "$name" && -d "$1/.subscriptions/$name" ]] || return 0
  printf '%s\n' "$name"
}

since_to_iso() {
  # ccusage --since takes YYYYMMDD; normalize to ISO for message filtering
  local s="$1"
  if [[ "$s" =~ ^[0-9]{8}$ ]]; then
    printf '%s-%s-%sT00:00:00Z\n' "${s:0:4}" "${s:4:2}" "${s:6:2}"
  elif [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%sT00:00:00Z\n' "$s"
  else
    printf '%s\n' "$s"
  fi
}

sub_token_rows() {
  local profile_dir="$1" since_iso="${2:-}"
  node - "$profile_dir/.subscriptions/switch-log.jsonl" "$profile_dir/projects" "$since_iso" <<'NODE'
const fs = require("fs");
const path = require("path");
const [journalPath, projectsDir, since] = process.argv.slice(2);

let events = [];
try {
  events = fs.readFileSync(journalPath, "utf8")
    .split("\n").filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(e => e && e.ts && e.sub)
    .sort((a, b) => (a.ts < b.ts ? -1 : 1));
} catch {}

function subAt(ts) {
  let sub = "(pre-subscriptions)";
  for (const e of events) {
    if (e.ts <= ts) sub = e.sub;
    else break;
  }
  return sub;
}

function* jsonlFiles(dir) {
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const ent of entries) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) yield* jsonlFiles(p);
    else if (ent.name.endsWith(".jsonl")) yield p;
  }
}

const totals = {};
const seen = new Set();
function bucket(sub) {
  return totals[sub] ??= {
    sub, inputTokens: 0, outputTokens: 0,
    cacheCreationTokens: 0, cacheReadTokens: 0,
    totalTokens: 0, messages: 0
  };
}

for (const file of jsonlFiles(projectsDir)) {
  let lines;
  try { lines = fs.readFileSync(file, "utf8").split("\n"); } catch { continue; }
  for (const line of lines) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    const usage = entry?.message?.usage;
    if (!usage || !entry.timestamp) continue;
    if (since && entry.timestamp < since) continue;
    const key = entry.message.id && entry.requestId
      ? `${entry.message.id}:${entry.requestId}` : null;
    if (key) {
      if (seen.has(key)) continue;
      seen.add(key);
    }
    const b = bucket(subAt(entry.timestamp));
    const inp = usage.input_tokens ?? 0;
    const out = usage.output_tokens ?? 0;
    const cc = usage.cache_creation_input_tokens ?? 0;
    const cr = usage.cache_read_input_tokens ?? 0;
    b.inputTokens += inp;
    b.outputTokens += out;
    b.cacheCreationTokens += cc;
    b.cacheReadTokens += cr;
    b.totalTokens += inp + out + cc + cr;
    b.messages += 1;
  }
}
console.log(JSON.stringify(Object.values(totals).sort((a, b) => a.sub.localeCompare(b.sub))));
NODE
}
```

3. In the per-profile loop in `main()`, change the flow: keep the existing logged-in gate and ccusage row for profiles **without** slots. For profiles **with** slots, skip the profile-level logged-in gate (slots decide), still run ccusage for the profile totals, then emit one row per token bucket. Replace the loop body's row-writing node call with logic that first computes:

```bash
    slots="$(list_slots "$profile_dir")"
    sub_rows='[]'
    active=""
    since_iso=""
    if [[ -n "$slots" ]]; then
      active="$(active_slot "$profile_dir")"
      prev=""
      for a in "$@"; do
        [[ "$prev" == "--since" ]] && since_iso="$(since_to_iso "$a")"
        prev="$a"
      done
      sub_rows="$(sub_token_rows "$profile_dir" "$since_iso")"
    fi
```

and passes `sub_rows`, `active`, and the newline list of slot names into the row-accumulating node heredoc via env. The existing call line becomes:

```bash
    CCUSAGE_JSON="$ccusage_json" SUB_ROWS_JSON="$sub_rows" ACTIVE_SUB="$active" SLOT_NAMES="$slots" \
      node - "$rows_file" "$profile" "$profile_dir" "$period" "$status" "$args_json" <<'NODE'
```

Inside that node script, after building the existing profile `row`, append per-sub rows:

```js
const subRows = JSON.parse(process.env.SUB_ROWS_JSON || "[]");
const activeSub = process.env.ACTIVE_SUB || "";
const slotNames = (process.env.SLOT_NAMES || "").split("\n").filter(Boolean);
if (slotNames.length > 0) {
  const grand = subRows.reduce((n, r) => n + r.totalTokens, 0) || 1;
  const known = new Set(subRows.map(r => r.sub));
  for (const name of slotNames) {
    if (!known.has(name)) subRows.push({
      sub: name, inputTokens: 0, outputTokens: 0,
      cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0, messages: 0
    });
  }
  for (const r of subRows.sort((a, b) => a.sub.localeCompare(b.sub))) {
    rows.push({
      profile, sub: r.sub,
      status: r.sub === activeSub ? "active" : (slotNames.includes(r.sub) ? "stored" : "history"),
      periods: row.periods,
      totalTokens: r.totalTokens,
      inputTokens: r.inputTokens,
      outputTokens: r.outputTokens,
      cacheCreationTokens: r.cacheCreationTokens,
      cacheReadTokens: r.cacheReadTokens,
      totalCost: row.totalCost * (r.totalTokens / grand),
      latestPeriod: row.latestPeriod,
      latestTokens: row.latestTokens,
      args
    });
  }
}
rows.push(row);  // profile total row, as today
```

(`rows` here is the array read from/written back to `rows_file`; `row` is the existing profile-total object. `(pre-subscriptions)` rows get status `history`.)

Also change the logged-in gate at the top of the loop to:

```bash
    if [[ -z "$(list_slots "$profile_dir")" ]] && ! profile_logged_in "$profile_dir" "$claude_bin"; then
      continue
    fi
```

4. In the final rendering node script, honor `--json`: pass `as_json` as an extra argv and short-circuit:

```js
const asJson = process.argv[4] === "1";
if (asJson) {
  console.log(JSON.stringify(rows));
  process.exit(0);
}
```

and in the table mapping, render the Profile column as `row.sub ? `${row.profile}/${row.sub}` : row.profile`.

Call site change: `node - "$rows_file" "$period" "$as_json" <<'NODE'` — adjust `process.argv` indices accordingly (`[rowsPath, period, asJsonFlag]`).

- [ ] **Step 4: Run tests**

Run: `npm test`
Expected: all pass, including the four attribution numbers (355 / 370 / 11 / 5.03).

- [ ] **Step 5: Commit**

```bash
git add bin/claude-profile-usage test/run-tests.sh
git commit -m "feat: per-subscription usage attribution from switch journal"
```

---

### Task 9: Documentation and release prep

**Files:**
- Modify: `README.md`, `bin/claude-profile` (VERSION), `package.json` (version), `docs/superpowers/specs/2026-07-09-profile-subscriptions-design.md` (CLI grammar sync)

**Interfaces:**
- Consumes: final CLI surface from Tasks 2–8.
- Produces: user-facing docs; version 0.4.0.

- [ ] **Step 1: Update README**

Add a `## Subscriptions` section after `## Profile Storage and Shared Config` covering: the personal/work mental model; `--add-sub` / `--switch` (rotation) / `--subs` / `--remove-sub [--purge]` with the exit → switch → `--resume` workflow example; shared history/MCP registrations vs per-subscription credentials; the one-time `/mcp` re-auth per subscription for remote MCP servers; `claude-profile-usage` per-subscription rows and the parallel-sessions attribution caveat; the note that subscriptions rely on Claude Code's `CLAUDE_SECURESTORAGE_CONFIG_DIR` support (checked by `--doctor`). Example block:

```sh
claude-profile --add-sub personal alice   # launches claude; /login as alice
claude-profile --add-sub personal bob     # launches claude; /login as bob
claude-profile personal                   # runs on bob (active)
# ... rate limit hit: exit claude ...
claude-profile --switch personal          # bob → alice
claude-profile personal --resume          # same conversation, fresh quota
```

- [ ] **Step 2: Sync spec CLI grammar**

In the spec's Flows section, update the four flow headings to the option-first grammar (`claude-profile --add-sub <profile> <name>`, etc.) to match the implementation.

- [ ] **Step 3: Bump versions**

- `bin/claude-profile`: `VERSION="0.4.0"`
- `package.json`: `"version": "0.4.0"`

- [ ] **Step 4: Run full suite**

Run: `npm test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add README.md bin/claude-profile package.json docs/superpowers/specs/2026-07-09-profile-subscriptions-design.md
git commit -m "docs: document subscriptions and bump to 0.4.0"
```

---

## Manual E2E acceptance (user-run, not automatable)

1. `claude-profile --add-sub personal <name1>` → `/login` with account 1, exit.
2. `claude-profile --add-sub personal <name2>` → `/login` with account 2, exit.
3. `claude-profile personal` → converse, exit.
4. `claude-profile --switch personal` → `claude-profile personal --resume` → the same conversation continues on the other account.
5. `/mcp` re-auth the remote MCP once under the second subscription; switch back and forth; both keep working.
6. `claude-profile-usage` → per-subscription rows with plausible splits.
7. Check whether any UI surface shows a stale account identity after a switch (the `.claude.json` `oauthAccount` open item from the spec).
