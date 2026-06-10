# claude-profile

Run Claude Code with isolated local account profiles.

Claude Code supports `CLAUDE_CONFIG_DIR`, which moves settings, credentials,
session history, plugins, and other user state under a custom directory. This
launcher uses that official mechanism to run multiple Claude accounts side by
side without copying credentials between them.

## Install

From a cloned repo:

```sh
git clone https://github.com/0xmapachex/claude-profile.git
cd claude-profile
./install.sh
```

Or with npm:

```sh
npm install -g @0xmapache/claude-profile
```

The installer copies the package to `~/.local/share/claude-profile`, symlinks
`claude-profile` and `claude-usage` into `~/.local/bin`, and adds a marked zsh
integration block to `~/.zshrc`.

## Usage

```sh
claude-profile personal-one
claude-profile work -- --version
claude-profile-yolo work
claude-personal
claude-work
claude-any-profile-name
claude-profile-usage
```

The `claude-*` form is provided by zsh's `command_not_found_handler`; the text
after `claude-` is treated as the profile name.

## Profile Storage

Profiles are created under:

```sh
~/.claude-profiles/<profile>
```

Each profile has isolated:

- credentials
- sessions
- history
- cache
- telemetry
- project state

The first time you start a profile, run `/login` inside Claude Code. After that,
Claude should remain logged into that profile because the profile keeps its own
`CLAUDE_CONFIG_DIR` and credential namespace.

By default, the launcher also labels the terminal session with the profile:

- It sets the terminal title to `claude:<profile>` when stdout is a TTY.
- It passes `--name <profile>` to Claude for normal interactive launches, which
  Claude uses for the session display and terminal title.
- It does not override explicit `--name` / `-n`, and it does not inject a name
  for `--version`, `--help`, `--print`, or Claude management subcommands.

Disable either behavior if needed:

```sh
CLAUDE_PROFILE_SET_TERMINAL_TITLE=0 claude-profile work
CLAUDE_PROFILE_SET_CLAUDE_NAME=0 claude-profile work
CLAUDE_PROFILE_TITLE_PREFIX="cc:" claude-profile work
```

## Shared Configuration

On first initialization, the launcher bootstraps from `~/.claude`:

- `settings.json` is copied once.
- `skills`, `agents`, `commands`, `output-styles`, and `CLAUDE.md` are symlinked
  if they exist.

`settings.json` is sanitized during the copy. The launcher removes top-level
`env` and `apiKeyHelper` keys so profile login cannot be silently overridden by
API-key or helper-based auth configured in settings.

To customize linked items:

```sh
export CLAUDE_PROFILE_SHARED_ITEMS="skills agents commands output-styles CLAUDE.md plugins"
```

`plugins` is not linked by default because plugin installs include executable
code and mutable cache/data. Link it only if that is the security model you want.

## Auth Safety

Before starting Claude, the launcher unsets auth/provider environment variables:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `CLAUDE_CODE_OAUTH_TOKEN`
- `CLAUDE_CODE_USE_BEDROCK`
- `CLAUDE_CODE_USE_VERTEX`
- `CLAUDE_CODE_USE_FOUNDRY`
- `CLAUDE_CODE_USE_ANTHROPIC_AWS`
- `CLAUDE_CODE_USE_MANTLE`
- `ANTHROPIC_BASE_URL`

This is intentional. The profile should use its own `/login` subscription OAuth,
not fall back to an API key or a provider token from the parent shell.

## Commands

```sh
claude-profile --init personal-one
claude-profile --path personal-one
claude-profile --sync-settings personal-one
claude-profile --remove personal-one
claude-profile --trash-list
claude-profile --list
claude-profile --doctor
```

Use `--sync-settings` after changing `~/.claude/settings.json` when you want a
profile to pick up the latest sanitized settings copy. It does not sync auth,
history, sessions, cache, telemetry, or project state.

`--remove` is intentionally non-destructive. It moves the profile directory to
`~/.claude-profiles/.trash/<profile>-<timestamp>` instead of deleting it.

## Usage Reports

```sh
claude-profile-usage
claude-profile-usage weekly
claude-profile-usage monthly
claude-profile-usage daily --since 2026-06-01
```

`claude-profile-usage`:

- Lists profiles under `~/.claude-profiles`.
- Keeps only profiles where `claude auth status --json` reports `loggedIn=true`.
- Runs `ccusage claude <period> --json --offline` per logged-in profile.
- Prints a table with local token and estimated-cost totals.

This is local usage history, not live subscription quota. Claude Code has an
interactive `/usage` command and uses an OAuth usage endpoint internally, but
that endpoint is not a stable public API and is currently reported by many users
as aggressively rate-limited. This package does not extract Keychain secrets,
print OAuth tokens, or call undocumented usage endpoints.

## Installation Shape

This is not a Claude skill. A skill runs inside Claude after startup, but account
selection must happen before Claude starts. The right public shape is a small
shell CLI plus install script, distributed as a GitHub repo.
