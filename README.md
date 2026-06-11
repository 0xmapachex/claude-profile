# claude-profile

Use multiple Claude Code accounts locally without mixing credentials, sessions,
history, or configuration clutter.

`claude-profile` starts Claude Code with a dedicated `CLAUDE_CONFIG_DIR` per
profile. Use one profile for work, another for personal, and as many named
profiles as you need.

## Install

```sh
npm install -g @0xmapache/claude-profile
```

This installs:

- `claude-profile`
- `claude-profile-usage`

## Quick Start

Create and open a profile:

```sh
claude-profile personal
```

Inside Claude Code, log in with the account for that profile:

```text
/login
```

Open the same profile later:

```sh
claude-profile personal
```

After the first launch, a shortcut named `claude-<profile>` is created in
`~/.local/bin`, so you can also reopen it with:

```sh
claude-personal
```

Create another profile:

```sh
claude-profile work
```

Inside that session, run `/login` with your other Claude account.

List profiles:

```sh
claude-profile --list
```

Remove a profile:

```sh
claude-profile --remove work
```

Removal is non-destructive. The profile is moved to:

```sh
~/.claude-profiles/.trash/<profile>-<timestamp>
```

Review local usage across logged-in profiles:

```sh
claude-profile-usage
```

## Permissions

Profile launches use Claude Code's dangerous permissions bypass by default:

```sh
claude-profile work
```

This keeps the profile command simple and matches the common local agent workflow.

## Profile Storage and Shared Config

Profiles live under:

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

On first launch, the profile is bootstrapped from your main `~/.claude` config:

- `settings.json` is copied once.
- `skills`, `agents`, `commands`, `output-styles`, and `CLAUDE.md` are symlinked
  if they exist.

This means shared skills update everywhere, while account-specific state stays
separate.

If you later change your main `~/.claude/settings.json`, sync a profile:

```sh
claude-profile --sync-settings work
```

## Safety

Before starting Claude, `claude-profile` removes auth/provider environment
variables such as `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and
`CLAUDE_CODE_OAUTH_TOKEN`. A profile should use its own `/login` session, not an
API key or token inherited from your shell.

Copied `settings.json` files are sanitized by removing top-level `env` and
`apiKeyHelper` keys.

## Usage Reports

```sh
claude-profile-usage
claude-profile-usage weekly
claude-profile-usage monthly
claude-profile-usage daily --since 2026-06-01
```

`claude-profile-usage` checks which profiles are logged in with
`claude auth status --json`, then summarizes local Claude Code usage logs with
`ccusage`.

This reports local token and estimated-cost history. It does not read OAuth
tokens or call undocumented live quota endpoints.

## Terminal Titles

Interactive launches are labeled with the profile name:

- terminal title: `claude:<profile>`
- Claude session name: `<profile>`

Customize or disable this behavior:

```sh
CLAUDE_PROFILE_TITLE_PREFIX="cc:" claude-profile work
CLAUDE_PROFILE_SET_TERMINAL_TITLE=0 claude-profile work
CLAUDE_PROFILE_SET_CLAUDE_NAME=0 claude-profile work
```

## Profile Colors

Each profile is assigned a random session color the first time it is
initialized, avoiding colors already used by other profiles. On a bare launch
(no extra claude arguments), the wrapper applies it by running claude's
`/color` command at startup, so the session name badge inside Claude Code is
visually distinct per account.

Color injection is skipped when you pass any arguments: they may carry a
prompt of their own, and resumed sessions (`-r`, `-c`) restore their previous
color automatically. It is also skipped when the installed claude version
does not support `/color`, so launches degrade gracefully (no color,
everything else works).

The color is stored in `~/.claude-profiles/<profile>/profile-color`. Pick one
by hand by writing any of the supported values into that file:

```text
red blue green yellow purple orange pink cyan
```

Disable color injection with:

```sh
CLAUDE_PROFILE_SET_CLAUDE_COLOR=0 claude-profile work
```

## Launch Shortcuts

Each profile launch also creates `~/.local/bin/claude-<profile>`, so the
second time around you can start a profile directly:

```sh
claude-work
claude-personal
```

Shortcuts are small generated scripts; removing a profile removes its
shortcut, and existing commands not created by claude-profile are never
overwritten. Customize or disable:

```sh
CLAUDE_PROFILE_SHORTCUT_DIR="$HOME/bin" claude-profile work
CLAUDE_PROFILE_SHORTCUTS=0 claude-profile work
```
