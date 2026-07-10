# Design: Multiple Subscriptions per Profile

Date: 2026-07-09
Status: Approved design direction; architecture refined after empirical spike
Repo: claude-profile

## Problem

Today one profile = one config dir = one Claude account. Switching accounts
means switching profiles, which discards conversation history, `--resume`
continuity, MCP registrations, and project state — because each account lives
in a different `CLAUDE_CONFIG_DIR`.

The user wants identity contexts ("personal", "work") that each own their
history, MCPs, and connections, with N subscriptions (accounts) attached to
each context. Within a context: hit a rate limit → exit → switch subscription
→ relaunch → `--resume` the same conversation. Across contexts: full
isolation, as today.

## Requirements (from interview)

1. A profile shares one history/MCP/project state across its subscriptions;
   profiles are isolated from each other.
2. Workflow to support: exit → switch → relaunch → `--resume` the same
   conversation on the other subscription.
3. Sticky active subscription per profile; explicit switch command; `--switch`
   with no argument rotates to the next subscription.
4. Credentials stored locally once per subscription (login once, switch
   freely). No re-login on switch.
5. Remote MCP OAuth (Sentry/Linear style) must keep working across switches —
   nothing may be invalidated by a switch.
6. `claude-profile-usage` must attribute usage per subscription.
7. Fresh start: no migration of existing profiles required; the design is
   nevertheless fully backward compatible.

Out of scope (YAGNI, explicitly declined or unneeded):

- Automatic switching on rate-limit detection. Switching is manual.
- Merging histories of existing per-account profiles.

## Spike findings (2026-07-09, claude-code current build, macOS)

Empirically verified on this machine; the decompiled CLI source confirms the
mechanism:

1. On macOS, credentials live in the login Keychain as a generic password:
   service `Claude Code-credentials` for the default config dir, or
   `Claude Code-credentials-<first-8-hex-of-sha256(dir)>` for a custom dir;
   account = OS username. A plaintext-file fallback store exists and the CLI
   migrates between the two automatically.
2. The credential blob is JSON with two top-level keys: `claudeAiOauth`
   (access/refresh tokens, expiry, `subscriptionType`, `rateLimitTier`) and
   `mcpOAuth` (per-server OAuth entries for remote MCP servers).
3. **`CLAUDE_SECURESTORAGE_CONFIG_DIR`**: when set, the credential store is
   keyed by *this* path instead of `CLAUDE_CONFIG_DIR`. Verified with
   read-only `claude auth status --json` probes: a scratch config dir reports
   logged-out; the same scratch config dir with the env var pointing at the
   default store reports logged-in. Credentials follow the env var; all other
   state follows the config dir.
4. Credential writes are serialized via a `.storage-write` lock in the
   storage dir; each storage dir is fully independent.

## Architecture

**A profile is one config dir. A subscription is a credential-storage
directory selected at launch via `CLAUDE_SECURESTORAGE_CONFIG_DIR`.**

- `CLAUDE_CONFIG_DIR` = profile dir → history, `.claude.json` (MCPs, project
  trust), settings, todos: shared within the profile, isolated across
  profiles. Unchanged from today.
- `CLAUDE_SECURESTORAGE_CONFIG_DIR` = active subscription's storage dir →
  Claude Code itself keeps each subscription's credentials in its own
  Keychain entry (or fallback file). The wrapper never reads, writes, or
  copies credential material.
- Switching = changing which storage dir the next launch points at. No
  save-before-load, no keychain surgery, no live-session guard: running
  sessions hold their own env and are unaffected.

Consequences:

- Parallel windows on *different* subscriptions of the same profile work
  (bonus capability; see usage-attribution caveat).
- `mcpOAuth` rides in the same store, so remote-MCP OAuth is **per
  subscription**: each remote MCP server needs one `/mcp` re-auth per
  subscription, once ever. Nothing is invalidated by switching — each
  subscription keeps its own persistent MCP tokens. This satisfies
  requirement 5's letter (nothing breaks) at a small one-time setup cost,
  and it buys the elimination of the entire credential-manipulation risk
  surface. Surfaced to the user in `--subs` output the first time a new slot
  is used.

### Rejected alternatives

- **Config dir per subscription + shared state symlinks:** `.claude.json`
  mixes shareable and per-account state in one file that Claude replaces by
  atomic rename; a rename converts a symlink into a private copy and forks
  state. Requires a sync engine for a file we don't control.
- **Credential slot swap (wrapper copies `claudeAiOauth` between slots and
  the live store):** works, and preserves shared `mcpOAuth`, but depends on
  many undocumented internals (service-name hashing, account naming, blob
  schema, hex encoding, lock protocol) and puts the wrapper in the business
  of writing token material, with real corruption/logout failure modes.
  Retained as the documented fallback if `CLAUDE_SECURESTORAGE_CONFIG_DIR`
  is ever removed. The env var's presence is checked by `--doctor` (string
  scan of the installed CLI binary) so regression is diagnosable in one
  command.

## Storage layout

```
~/.claude-profiles/
  personal/                      # profile = CLAUDE_CONFIG_DIR (unchanged)
    projects/                    # shared history; --resume works across switches
    .claude.json                 # shared MCPs, project trust (Claude-managed)
    settings.json                # synced from ~/.claude as today
    profile-color                # existing machinery, untouched
    .subscriptions/              # NEW; dot-prefixed, mode 700
      active                     # name of the active subscription
      switch-log.jsonl           # journal: {ts, event, sub[, from]} per line
      alice/                     # slot dir = its own securestorage dir
        meta.json                # {name, email?, storageDir, createdAt, lastUsedAt}
      bob/
        meta.json
  work/                          # isolated profile, same shape
```

- A profile with no `.subscriptions/` slots behaves exactly as today (env var
  never set). The feature activates only when subscriptions are added.
- Slot dirs double as the securestorage dirs, except an **adopted** slot (see
  add-sub) whose `storageDir` is the profile dir itself, preserving an
  existing login untouched.
- Journal timestamps are UTC ISO-8601. Events: `switch` (active changed) and
  `launch` (a session started under a subscription).

## Flows

### Bare launch — `claude-profile <profile> [args...]` (still `exec`s)

1. Init/sync as today.
2. If slots exist and `active` names a valid slot: export
   `CLAUDE_SECURESTORAGE_CONFIG_DIR=<slot storageDir>`, append a `launch`
   journal entry, set terminal title `claude:<profile> (<sub-name>)`.
3. If `active` is stale/missing but slots exist: warn, pick the
   lexicographically first slot, heal `active`.
4. No slots: exactly today's behavior.

### Add — `claude-profile <profile> --add-sub <name>`

1. Validate name (same charset as profile names); refuse duplicates.
2. If this is the first slot and the profile already has a live login
   (`claude auth status --json` reports loggedIn under the profile dir),
   auto-adopt it first: create a slot named from the reported email
   local-part (sanitized; fallback `sub1`) with `storageDir` = profile dir.
3. Create the new slot dir (mode 700), write `meta.json` with
   `storageDir` = slot dir, set `active` to it, append journal entry.
4. Launch claude normally (exec, env var pointing at the new empty slot);
   the user runs `/login` inside — identical to first-time profile setup.
   Post-login, the next `--subs` invocation backfills the email in
   `meta.json` from `claude auth status --json`.

### Switch — `claude-profile <profile> --switch [name]`

1. Resolve target: given name, else next slot in sorted rotation after the
   current active. Error if fewer than 2 slots exist.
2. Write `active`, update `lastUsedAt`, append `switch` journal entry.
3. Print `switched <profile>: <old> → <new>`. That's the whole operation —
   no credential I/O, safe at any time, even with sessions running.

### List / remove — `--subs`, `--remove-sub <name>`

- `--subs`: one line per slot — name, email (backfilled via
  `claude auth status` against the slot's storage dir, read-only), `*` on
  active, lastUsedAt.
- `--remove-sub`: moves the slot dir to `~/.claude-profiles/.trash/` with the
  existing timestamped naming. The Keychain entry for that slot is left in
  place (restorable); `--remove-sub --purge` additionally deletes it via
  `security delete-generic-password`. Removing the active slot re-points
  `active` at the first remaining slot, or clears it when none remain.

## Usage attribution (`claude-profile-usage`)

- The journal turns each profile's history into windows: from each
  `switch`/first-`launch` event until the next. Time before the first entry
  goes to a synthetic `(pre-subscriptions)` bucket.
- **Token counts (exact for serial use):** read `projects/**/*.jsonl`
  transcripts; each assistant message carries a timestamp and usage block;
  bucket every message into its window. Correct even for one conversation
  resumed across a switch. Caveat, stated in output: simultaneous parallel
  sessions on different subscriptions of the same profile blur attribution
  within the overlap.
- **Cost (approximate, stated):** ccusage runs per profile as today; the
  profile's estimated cost is apportioned to subscriptions by token share.
- Output: one row per (profile, subscription) plus a profile total row.
  Profiles without subscriptions render exactly as today.
- Logged-in detection: per slot via `claude auth status --json` with the
  slot's storage dir — read-only and safe for inactive slots (no swapping
  required, a direct benefit of the architecture).

## Error handling

| Case | Behavior |
|---|---|
| `--switch` target slot missing | Error naming `--add-sub <name>` |
| `--switch` with <2 slots | Error explaining `--add-sub` |
| `active` stale/missing | Warn, heal to first slot (launch) / show no marker (`--subs`) |
| Slot `meta.json` corrupt | Quarantine slot to `.trash`, prompt `--add-sub` |
| Journal append fails | Operation succeeds; warn of attribution gap |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` absent from installed CLI | `--doctor` reports it; launch warns once per profile that subscriptions are inert (all slots resolve to the profile's own store) |
| node missing | Same policy as settings sync today: clear error |

## Testing

1. **Static:** `bash -n` on both scripts (existing `npm test`).
2. **Scripted suite:** point `CLAUDE_PROFILE_CLAUDE_BIN` at a stub claude
   that records its environment and fakes `auth status --json`. Cover:
   add-sub happy path; auto-adopt of an existing login; switch by name;
   rotate; launch env var selection (set with slots, absent without);
   active-file healing; remove-sub active/inactive/last; journal contents;
   usage windowing over synthetic transcripts; zero-subscription profiles
   byte-identical behavior.
3. **Manual E2E acceptance (user):** create profile → `--add-sub` twice with
   two real accounts → converse → exit → `--switch` → `--resume` the same
   conversation → re-auth the remote MCP once under the second subscription
   and confirm it persists across subsequent switches → usage report shows
   both subscriptions with plausible splits.

## Risks and open items

- **`CLAUDE_SECURESTORAGE_CONFIG_DIR` is undocumented** and could change in
  a future Claude Code release. Mitigations: `--doctor` scans the installed
  binary for the string and reports; failure mode is inert (slots resolve to
  the same store — nothing corrupts); the slot-swap design remains in this
  spec as the fallback implementation strategy.
- **`oauthAccount` staleness in `.claude.json`** (profile-level, written by
  whichever account logged in last): verify during manual E2E whether any
  UI surface shows the wrong account; if so, evaluate patching it at launch
  from slot metadata.
- Usage cost split is approximate by design; token counts are exact for the
  serial-switching workflow.
