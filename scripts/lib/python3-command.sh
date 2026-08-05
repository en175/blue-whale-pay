#!/usr/bin/env bash
# Select a real Python 3 launcher on macOS/Linux or Windows Git Bash.

select_python3_command() {
  PYTHON3_COMMAND=()
  python3_path="$(command -v python3 2>/dev/null || true)"
  if [ -n "$python3_path" ]; then
    case "$python3_path" in
      *WindowsApps*) ;;
      *) PYTHON3_COMMAND=(python3) ;;
    esac
  fi
  if [ "${#PYTHON3_COMMAND[@]}" -eq 0 ] && command -v py >/dev/null 2>&1; then
    PYTHON3_COMMAND=(py -3)
  fi
  [ "${#PYTHON3_COMMAND[@]}" -gt 0 ]
}
