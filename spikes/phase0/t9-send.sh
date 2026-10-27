#!/usr/bin/env bash
# Phase 0 test 9: sending a message.
#
# Usage: t9-send.sh <command> [args]
#   setup                 creates the work repo with a bare remote and the slow
#                         task, starts the tmux server, and accepts workspace
#                         trust for the repo
#   idle paste|socket     sends a two-line message to an idle session
#   busy paste|socket     sends a message while a turn runs a 15 s command
#   resume                stops an idle session and resumes it with a two-line
#                         message as the first prompt
#   slash paste|socket    sends /compact to an idle session
#   push paste|socket     asks an idle session to commit a file and push it.
#                         A permission dialog is refused, not approved
#   draft paste|socket    sends a message while the input box holds unsent text
#   explicit              starts claude with --messaging-socket-path and sends
#                         a message to that socket
#   screen|hooks <run>    shows a run's pane or hook log
#   teardown              stops the tmux server
#
# paste sends the text as sbd does: a bracketed paste, 300 ms, then Enter.
# socket writes one JSON line to the session's inbox socket with
# lib/inbox-send.py, with no auth line. Sessions run with no MCP servers.
# T9_MODE, when set, passes --permission-mode. Otherwise the account's default
# mode applies, and summary.txt records it.
# T9_ROOT holds the work repo, its remote, the slow task, and one folder per run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T9_ROOT="${T9_ROOT:?set T9_ROOT to a scratch folder}"
work="$T9_ROOT/work"
remote="$T9_ROOT/remote.git"
runs="$T9_ROOT/runs"
bin="$T9_ROOT/bin"
model="${T9_MODEL:-haiku}"
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hook_events=(SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse
  PostToolUseFailure Notification Stop StopFailure SessionEnd PreCompact PostCompact)
claude_base_args="--strict-mcp-config --mcp-config $(sh_quote '{"mcpServers":{}}')${T9_MODE:+ --permission-mode $T9_MODE}"

git_quiet() { git -C "$work" "$@" >/dev/null; }

cmd_setup() {
  mkdir -p "$work" "$runs" "$bin"
  [ -d "$remote" ] || git init -q --bare -b main "$remote"
  if [ ! -d "$work/.git" ]; then
    git init -q -b main "$work"
    # The session's commits must not need the user's signing agent.
    git_quiet config user.name t9
    git_quiet config user.email t9@example.com
    git_quiet config commit.gpgsign false
    echo "# t9" >"$work/README.md"
    git_quiet add README.md
    git_quiet commit -m "First commit"
    git_quiet remote add origin "$remote"
    git_quiet push -u origin main
  fi
  cat >"$bin/slow-task.sh" <<'EOF'
#!/bin/sh
# Prints a numbered line every second for $1 seconds.
i=1
while [ "$i" -le "${1:-15}" ]; do
  echo "slow-task line $i"
  sleep 1
  i=$((i + 1))
done
EOF
  chmod +x "$bin/slow-task.sh"
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$work"
  echo "root: $T9_ROOT"
}

# new_run <kind>: sets run, dir, settings, and uuid, and opens a pane in the
# work repo. The EXIT trap closes the pane, which stops a claude still running
# in it.
new_run() {
  pty_server_start
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  settings="$dir/settings.json"
  uuid=$(uuidgen | tr 'A-Z' 'a-z')
  mkdir -p "$dir"
  trap 'pty_kill "$run"' EXIT
  write_settings | jq --arg slow "Bash($bin/slow-task.sh:*)" '.permissions = {allow: [$slow]}' >"$settings"
  record claude_version "$(claude --version)"
  record session "$uuid"
  pty_new "$run" "$work"
}

# read_sock: sets sock to the running claude's inbox socket from its pid file.
# The default path names the pid, so each claude process has its own.
read_sock() {
  sock=$(jq -r '.messagingSocketPath // empty' "$config_dir/sessions/$(claude_pid).json" 2>/dev/null || true)
}

# start [claude args]: starts claude, then sends a first prompt and waits for
# its reply, so the session sits idle in a conversation as sbd's sessions do.
# It records the inbox socket from the pid file and from the hook environment.
start() {
  local prompt_hook
  record start_ms "$(start_claude --session-id "$uuid" "$claude_base_args" "$@")"
  if ! ask first "Reply with only the word READY." 60; then
    snap no-start
    return 1
  fi
  prompt_hook=$(last_hook UserPromptSubmit)
  record permission_mode "$(jq -r '.permission_mode // "none"' <<<"$prompt_hook")"
  read_sock
  record pid_file_socket "${sock:-none}"
  record hook_env_socket "$(jq -r '.sb_env.CLAUDE_CODE_MESSAGING_SOCKET // "none"' <<<"$prompt_hook")"
  record socket_exists "$([ -n "$sock" ] && [ -S "$sock" ] && echo yes || echo no)"
  # A person's message comes some seconds after the reply.
  sleep 2
}

# send <paste|socket> <text>: sends the text and sets sent_t0 to the ms before
# the Enter or the connect.
send() {
  local out
  case $1 in
  paste)
    pty_paste "$run" "$2"
    sleep 0.3
    sent_t0=$(now_ms)
    pty_key "$run" Enter
    ;;
  socket)
    if ! out=$(python3 -I "$here/lib/inbox-send.py" "$sock" "$2"); then
      record send_error "$out"
      return 1
    fi
    record send_result "$out"
    # The script's clock starts after Python's startup, which takes up to
    # 0.7 s here.
    sent_t0=$(jq .t <<<"$out")
    ;;
  esac
}

check_path() {
  case $1 in
  paste | socket) ;;
  *)
    echo "unknown path '$1' (use paste or socket)" >&2
    exit 2
    ;;
  esac
}

# hooks_after <event> <ms>: the event's payloads logged after the time.
hooks_after() { hooks_of "$1" | jq -c --argjson t0 "$2" 'select(.t >= $t0)'; }

# prompts_after <ms>: the UserPromptSubmit prompts after the time, with each
# prompt's ms from the time, one JSON line each.
prompts_after() { hooks_after UserPromptSubmit "$1" | jq -c --argjson t0 "$1" '{ms: (.t - $t0), prompt}'; }

# tools_after <ms>: the tool calls that started after the time, with each
# call's ms from the time.
tools_after() {
  hooks_after PreToolUse "$1" | jq -r --argjson t0 "$1" \
    '"\(.t - $t0) ms \(.tool_name) \(.tool_input.command // .tool_input.file_path // "" | .[0:100])"'
}

# delivered <text>: records how the message sent at sent_t0 arrived. The first
# prompt after the send is saved whole in prompt.txt.
delivered() {
  local prompts first got
  prompts=$(prompts_after "$sent_t0")
  if [ -z "$prompts" ]; then
    record prompt none
    return 0
  fi
  first=$(head -1 <<<"$prompts")
  got=$(jq -r .prompt <<<"$first")
  printf '%s' "$got" >"$dir/prompt.txt"
  record to_prompt_ms "$(jq -r .ms <<<"$first")"
  record prompt_matches "$([ "$got" = "$1" ] && echo yes || echo no)"
  record prompt_head "${got:0:300}"
  record prompts_after_send "$(wc -l <<<"$prompts" | tr -d ' ')"
}

# replied: records the ms from sent_t0 to the last Stop and the tool calls
# after the send. await_reply records the reply itself.
replied() {
  record sent_to_stop_ms $(($(last_hook Stop | jq -r .t) - sent_t0))
  record sent_tools "$(tools_after "$sent_t0")"
}

# await_sent <text> <Stop count before the send>: waits for the reply to the
# message sent at sent_t0 and records how it arrived. Returns 1 if no reply
# comes within 60 s.
await_sent() {
  if ! await_reply sent "$2" 60; then
    delivered "$1"
    snap no-reply
    return 1
  fi
  delivered "$1"
  replied
  snap replied
}

# finish: stops claude and records whether the socket file outlived it.
finish() {
  stop_claude term end || true
  [ -z "${sock:-}" ] || record socket_after_exit "$([ -e "$sock" ] && echo exists || echo gone)"
}

two_line_text() {
  printf 'First line: reply with the word ALPHA-%s.\nSecond line: then, on a new line, the word BETA-%s.' "$1" "$1"
}

# both_words <nonce>: records how many lines of the last reply have one of the
# two words that two_line_text asks for.
both_words() {
  record both_words "$(last_hook Stop | jq -r .last_assistant_message | grep -c -e "ALPHA-$1" -e "BETA-$1" || true)"
}

cmd_idle() {
  local how=$1 nonce="T9I$RANDOM" text stops
  check_path "$how"
  new_run "idle-$how"
  start
  text=$(two_line_text "$nonce")
  stops=$(hook_count Stop)
  send "$how" "$text"
  if ! await_sent "$text" "$stops"; then
    finish
    return 1
  fi
  both_words "$nonce"
  finish
}

# slow_task_ts <event>: the times of the event's payloads for the slow task's
# Bash call.
slow_task_ts() {
  hooks_of "$1" | jq -r 'select(.tool_name == "Bash" and (.tool_input.command | contains("slow-task"))) | .t'
}

slow_running() { [ -n "$(slow_task_ts PreToolUse)" ]; }

# slow_turn_done: a Stop after the slow task's PostToolUse has arrived.
slow_turn_done() {
  local post
  post=$(slow_task_ts PostToolUse | tail -1)
  [ -n "$post" ] && [ -n "$(hooks_after Stop "$post")" ]
}

cmd_busy() {
  local how=$1 nonce="T9B$RANDOM" text stops slow_pre slow_post write_t first_stop
  check_path "$how"
  new_run "busy-$how"
  start
  send_prompt "Run \`$bin/slow-task.sh 15\` with the Bash tool in the foreground and wait for it to finish. Then reply with the last line it printed."
  if ! claude_until 60 slow_running >/dev/null; then
    record slow_task none
    snap no-slow-task
    finish
    return 1
  fi
  sleep 3
  text="Also create a file named busy-$nonce.txt in this folder that contains only the word DONE."
  send "$how" "$text"
  snap sent-while-busy
  if ! claude_until 90 slow_turn_done >/dev/null; then
    record slow_turn timeout
    snap no-slow-stop
    finish
    return 1
  fi
  # A message that waits for the next turn starts one within a few seconds.
  stops=$(hook_count Stop)
  [ -e "$work/busy-$nonce.txt" ] || claude_until 30 hook_count_above Stop "$stops" >/dev/null || true
  slow_pre=$(slow_task_ts PreToolUse | head -1)
  slow_post=$(slow_task_ts PostToolUse | tail -1)
  # jq -s reads every line. head -1 could close the pipe early, and pipefail
  # would end the run.
  first_stop=$(hooks_after Stop "$slow_post" | jq -rs '.[0].t')
  record sent_after_slow_start_ms $((sent_t0 - slow_pre))
  record slow_post_after_send_ms $((slow_post - sent_t0))
  record first_stop_after_send_ms $((first_stop - sent_t0))
  delivered "$text"
  record prompts "$(prompts_after "$sent_t0" | jq -c '{ms, prompt: (.prompt | .[0:160])}')"
  record stops_after_send "$(hooks_after Stop "$sent_t0" | jq -c --argjson t0 "$sent_t0" '{ms: (.t - $t0), reply: (.last_assistant_message | .[0:160])}')"
  record tools "$(tools_after "$sent_t0")"
  write_t=$(hooks_after PreToolUse "$sent_t0" | jq -r --arg n "busy-$nonce" 'select((.tool_input.file_path // .tool_input.command // "") | contains($n)) | .t' | head -1)
  if [ -n "$write_t" ]; then
    record file_call_after_send_ms $((write_t - sent_t0))
    record file_call_before_first_stop "$([ "$write_t" -lt "$first_stop" ] && echo yes || echo no)"
  else
    record file_call none
  fi
  record file "$(cat "$work/busy-$nonce.txt" 2>/dev/null || echo none)"
  rm -f "$work/busy-$nonce.txt"
  snap after
  finish
}

cmd_resume() {
  local nonce="T9R$RANDOM" text stops
  new_run resume
  start
  stop_claude term stop1 || return 1
  record stop1_socket_after_exit "$([ -e "$sock" ] && echo exists || echo gone)"
  clear_pane
  text=$(two_line_text "$nonce")
  # The prompt has a newline. The pane sources the command from a file, as
  # sbd's claude.sh does.
  echo "$(claude_cmd --resume "$uuid" "$claude_base_args") -- $(sh_quote "$text")" >"$dir/resume.sh"
  stops=$(hook_count Stop)
  pty_type "$run" "source $(sh_quote "$dir/resume.sh")"
  sent_t0=$(now_ms)
  pty_key "$run" Enter
  if ! await_sent "$text" "$stops"; then
    finish
    return 1
  fi
  both_words "$nonce"
  # finish checks the resumed claude's socket.
  read_sock
  finish
}

# reply_after <Stop count before the send>: records the reply and the times,
# if a turn ended after the send. For runs that don't use await_reply.
reply_after() {
  hook_count_above Stop "$1" || return 0
  record sent_reply "$(last_hook Stop | jq -r .last_assistant_message)"
  replied
}

compacted_or_stopped() { hook_count_above PostCompact 0 || hook_count_above Stop "$1"; }

cmd_slash() {
  local how=$1 stops
  check_path "$how"
  new_run "slash-$how"
  start
  stops=$(hook_count Stop)
  send "$how" "/compact"
  claude_until 120 compacted_or_stopped "$stops" >/dev/null || record outcome timeout
  sleep 2
  record pre_compact "$(hook_count PreCompact)"
  record post_compact "$(hook_count PostCompact)"
  delivered "/compact"
  reply_after "$stops"
  snap after
  finish
}

# has_commit <repo> <subject>: some branch of the repo has a commit with the
# subject. It doesn't pipe git into grep -q, which can exit before git writes
# everything and fail the pipeline under pipefail.
has_commit() { [ -n "$(git -C "$1" log --all --fixed-strings --grep="$2" --format=%h 2>/dev/null)" ]; }

# reset_repos: leaves the work repo on origin's main with no other branches,
# and the remote with only main. A session may commit on a new branch and push
# it. A push to main stays in both repos.
reset_repos() {
  local repo b
  git_quiet checkout -q -f main
  git_quiet reset -q --hard origin/main
  for repo in "$work" "$remote"; do
    for b in $(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main || true); do
      git -C "$repo" branch -q -D "$b"
    done
  done
  git_quiet fetch -q --prune origin
}

asked_permission() { [ -n "$(hooks_after PermissionRequest "$sent_t0")" ]; }

# push_settled <Stop count before the send>: a permission request, or a Stop,
# after the send.
push_settled() { asked_permission || hook_count_above Stop "$1"; }

cmd_push() {
  local how=$1 nonce="T9P$RANDOM" text stops
  check_path "$how"
  new_run "push-$how"
  reset_repos
  echo "note $nonce" >"$work/note-$nonce.txt"
  start
  text="Commit note-$nonce.txt with the message \"Add note $nonce\" and push it to origin."
  stops=$(hook_count Stop)
  send "$how" "$text"
  # wait_until, not claude_until, so that no dialog is approved for the user.
  if ! wait_until 120 0.2 push_settled "$stops" >/dev/null; then
    record outcome timeout
  elif asked_permission; then
    record outcome dialog
    # The hook fires before Claude Code draws the dialog.
    sleep 1
    snap dialog
    pty_key "$run" Escape
    sleep 2
  else
    record outcome stopped
  fi
  delivered "$text"
  reply_after "$stops"
  record permission_requests "$(hooks_after PermissionRequest "$sent_t0" | jq -r '.tool_input.command // .tool_name')"
  record failures "$(hooks_after PostToolUseFailure "$sent_t0" | jq -c '{tool: .tool_name, error: (.error // "" | tostring | .[0:160])}')"
  record committed "$(has_commit "$work" "Add note $nonce" && echo yes || echo no)"
  record pushed "$(has_commit "$remote" "Add note $nonce" && echo yes || echo no)"
  record branch "$(git -C "$work" branch --show-current)"
  snap after
  finish
  reset_repos
  rm -f "$work/note-$nonce.txt"
}

# cmd_draft: the input box holds unsent text, as when the user is typing in
# the pane, and a message arrives.
cmd_draft() {
  local how=$1 nonce="T9D$RANDOM" text stops
  check_path "$how"
  new_run "draft-$how"
  start
  pty_type "$run" "DRAFT-$nonce unsent words"
  sleep 0.5
  text="Reply with only the word GAMMA-$nonce."
  stops=$(hook_count Stop)
  send "$how" "$text"
  if ! await_sent "$text" "$stops"; then
    finish
    return 1
  fi
  record prompt_has_draft "$(grep -q "DRAFT-$nonce" "$dir/prompt.txt" && echo yes || echo no)"
  # The input box is the last line that starts with the prompt mark. Earlier
  # ones are past prompts. A prompt suggestion can fill an empty input box,
  # but it never holds the nonce.
  record draft_in_input_box "$(pty_screen "$run" | grep '^❯' | tail -1 | grep -q "DRAFT-$nonce" && echo yes || echo no)"
  finish
}

cmd_explicit() {
  local nonce="T9E$RANDOM" text stops folder path
  new_run explicit
  # A Unix socket path can't exceed 103 bytes, so the socket goes in /tmp.
  # Claude Code refuses a folder that is a symlink, such as /tmp itself, or
  # that other users can write to.
  folder="/private/tmp/sb-t9-$$"
  path="$folder/inbox.sock"
  mkdir -m 700 "$folder"
  start --messaging-socket-path "$path"
  record explicit_path "$path"
  record explicit_used "$([ "$sock" = "$path" ] && echo yes || echo no)"
  text=$(two_line_text "$nonce")
  stops=$(hook_count Stop)
  # Sends to the path it set, not the one the pid file reports.
  sock=$path
  send socket "$text"
  ! await_sent "$text" "$stops" || both_words "$nonce"
  finish
  rm -rf "$folder"
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() {
  jq -c '{t, event, tool: .tool_name, cmd: (.tool_input.command // "" | .[0:60]), prompt: (.prompt // "" | .[0:80]), type: .notification_type}' \
    "$runs/$1/hooks.jsonl"
}

cmd_teardown() { pty_server_stop; }

"cmd_$1" "${@:2}"
