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
copy_item "$source_dir/README.md" "$install_root/README.md"
copy_item "$source_dir/LICENSE" "$install_root/LICENSE"
copy_item "$source_dir/package.json" "$install_root/package.json"

chmod 755 "$install_root/bin/claude-profile" "$install_root/bin/claude-profile-usage"
ln -sfn "$install_root/bin/claude-profile" "$bin_dir/claude-profile"
ln -sfn "$install_root/bin/claude-profile-usage" "$bin_dir/claude-profile-usage"
ln -sfn "$install_root/bin/claude-profile-usage" "$bin_dir/claude-usage"

printf 'Installed claude-profile to %s\n' "$install_root"
printf 'Installed commands in %s\n' "$bin_dir"
