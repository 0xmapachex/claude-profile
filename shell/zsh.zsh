# claude-profile shell integration

claude-profile-yolo() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: claude-profile-yolo <profile> [claude args...]" >&2
    return 2
  fi

  local profile="$1"
  shift
  claude-profile "$profile" --dangerously-skip-permissions "$@"
}

claude-personal() {
  claude-profile personal "$@"
}

claude-work() {
  claude-profile work "$@"
}

if (( $+functions[command_not_found_handler] )) && (( ! $+functions[_claude_profile_previous_command_not_found_handler] )); then
  functions -c command_not_found_handler _claude_profile_previous_command_not_found_handler
fi

command_not_found_handler() {
  local command_name="$1"

  if [[ "$command_name" == claude-* ]]; then
    local profile="${command_name#claude-}"

    case "$profile" in
      ""|profile|usage|yolo)
        return 127
        ;;
    esac

    shift

    if [[ "$profile" == *-yolo ]]; then
      profile="${profile%-yolo}"

      if [[ -z "$profile" ]]; then
        return 127
      fi

      claude-profile-yolo "$profile" "$@"
      return $?
    fi

    claude-profile "$profile" "$@"
    return $?
  fi

  if (( $+functions[_claude_profile_previous_command_not_found_handler] )); then
    _claude_profile_previous_command_not_found_handler "$@"
    return $?
  fi

  return 127
}
