#!/usr/bin/env bash
set -euo pipefail

install_root="${CLAUDE_PROFILE_INSTALL_ROOT:-$HOME/.local/share/claude-profile}"
bin_dir="${CLAUDE_PROFILE_BIN_DIR:-$HOME/.local/bin}"
shell_file="${CLAUDE_PROFILE_SHELL_FILE:-$HOME/.zshrc}"
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

begin_marker="# >>> claude-profile >>>"
end_marker="# <<< claude-profile <<<"

mkdir -p "$install_root" "$bin_dir"

copy_item() {
  local src="$1"
  local dst="$2"

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    tar -C "$src" -cf - . | tar -C "$dst" -xf -
  elif [[ -f "$src" ]]; then
    cp "$src" "$dst"
  fi
}

copy_item "$source_dir/bin" "$install_root/bin"
copy_item "$source_dir/shell" "$install_root/shell"
copy_item "$source_dir/README.md" "$install_root/README.md"
copy_item "$source_dir/LICENSE" "$install_root/LICENSE"
copy_item "$source_dir/package.json" "$install_root/package.json"

chmod 755 "$install_root/bin/claude-profile" "$install_root/bin/claude-profile-usage"
ln -sfn "$install_root/bin/claude-profile" "$bin_dir/claude-profile"
ln -sfn "$install_root/bin/claude-profile-usage" "$bin_dir/claude-profile-usage"
ln -sfn "$install_root/bin/claude-profile-usage" "$bin_dir/claude-usage"

touch "$shell_file"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/claude-profile-zshrc.XXXXXX")"
awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { skip = 1; next }
  $0 == end { skip = 0; next }
  skip != 1 { print }
' "$shell_file" > "$tmp_file"

{
  cat "$tmp_file"
  printf '\n%s\n' "$begin_marker"
  printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  printf 'source "$HOME/.local/share/claude-profile/shell/zsh.zsh"\n'
  printf '%s\n' "$end_marker"
} > "$shell_file"

rm -f "$tmp_file"

printf 'Installed claude-profile to %s\n' "$install_root"
printf 'Installed commands in %s\n' "$bin_dir"
printf 'Updated shell integration in %s\n' "$shell_file"
printf 'Restart your shell or run: source %s\n' "$shell_file"
