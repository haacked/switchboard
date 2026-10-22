# shellcheck shell=bash
# Drives terminal sessions in a private tmux server for the Phase 0 tests.
# Source this file from a test script.

PTY_SOCKET="${PTY_SOCKET:-sb-phase0}"
PTY_COLS="${PTY_COLS:-200}"
PTY_ROWS="${PTY_ROWS:-50}"

ptmux() { tmux -L "$PTY_SOCKET" "$@"; }

# EPOCHREALTIME has six decimal places, so dropping the separator gives microseconds.
now_ms() { echo $((${EPOCHREALTIME//[.,]/} / 1000)); }

# wait_until <timeout seconds> <interval seconds> <command...>
# Runs the command every interval until it succeeds. Prints the ms from the
# start to the poll that succeeded, timed before the command ran, and returns 0.
# Prints "timeout" and returns 1 otherwise. The command's output goes to stderr.
wait_until() {
  local timeout_ms=$(($1 * 1000)) interval=$2 start t
  shift 2
  start=$(now_ms)
  while :; do
    t=$(now_ms)
    if "$@" >&2; then
      echo $((t - start))
      return 0
    fi
    ((t - start < timeout_ms)) || break
    sleep "$interval"
  done
  echo timeout
  return 1
}

# clean_env <command...>: runs the command in an empty environment. A test
# claude must not inherit this shell's SUPACODE_* variables, because the
# Supacode resume hook would then overwrite the record of the user's own pane.
# It must not inherit CLAUDE* variables either, because they mark a child of
# another Claude session.
clean_env() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$PATH" \
    SHELL=/bin/zsh TERM=xterm-256color LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" "$@"
}

pty_server_start() {
  ptmux has-session 2>/dev/null && return 0
  clean_env tmux -L "$PTY_SOCKET" -f /dev/null new-session -d -s base -x "$PTY_COLS" -y "$PTY_ROWS"
  # These let claude turn on focus reporting and extended keys, as it would in
  # Ghostty. A killed claude can then leave them on in the pane.
  ptmux set -g focus-events on
  ptmux set -s extended-keys on
}

pty_server_stop() { ptmux kill-server 2>/dev/null || true; }

# pty_new <name> <cwd>: starts a zsh pane and waits until zsh runs commands.
# The pane target is the name.
pty_new() {
  ptmux new-session -d -s "$1" -x "$PTY_COLS" -y "$PTY_ROWS" -c "$2" /bin/zsh -l
  pty_echo "$1" "SHELL-READY-$RANDOM"
  # zsh sets the keypad modes when its line editor draws the next prompt.
  sleep 0.5
}

# pty_echo <target> <token> [args]: runs `echo <token> <args>` in the pane's
# shell and waits up to 30 s for a line that starts with the token.
pty_echo() {
  local target=$1 token=$2
  shift 2
  pty_type "$target" "echo $token $*"
  pty_key "$target" Enter
  pty_wait "$target" 30 "^$token" >/dev/null
}

pty_kill() { ptmux kill-session -t "$1" 2>/dev/null || true; }

pty_type() { ptmux send-keys -t "$1" -l -- "$2"; }

pty_key() { ptmux send-keys -t "$1" "$2"; }

# pty_paste <target> <text>: pastes with bracketed paste, as the service would.
pty_paste() {
  ptmux set-buffer -b sbpaste -- "$2"
  ptmux paste-buffer -p -d -b sbpaste -t "$1"
}

# The visible screen only, with wrapped lines joined.
pty_screen() { ptmux capture-pane -p -J -t "$1"; }

# screen_matches <target> <extended regex>...: every regex matches some line.
screen_matches() {
  local screen re
  screen=$(pty_screen "$1")
  shift
  for re in "$@"; do
    grep -Eq -- "$re" <<<"$screen" || return 1
  done
}

# pty_wait <target> <timeout seconds> <extended regex>...
# Polls the visible screen every 100 ms until every regex matches some line.
pty_wait() { wait_until "$2" 0.1 screen_matches "$1" "${@:3}"; }

# pty_menu_cursor <target> <title regex>: the highlighted item of the menu below
# the title, without its marker. Claude Code also marks each past prompt with
# ❯, so the search starts at the title.
pty_menu_cursor() {
  pty_screen "$1" | awk -v t="$2" '$0 ~ t {f = 1} f && /^ *❯ / {sub(/^ *❯ /, ""); sub(/ +$/, ""); print; exit}'
}

# pty_select <target> <title regex> <item regex>: moves down the menu below the
# title until the highlighted item matches, then picks it. Claude Code menus
# don't always number their items or keep their order, so this matches the
# item's text. Returns 1 if no item matches after 10 moves.
pty_select() {
  local i
  for ((i = 0; i < 10; i++)); do
    if grep -Eq -- "$3" <<<"$(pty_menu_cursor "$1" "$2")"; then
      pty_key "$1" Enter
      return 0
    fi
    pty_key "$1" Down
    sleep 0.2
  done
  return 1
}

# Terminal modes that a killed program can leave on in the pane.
pty_modes() {
  ptmux display -p -t "$1" \
    'alternate=#{alternate_on} cursor=#{cursor_flag} keypad=#{keypad_flag} keypad_cursor=#{keypad_cursor_flag} mouse=#{mouse_any_flag} keys=#{pane_key_mode}'
}

pty_shell_pid() { ptmux display -p -t "$1" '#{pane_pid}'; }

# The newest process that the pane's shell started.
pty_child_pid() { pgrep -n -P "$(pty_shell_pid "$1")"; }

pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# pty_wait_gone <pid> <timeout seconds>: prints elapsed ms or "timeout".
pty_wait_gone() { wait_until "$2" 0.05 pid_gone "$1"; }

# Every process below <pid>, one per line: pid ppid pgid rss command.
proc_tree() {
  local pid=$1 child
  ps -o pid=,ppid=,pgid=,rss=,command= -p "$pid" 2>/dev/null
  for child in $(pgrep -P "$pid"); do
    proc_tree "$child"
  done
}
