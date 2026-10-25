# shellcheck shell=bash
# Runs claude in a pty.sh pane and reads its hook log. Source pty.sh first.
#
# The caller sets these globals for the current run:
#   run       the pane target
#   dir       the run folder, which gets hooks.jsonl, summary.txt, and snapshots
#   settings  the settings file that claude_cmd passes to claude
#   model     the model for claude to use

claude_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In default permission mode, the prompt footer shows "manual mode on" instead
# of the shift+tab hint.
claude_ready_re='shift\+tab to cycle|manual mode on'
claude_proceed_title='Do you want to proceed'

# Dialogs that claude can open: a regex for the dialog's title, then a regex
# for the item to pick. The menu sits below the title.
# SB_EXIT_CHOICE picks what /exit does with background work that still runs:
# 1 exits and stops it, 2 moves the session to the background, 3 stays.
claude_dialogs=(
  'Accessing workspace' '^Yes, I trust this folder'
  "$claude_proceed_title" '^(1\. )?Yes'
  'Background work is running' "^${SB_EXIT_CHOICE:-1}\\. "
)

# Joins a multi-line value with ';', so summary.txt keeps one key=value per line.
record() {
  echo "$1=${2//$'\n'/;}" | tee -a "$dir/summary.txt"
}

snap() {
  pty_screen "$run" >"$dir/screen-$1.txt"
  pty_modes "$run" >>"$dir/screen-$1.txt"
  proc_tree "$(pty_shell_pid "$run")" >"$dir/tree-$1.txt" || true
}

# sh_quote <text>: the text in single quotes, for a command that sh runs.
sh_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The events that write_settings logs. A test can replace the list after it
# sources this file.
hook_events=(SessionStart SessionEnd Stop UserPromptSubmit PreToolUse PostToolUse
  SubagentStart SubagentStop Notification)

# write_settings [log]: prints hook settings that log every event in
# hook_events to <log>, or to $SB_HOOK_LOG when no log is given. A background
# session needs <log>, because its worker does not inherit SB_HOOK_LOG.
write_settings() {
  local c
  c=$(sh_quote "$claude_lib_dir/hook-log.sh")
  [ -z "${1:-}" ] || c="SB_HOOK_LOG=$(sh_quote "$1") $c"
  jq -n --arg c "$c" \
    '{hooks: ([$ARGS.positional[] | {(.): [{matcher: "", hooks: [{type: "command", command: $c, timeout: 5}]}]}] | add)}' \
    --args "${hook_events[@]}"
}

# hooks_of <event> [log files]: the logged payloads of one event, oldest first.
hooks_of() {
  local event=$1
  shift
  (($#)) || set -- "$dir/hooks.jsonl"
  jq -c --arg e "$event" 'select(.event == $e)' "$@" 2>/dev/null || true
}

hook_count() { hooks_of "$1" | wc -l | tr -d ' '; }

hook_count_above() { (($(hook_count "$1") > $2)); }

last_hook() { hooks_of "$1" | tail -1; }

transcript() { hooks_of SessionStart "$@" | jq -r .transcript_path | head -1; }

# Counts the SubagentStop events whose agent_id a SubagentStart announced.
# Claude Code also fires SubagentStop for its prompt-suggestion agent, which
# never fires SubagentStart.
subagent_stop_count() {
  hooks_of SubagentStop | jq -r .agent_id | grep -cFxf <(hooks_of SubagentStart | jq -r .agent_id) || true
}

# subagent_reported: the turn that the last subagent's result started has ended.
# While fork mode is on, which is the default, a subagent in an interactive
# session always runs in the background. Its result arrives as a prompt that
# starts a turn, so the next ask would otherwise take that turn's Stop. On
# 2.1.308 the prompt is a <task-notification> block with the agent_id as
# <task-id>. On 2.1.310 it is an <agent-message from="<agent_id>"> block.
subagent_reported() {
  local id t
  id=$(hooks_of SubagentStart | tail -1 | jq -r .agent_id)
  t=$(hooks_of UserPromptSubmit | jq -r --arg id "$id" \
    'select(.prompt | contains("<task-id>\($id)</task-id>") or contains("<agent-message from=\"\($id)\"")) | .t' | head -1)
  [ -n "$t" ] && (($(last_hook Stop | jq -r .t) > t))
}

claude_pid() { pty_child_pid "$run"; }

# answer_dialog: picks the listed item if a known dialog is on screen.
# Returns 0 only when it answered one. A dialog that claude drew outside the
# alternate screen stays on screen after claude exits, so this answers only
# while claude runs.
answer_dialog() {
  local screen i
  claude_pid >/dev/null || return 1
  screen=$(pty_screen "$run")
  for ((i = 0; i < ${#claude_dialogs[@]}; i += 2)); do
    if grep -Eq -- "${claude_dialogs[i]}" <<<"$screen"; then
      record dialog "${claude_dialogs[i]}: ${claude_dialogs[i + 1]}"
      pty_select "$run" "${claude_dialogs[i]}" "${claude_dialogs[i + 1]}" ||
        record dialog_unanswered "$(pty_menu_cursor "$run" "${claude_dialogs[i]}")"
      # Gives the dialog time to close, so the next poll doesn't answer it again.
      sleep 0.5
      return 0
    fi
  done
  return 1
}

# A poll that answers a dialog fails. The command then runs on the next poll,
# which wait_until times after the answer rather than before it.
answer_then() {
  answer_dialog && return 1
  "$@"
}

# claude_until <timeout seconds> <command...>: wait_until that answers dialogs.
claude_until() { wait_until "$1" 0.1 answer_then "${@:2}"; }

# accept_trust <folder>: starts claude in a new pane in the folder, accepts the
# workspace trust dialog, and stops claude. Claude Code stores trust for the
# repo's main checkout, so this covers every worktree of the repo.
accept_trust() {
  local pid
  pty_kill "$run"
  pty_new "$run" "$1"
  pty_type "$run" claude
  pty_key "$run" Enter
  if ! claude_until 60 screen_matches "$run" "$claude_ready_re" >/dev/null; then
    pty_kill "$run"
    return 1
  fi
  pid=$(claude_pid)
  kill -TERM "$pid"
  pty_wait_gone "$pid" 10 >/dev/null || true
  pty_kill "$run"
}

# slash_command <command>: pastes the command and submits it.
slash_command() {
  pty_paste "$run" "$1"
  sleep 0.3
  pty_key "$run" Enter
}

# claude_cmd <args...>: the command line typed into the pane.
claude_cmd() {
  echo "SB_HOOK_LOG=$dir/hooks.jsonl claude --model $model --settings $settings $*"
}

# start_claude <args...>: starts claude and prints the ms from Enter to its prompt.
start_claude() {
  pty_type "$run" "$(claude_cmd "$@")"
  pty_key "$run" Enter
  claude_until 60 screen_matches "$run" "$claude_ready_re"
}

send_prompt() {
  pty_type "$run" "$1"
  sleep 0.2
  pty_key "$run" Enter
}

# await_reply <label> <Stop count before the turn> <timeout seconds>: waits
# for a new Stop, answering dialogs, and records the reply as <label>_reply.
# Records <label>_timeout and returns 1 if no Stop comes in time.
await_reply() {
  if ! claude_until "$3" hook_count_above Stop "$2" >/dev/null; then
    record "$1_timeout" "no Stop within $3 s"
    return 1
  fi
  record "$1_reply" "$(last_hook Stop | jq -r .last_assistant_message)"
}

# ask <label> <text> <timeout seconds>: sends a prompt and runs await_reply.
ask() {
  local stops
  stops=$(hook_count Stop)
  send_prompt "$2"
  await_reply "$1" "$stops" "$3"
}

# check_transcript <label> <nonce>
check_transcript() {
  local path valid
  path=$(transcript)
  if jq -e . "$path" >/dev/null 2>&1; then valid=yes; else valid=no; fi
  record "$1_transcript_valid" "$valid"
  record "$1_transcript_lines" "$(wc -l <"$path" | tr -d ' ')"
  record "$1_transcript_last_type" "$(tail -1 "$path" | jq -r '.type + (if .subtype then "/" + .subtype else "" end)' 2>/dev/null || echo unparsable)"
  record "$1_transcript_nonce_replies" "$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$path" 2>/dev/null | grep -c -- "$2" || true)"
}

# stop_claude <method> <label>: stops claude with term (SIGTERM), hup (SIGHUP),
# or exit (pasted /exit), and records how it went. Returns 1 if claude is still
# running 10 s later.
stop_claude() {
  local method=$1 label=$2 pid ends exit_ms pids survivors
  if ! pid=$(claude_pid); then
    record "${label}_exit_ms" no-claude
    return 1
  fi
  ends=$(hook_count SessionEnd)
  snap "before-$label"
  case "$method" in
  term) kill -TERM "$pid" ;;
  hup) kill -HUP "$pid" ;;
  exit) slash_command /exit ;;
  *)
    echo "stop_claude: unknown method '$method' (use term, hup, or exit)" >&2
    return 2
    ;;
  esac
  if ! exit_ms=$(claude_until 10 pid_gone "$pid"); then
    record "${label}_exit_ms" timeout
    snap "stuck-$label"
    return 1
  fi
  record "${label}_exit_ms" "$exit_ms"
  sleep 1
  record "${label}_modes" "$(pty_modes "$run")"
  pids=$(awk -v shell="$(pty_shell_pid "$run")" -v claude="$pid" \
    '$1 != shell && $1 != claude {print $1}' "$dir/tree-before-$label.txt" | paste -sd ',' -)
  if [ -n "$pids" ]; then
    survivors=$(ps -o pid=,ppid=,command= -p "$pids" | cut -c1-120 || true)
  fi
  record "${label}_survivors" "${survivors:-none}"
  if hook_count_above SessionEnd "$ends"; then
    record "${label}_session_end" "$(last_hook SessionEnd | jq -r .reason)"
  else
    record "${label}_session_end" none
  fi
  snap "after-$label"
}

# shell_ok <label>: checks that the shell in the pane still runs commands, and
# records claude's exit status, which the shell still holds in $?.
shell_ok() {
  local token="SHELL-OK-$RANDOM"
  # shellcheck disable=SC2016 # The pane's shell expands $?, not this one.
  if pty_echo "$run" "$token" 'status=$?'; then
    record "$1_shell_ok" yes
    record "$1_exit_status" "$(pty_screen "$run" | grep -E "^$token" | tail -1 | sed 's/.*status=//')"
  else
    record "$1_shell_ok" no
    pty_screen "$run" >"$dir/screen-shell-$1.txt"
  fi
}

clear_pane() {
  pty_type "$run" clear
  pty_key "$run" Enter
  sleep 0.5
  ptmux clear-history -t "$run"
}

# resume_timed <label> <uuid> <regex>...: clears the pane, resumes the session,
# and records the ms from Enter until the prompt and every regex show.
# Returns 1 if they don't show within 60 s.
resume_timed() {
  local label=$1 uuid=$2 t0 ms starts ok=0
  shift 2
  clear_pane
  starts=$(hook_count SessionStart)
  pty_type "$run" "$(claude_cmd --resume "$uuid")"
  t0=$(now_ms)
  pty_key "$run" Enter
  ms=$(pty_wait "$run" 60 "$claude_ready_re" "$@") || ok=1
  record "${label}_redraw_ms" "$ms"
  if wait_until 5 0.2 hook_count_above SessionStart "$starts" >/dev/null; then
    record "${label}_session_start_ms" $(($(last_hook SessionStart | jq -r .t) - t0))
  fi
  snap "resumed-$label"
  return "$ok"
}

# stop_background_sessions <cwd>: stops the background sessions that run in
# the folder. /exit with SB_EXIT_CHOICE=2 forks the session into one.
stop_background_sessions() {
  local id
  for id in $(claude agents --json --cwd "$1" | jq -r --arg w "$1" '.[] | select(.cwd == $w) | .id' || true); do
    claude stop "$id" || true
  done
}

# kill_bg <text>: Claude Code runs each Bash command in a shell that leads its
# own process group. Only that shell's command line holds the command text, so
# this kills the whole group of each matching shell.
kill_bg() {
  local p
  for p in $(pgrep -f -- "$1"); do
    kill -TERM -- "-$(ps -o pgid= -p "$p" | tr -d ' ')" 2>/dev/null || true
  done
}
