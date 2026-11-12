# shellcheck shell=bash
# Defines check_prerequisites, which bin/install and bin/update run before they
# build or quit the app. It fails and lists the install command for each tool
# that Switchboard needs and can't find. It warns when claude is missing or gh
# is signed out, because sessions need both but the install doesn't.

check_prerequisites() {
  # sbd's findExecutable also searches these folders, so a tool there works
  # even when this shell's PATH lacks them, as on a new Mac before Homebrew's
  # shellenv runs. SB_TOOL_FOLDERS lets a test replace them.
  local PATH="$PATH:${SB_TOOL_FOLDERS:-$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin}"
  local missing=()
  command -v tmux >/dev/null || missing+=("tmux: run brew install tmux")
  command -v gh >/dev/null || missing+=("gh: run brew install gh")
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Switchboard needs:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
  command -v claude >/dev/null || echo "Warning: claude is not on PATH. Switchboard's sessions run it." >&2
  gh auth status >/dev/null 2>&1 ||
    echo "Warning: gh is not signed in. Run gh auth login so Switchboard can follow pull requests." >&2
}
