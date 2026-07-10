# Design: Multiple Subscriptions per Profile

Date: 2026-07-09
Status: Approved pending user review
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

1. A profile group shares one history/MCP/project state; groups are isolated
   from each other.
2. Workflow to support: exit → switch → relaunch → `--resume` the same
   conversation on the other subscription.
3. Sticky active subscription per profile; explicit switch command; `--switch`
   with no argument rotates to the next subscription.
4. Credentials stored locally once per subscription (login once, swap
   freely). No re-login on switch.
5. The user's MCP servers use their own OAuth (Sentry/Linear style). A
   subscription switch must not invalidate MCP OAuth tokens.
6. `claude-profile-usage` must attribute usage per subscription, not just per
   profile.
7. Fresh start: no migration of existing profiles; breaking CLI changes are
   acceptable (though the design ends up fully backward compatible anyway).

Out of scope (YAGNI, explicitly declined or unneeded):

- Automatic switching on rate-limit detection. Switching is manual.
- Running two subscriptions of the same profile in parallel windows. One live
  credential per profile; parallel windows on the *same* subscription remain
  fine.
- Merging histories of existing per-account profiles.

## Architecture (first principles)

Claude Code binds all durable state — `projects/` history, `.claude.json`
(MCP registrations, project trust), todos, settings — to the config dir, and
rewrites it frequently via atomic renames. That state is designed to be
singular per identity context. The only state that differs between
subscriptions is the account credential, which Claude itself treats as a
swappable singleton (`/login` replaces it in place).

Therefore: **a profile is one config dir (unchanged); subscriptions are
time-multiplexed credentials within it.**

Rejected alternative: config dir per subscription with shared state symlinked
from a group dir. `.claude.json` mixes shareable state (MCPs, trust) with
per-account state (`oauthAccount`) in one file that Claude replaces by atomic
rename — a rename silently converts a symlink into a private copy and forks
state. Sharing it would require a bidirectional sync engine for a file we do
not control. Its only benefit (parallel windows across subscriptions) is not
required.

## Storage layout

```
~/.claude-profiles/
  personal/                      # profile = CLAUDE_CONFIG_DIR (unchanged)
    projects/                    # shared history; --resume works across switches
    .claude.json                 # shared MCPs, project trust (Claude-managed)
    settings.json                # synced from ~/.claude as today
    profile-color                # existing machinery, untouched
    .subscriptions/              # NEW; dot-prefixed, mode 700
      active                     # file containing the active subscription name
      switch-log.jsonl           # one JSON object per line: {ts, from, to}
      alice/
        meta.json                # {email, org?, createdAt, lastUsedAt}
        credentials              # account-OAuth snapshot, mode 600
      bob/
        meta.json
        credentials
  work/                          # isolated profile, same shape
```

- A profile with no `.subscriptions/` slots behaves exactly as today. The
  feature activates only when subscriptions are added. No migration needed;
  existing profiles keep working.
- `switch-log.jsonl` timestamps are UTC ISO-8601. `from` is the previous
  subscription name (or `null` for the first activation), `to` the new one.

## Component: credential store

A small abstraction with one contract:

- `read_live(config_dir)` → account-OAuth blob currently in effect
- `write_live(config_dir, blob)` → install account-OAuth blob

The blob is **only the Anthropic account OAuth**. MCP OAuth tokens live in
the same underlying store and must be preserved untouched by both operations
(surgical read/merge/write, not whole-store replacement).

Two backends, selected at runtime by `--doctor`-visible detection:

- **File backend**: `$CONFIG_DIR/.credentials.json` — read/merge/write the
  account-OAuth key via node, preserving all other keys.
- **Keychain backend (macOS)**: read/write the relevant generic password
  entry via the `security` CLI, applying the same surgical merge to the JSON
  payload.

**Verification spike (first implementation task):** a throwaway script sets a
scratch `CLAUDE_CONFIG_DIR`, performs a login, and reports exactly where the
account OAuth and MCP OAuth tokens land on macOS (file vs. Keychain; one
entry or several; how the entry is keyed when `CLAUDE_CONFIG_DIR` is
non-default). The spike's findings pick the backend and settle whether the
`oauthAccount` block inside `.claude.json` must be patched on switch or is
reconciled by Claude on startup. No swap code is written before the spike
concludes.

## Flows

### Add a subscription — `claude-profile <profile> --add-sub <name>`

1. Validate name (same charset rules as profile names). Refuse duplicates.
2. If a live account OAuth exists, save it into the current active slot.
   If no slot exists yet (first-ever `--add-sub` on a profile that already
   has a login), auto-adopt the existing login into a new slot first: name it
   from the account email's local-part reported by `claude auth status
   --json` (sanitized to the profile-name charset), falling back to `sub1`
   if no email is available; record it in the journal as the initial entry.
3. Clear the live account OAuth (MCP OAuth untouched).
4. Run claude as a **child process** (this flow alone does not `exec`) so the
   user can `/login` with the new account.
5. On exit: snapshot live account OAuth into the new slot, extract account
   email into `meta.json`, set `active` to the new name, append journal entry.
6. If the user exits without logging in (no live credential): restore the
   previous slot's credential, delete the empty slot, report failure.

### Switch — `claude-profile <profile> --switch [name]`

1. Resolve target: given name, else the next subscription in sorted rotation
   after the current active one. Error if the profile has fewer than 2 slots.
2. Guard: if a claude process is running with this profile's config dir
   (best-effort `pgrep -f` on `CLAUDE_CONFIG_DIR=<dir>` plus a check that the
   dir is referenced by a live process), refuse unless `--force`. Swapping
   credentials under a live session breaks its token refresh.
3. Save live account OAuth into the current active slot (**save-before-load
   is mandatory** — tokens rotate on refresh, and since swaps only ever
   happen through the wrapper, saving at switch time keeps slots fresh).
4. Write target slot's blob to the live store.
5. Update `active`, update both slots' `lastUsedAt`, append journal entry.
6. Print `switched <profile>: <old-email> → <new-email>`.

Ordering guarantees atomicity of outcome: a failure at step 3 aborts before
anything is written; a failure at step 4 leaves the current slot saved and
the live store untouched (write happens via temp+rename for the file backend,
single `security` call for keychain); `active` is only updated after a
successful step 4.

### Bare launch — `claude-profile <profile> [args...]`

Unchanged, still `exec`s claude. Additions:

- Terminal title becomes `claude:<profile> (<active-email>)` when
  subscriptions exist.
- If `active` names a missing/corrupt slot: warn and continue with whatever
  live credential exists (never block a launch).

### List / remove — `--subs`, `--remove-sub <name>`

- `--subs`: one line per slot: name, email, `*` on active, lastUsedAt.
- `--remove-sub`: moves the slot dir to `~/.claude-profiles/.trash/` with the
  existing timestamped naming. Removing the active slot clears `active` (next
  launch uses the live credential as-is).

## Usage attribution (`claude-profile-usage`)

- The journal converts each profile's history into windows:
  `[(t0, alice), (t1, bob), …]` — from each entry's `ts` until the next.
  Time before the first journal entry is attributed to a synthetic
  `(pre-subscriptions)` bucket.
- **Token counts (exact):** read `projects/**/*.jsonl` transcripts directly;
  each assistant message carries a timestamp and a usage block; bucket every
  message into its window. This stays correct even for a single conversation
  resumed across a switch — the core workflow — which any session-level
  attribution would misassign.
- **Cost (approximate, stated):** ccusage runs per profile as today; the
  profile's estimated cost is apportioned to subscriptions by token share.
  Reimplementing per-model pricing tables is explicitly not worth it.
- Output: one row per (profile, subscription) plus a profile total row.
  Profiles without subscriptions render exactly as today.
- Logged-in detection: a subscription is listed if its slot exists; the
  active slot is additionally verified via `claude auth status --json` as
  today. Inactive slots are marked `stored` rather than probed (probing would
  require swapping credentials just to ask).

## Error handling

| Case | Behavior |
|---|---|
| `--switch` target slot missing | Error naming `--add-sub <name>` |
| Live claude session in profile | Refuse switch; `--force` overrides |
| Keychain/file read or write denied | Actionable error; ordered flow guarantees no half-swap |
| Journal append fails | Switch succeeds; warn that usage attribution has a gap |
| Corrupt slot (bad JSON) | Quarantine slot to `.trash`, prompt re-login via `--add-sub` |
| `active` file stale/missing | Warn, launch with live credential; `--subs` shows no active marker |
| node missing | Same policy as settings sync today: required, clear error |

## Testing

1. **Static:** `bash -n` on both scripts (existing `npm test`), extended to
   any new files.
2. **Scripted suite:** point `CLAUDE_PROFILE_CLAUDE_BIN` at a stub claude
   that fakes `auth status --json` and credential-store writes. Cover:
   add-sub happy path, add-sub abandoned login, switch by name, rotate,
   switch with live-session guard, remove-sub (active and inactive), journal
   contents, usage windowing over synthetic transcripts, zero-subscription
   profiles unchanged.
3. **Spike (first task, macOS):** empirical report on credential storage
   location and MCP OAuth co-location with non-default `CLAUDE_CONFIG_DIR`.
4. **Manual E2E acceptance:** create profile → `--add-sub` twice with two
   real accounts → start a conversation → exit → `--switch` → `--resume`
   the same conversation → verify the remote MCP's own OAuth still works →
   `claude-profile-usage` shows both subscriptions with plausible splits.

## Risks and open items

- **Credential storage location on macOS with custom `CLAUDE_CONFIG_DIR`** —
  the one real unknown; quarantined behind the credential-store contract and
  resolved by the spike before any dependent code is written.
- **`oauthAccount` staleness in `.claude.json`** after a swap — spike
  verifies whether Claude self-heals it; if not, the switch flow patches it
  from slot `meta.json`.
- **Claude Code updates** may relocate credentials; `--doctor` reports the
  detected backend so breakage is diagnosable in one command.
- Usage cost split is approximate by design; token counts are exact.
