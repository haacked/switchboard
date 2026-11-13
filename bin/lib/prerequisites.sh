# shellcheck shell=bash
# Defines check_prerequisites, which bin/install and bin/update run before they
# build or quit the app. It fails and lists the install command for each tool
# that Switchboard needs and can't find. It warns when claude is missing or gh
# is signed out, because sessions need both but the install doesn't.

# Prints the config.json setting at key path $1, or $2 when config.json doesn't
# set it. sbd reads the same keys and expands a leading ~ the same way.
switchboard_setting() {
  local config="${SB_HOME:-$HOME/.sb}/config.json" value
  value=$([ -f "$config" ] && plutil -extract "$1" raw -o - "$config" 2>/dev/null) || value=$2
  echo "${value/#\~/$HOME}"
}

check_prerequisites() {
  # bin/update runs the check, then runs bin/install, which would run it again.
  [ -z "${SB_PREREQUISITES_CHECKED:-}" ] || return 0
  # The check searches only where sbd searches: launchd's PATH, which holds
  # only the system folders, plus the folders that findExecutable adds.
  # SB_TOOL_FOLDERS lets a test replace the added folders.
  local PATH="${SB_TOOL_FOLDERS:-$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin}:/usr/bin:/bin:/usr/sbin:/sbin"
  local missing=() tmux gh claude
  tmux=$(switchboard_setting tmux tmux)
  gh=$(switchboard_setting github.gh gh)
  claude=$(switchboard_setting claude claude)
  command -v "$tmux" >/dev/null || missing+=("$tmux: run brew install tmux, or set \"tmux\" in config.json")
  command -v "$gh" >/dev/null || missing+=("$gh: run brew install gh, or set \"github.gh\" in config.json")
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Switchboard needs:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    return 1
  fi
  command -v "$claude" >/dev/null || echo "Warning: can't find $claude. Switchboard's sessions run it." >&2
  "$gh" auth status >/dev/null 2>&1 ||
    echo "Warning: gh is not signed in. Run gh auth login so Switchboard can follow pull requests." >&2
  export SB_PREREQUISITES_CHECKED=1
}
