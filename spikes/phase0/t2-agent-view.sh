#!/usr/bin/env bash
# Phase 0 test 2: Claude Code's background sessions (agent view).
#
# Usage: t2-agent-view.sh <command> [args]
#   setup                creates the repo and its linked worktree, starts the tmux
#                        server, and accepts workspace trust for the repo
#   lifecycle            start, stop, attach, recall, detach, and resume with a prompt
#   bgwork               stops a session while its background Bash job runs
#   blocked              a session that waits for an AskUserQuestion answer
#   trust                starts a session in a linked worktree outside T2_ROOT
#   idle <minutes>       leaves a finished session unattached and polls it every minute
#   screen|hooks <run>   shows a run's pane or hook log
#   cleanup              stops every session under T2_ROOT and stops the tmux server
#
# Sessions start the way sbd would: `claude --bg` from a shell with no terminal
# and a clean environment, in a linked worktree of a trusted repo. A session's
# worker runs under Claude Code's supervisor and takes its environment from the
# supervisor, not from the `claude --bg` command, unless that command started
# the supervisor. Each run records which process started the supervisor. Each
# run's settings file sets SB_SESSION_ID in its env block, and the launching
# shell exports SB_PROBE, so the hook log shows which of the two reaches the
# session.
# T2_ROOT holds the repo, the worktree, and one folder per run. Durations whose
# name ends in _max_ms include one `claude agents` call, about 0.2 s.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T2_ROOT="${T2_ROOT:?set T2_ROOT to a scratch folder}"
repo="$T2_ROOT/repo"
wt="$T2_ROOT/wt"
runs="$T2_ROOT/runs"
model="${T2_MODEL:-haiku}"

# `claude --bg` without a terminal refuses an untrusted folder.
cmd_setup() {
  mkdir -p "$runs" "$repo"
  if [ ! -d "$repo/.git" ]; then
    git -C "$repo" init -q
    git -C "$repo" commit -q --allow-empty --no-gpg-sign -m init
  fi
  [ -d "$wt" ] || git -C "$repo" worktree add -q -b t2 "$wt"
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$wt"
  echo "root: $T2_ROOT"
}

# new_run <kind>: sets run, dir, and settings for a new run. If the run ends
# early, the EXIT trap stops the run's session and closes its pane.
new_run() {
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  settings="$dir/settings.json"
  mkdir -p "$dir"
  write_settings "$dir/hooks.jsonl" | jq --arg id "$run" '.env = {SB_SESSION_ID: $id}' >"$settings"
  record claude_version "$(claude --version)"
  trap on_exit EXIT
}

# Stops only the session that this run's own `claude --bg` started.
on_exit() {
  pty_kill "$run"
  if [ -n "${id:-}" ] && [ -n "$(row_field pid 2>/dev/null)" ]; then
    claude stop "$id" >/dev/null 2>&1 || true
  fi
  record supervisor "$(claude daemon status 2>&1 | awk '/^(pid|origin):/' | paste -sd ' ' - || true)"
}

# bg <label> <cwd> <args...>: runs claude --bg as sbd would. Records the ms
# until it returned and the notes and warnings it printed. Sets bg_t0 to the
# time it started, and bg_id to the id of the session that took the prompt, or
# to nothing if claude started none.
bg() {
  local label=$1 cwd=$2 out
  shift 2
  bg_t0=$(now_ms)
  out=$(cd "$cwd" && clean_env SB_PROBE="shell-$run" claude --bg "$@" </dev/null 2>&1) || true
  record "${label}_return_ms" $(($(now_ms) - bg_t0))
  echo "$out" >>"$dir/bg-output.txt"
  record "${label}_notes" "$(grep -E '^(note|warning|Workspace)' <<<"$out" || true)"
  bg_id=$(grep -oE 'backgrounded · [0-9a-f]{8}' <<<"$out" | awk '{print $3}' || true)
  record "${label}_id" "${bg_id:-none}"
}

# bg_start <prompt>: starts a session in the worktree and sets id.
bg_start() {
  bg start "$wt" --model "$model" --settings "$settings" --name "$run" "$1"
  id=${bg_id:?claude --bg started no session}
}

# bg_resume <label> <prompt>: resumes the stopped session with a prompt and no
# flags, because any flag makes claude start a copy. A running session also
# gets a copy, which this stops at once.
bg_resume() {
  local sid
  sid=$(row_field sessionId)
  bg "$1" "$wt" --resume "$sid" "$2"
  if [ -n "$bg_id" ] && [ "$bg_id" != "$id" ]; then
    claude stop "$bg_id" >/dev/null || true
  fi
}

row() { claude agents --json --all | jq -c --arg i "${1:-$id}" '.[] | select(.id == $i)'; }

row_field() { row | jq -r --arg f "$1" '.[$f] // empty'; }

state_is() { [ "$(row_field state)" = "$1" ]; }

# turn_done <label> <Stop count before the turn> <timeout seconds>: waits for
# a new Stop hook and for the row to read done. Records the reply and the ms
# from the hook until a poll read done.
turn_done() {
  local stops=$2
  wait_until "$3" 0.05 hook_count_above Stop "$stops" >/dev/null || {
    record "$1_timeout" "$(row)"
    return 1
  }
  record "$1_reply" "$(last_hook Stop | jq -r .last_assistant_message)"
  if wait_until 10 0.02 state_is "done" >/dev/null; then
    record "$1_stop_to_done_max_ms" $(($(now_ms) - $(last_hook Stop | jq -r .t)))
  else
    record "$1_stop_to_done_max_ms" timeout
  fi
}

# snap_bg <label>: records the memory of the session's worker, its MCP
# servers, its terminal host, and the supervisor.
snap_bg() {
  local worker host sup
  worker=$(row_field pid)
  [ -n "$worker" ] || {
    record "$1_rss_kb" no-worker
    return 0
  }
  host=$(ps -o ppid= -p "$worker" | tr -d ' ' || true)
  sup=$(ps -o ppid= -p "$host" | tr -d ' ' || true)
  proc_tree "$sup" >"$dir/tree-$1.txt" || true
  record "$1_rss_kb" "worker=$(ps -o rss= -p "$worker" | tr -d ' ') host=$(ps -o rss= -p "$host" | tr -d ' ') supervisor=$(ps -o rss= -p "$sup" | tr -d ' ') worker_children=$(proc_tree "$worker" | awk 'NR > 1 {s += $4} END {print s + 0}')"
  record "$1_pids" "worker=$worker host=$host supervisor=$sup"
}

# gone_since <label> <pid> <t0>: waits up to 15 s for the process to exit and
# records the ms from t0.
gone_since() {
  if pty_wait_gone "$2" 15 >/dev/null; then record "$1" $(($(now_ms) - $3)); else record "$1" timeout; fi
}

# bg_stop <label>: claude stop, then records how long the command, the worker,
# and its terminal host took, each from the start of the stop, and what the
# row says.
bg_stop() {
  local worker host t0 ends
  worker=$(row_field pid)
  [ -n "$worker" ] || {
    record "$1_worker" none
    return 0
  }
  host=$(ps -o ppid= -p "$worker" | tr -d ' ' || true)
  ends=$(hook_count SessionEnd)
  t0=$(now_ms)
  claude stop "$id" >/dev/null
  record "$1_return_ms" $(($(now_ms) - t0))
  gone_since "$1_worker_gone_ms" "$worker" "$t0"
  gone_since "$1_host_gone_ms" "${host:-0}" "$t0"
  sleep 1
  record "$1_row" "$(row | jq -c '{state, status, pid}')"
  if hook_count_above SessionEnd "$ends"; then
    record "$1_session_end" "$(last_hook SessionEnd | jq -r .reason)"
  else
    record "$1_session_end" none
  fi
}

transcript_ok() {
  if jq -e . "$(transcript)" >/dev/null 2>&1; then record "$1_transcript_valid" yes; else record "$1_transcript_valid" no; fi
}

cmd_lifecycle() {
  local nonce stops nonce_ms ready_ms
  new_run lifecycle
  nonce="SB2-$RANDOM$RANDOM"
  bg_start "Reply with exactly this code and nothing else: $nonce"
  turn_done turn1 0 60
  record env "$(last_hook Stop | jq -c .sb_env)"
  snap_bg idle
  record logs "$(claude logs "$id" 2>&1 | grep -c -- "$nonce") lines with the nonce"
  bg_stop stop1
  transcript_ok stop1

  pty_server_start
  pty_new "$run" "$wt"
  clear_pane
  pty_type "$run" "claude attach $id"
  pty_key "$run" Enter
  nonce_ms=$(pty_wait "$run" 30 "⏺ $nonce")
  ready_ms=$(pty_wait "$run" 30 "$claude_ready_re")
  record attach_nonce_ms "$nonce_ms"
  record attach_ready_ms $((nonce_ms + ready_ms))
  snap attached
  ask recall "What exact code did you reply with earlier in this conversation? Reply with only that code." 60
  pty_key "$run" C-z
  sleep 1
  record detach_modes "$(pty_modes "$run")"
  shell_ok detach
  record detach_row "$(row | jq -c '{state, status, pid}')"

  bg_resume running "Reply with only: COPY-$nonce"
  bg_stop stop2

  stops=$(hook_count Stop)
  bg_resume stopped "What exact code did you reply with first in this conversation? Reply with only that code."
  record resume_row_after_return "$(row | jq -c '{state, status}')"
  turn_done resume "$stops" 60
  record resume_turn_ms $(($(last_hook Stop | jq -r .t) - bg_t0))
  bg_stop cleanup
  echo "run: $dir"
}

cmd_bgwork() {
  local nonce stops
  new_run bgwork
  nonce="SB2BG$RANDOM$RANDOM"
  bg_start "Use the Bash tool with run_in_background set to true to run exactly this command: sleep 90 && touch $wt/bg-done-$nonce. Do not wait for it or check on it. After you start it, reply with only: STARTED $nonce"
  turn_done turn1 0 90
  sleep 3
  record after_stop_row "$(row | jq -c '{state, status, waitingFor, pid}')"
  snap_bg running
  record job_before "$(pgrep -fl -- "$nonce" | cut -c1-100 | paste -sd ';' - || true)"
  bg_stop stop1
  sleep 2
  record job_after_stop "$(for p in $(pgrep -f -- "$nonce"); do ps -o pid=,ppid=,command= -p "$p" | cut -c1-100; done | paste -sd ';' - || true)"
  if wait_until 120 2 test -e "$wt/bg-done-$nonce" >/dev/null; then record job_finished yes; else record job_finished no; fi
  sleep 10
  record after_job_row "$(row | jq -c '{state, status, pid}')"
  record after_job_prompts "$(hook_count UserPromptSubmit)"
  # If the job's end woke the session, a resume would start a copy instead.
  [ -z "$(row_field pid)" ] || bg_stop woken
  stops=$(hook_count Stop)
  bg_resume belief "Did the background command you started earlier finish? Check with your tools if you can. Answer in one sentence that starts with BG:"
  turn_done belief "$stops" 120
  bg_stop cleanup
  rm -f "$wt/bg-done-$nonce"
  echo "run: $dir"
}

ask_hook_t() { hooks_of PreToolUse | jq -r 'select(.tool_name == "AskUserQuestion") | .t' | tail -1; }

cmd_blocked() {
  local ask_t
  new_run blocked
  bg_start "Use the AskUserQuestion tool to ask me one question: should the test use option A or option B? Offer exactly those two options. Do nothing else."
  if ! wait_until 60 0.05 state_is blocked >/dev/null; then
    record blocked_timeout "$(row)"
    bg_stop stop1
    return 1
  fi
  ask_t=$(ask_hook_t)
  if [ -n "$ask_t" ]; then
    record ask_to_blocked_max_ms $(($(now_ms) - ask_t))
  else
    record ask_hook none
  fi
  record blocked_row "$(row | jq -c '{state, status, waitingFor, pid}')"
  if wait_until 20 0.2 hook_count_above Notification 0 >/dev/null && [ -n "$ask_t" ]; then
    record ask_to_notification_ms $(($(last_hook Notification | jq -r .t) - ask_t))
  fi
  record notifications "$(hooks_of Notification | jq -c '{notification_type, message}' | paste -sd ';' -)"
  record logs_question "$(claude logs "$id" 2>&1 | grep -c 'option A' || true) lines name option A"
  bg_stop stop1
  echo "run: $dir"
}

cmd_trust() {
  local outside
  new_run trust
  outside="$T2_ROOT-outside-$(date +%H%M%S)"
  git -C "$repo" worktree add -q --detach "$outside"
  record outside "$outside"
  bg start "$outside" --model "$model" --settings "$settings" --name "$run" "Reply with only: TRUST-OK"
  id=$bg_id
  if [ -n "$id" ]; then
    turn_done turn1 0 60
    bg_stop stop1
  fi
  echo "run: $dir"
}

cmd_idle() {
  local minutes=$1 i
  new_run idle
  bg_start "Reply with only: IDLE"
  turn_done turn1 0 60
  snap_bg start
  for ((i = 1; i <= minutes; i++)); do
    sleep 60
    echo "$i min $(row | jq -c '{state, status, pid}') supervisor=$(claude daemon status 2>&1 | awk '/^pid:/ {print $2}')" >>"$dir/idle-poll.txt"
  done
  bg_stop cleanup
  echo "run: $dir"
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() {
  jq -c '{t, event, tool: .tool_name, type: .notification_type, msg: (.last_assistant_message // .message // "" | .[0:80])}' \
    "$runs/$1/hooks.jsonl"
}

# Stops the running background sessions in T2_ROOT, under it, or in a folder
# that cmd_trust created next to it.
cmd_cleanup() {
  local i
  for i in $(claude agents --json | jq -r --arg r "$T2_ROOT" '.[] | select(.kind == "background" and .pid != null and (.cwd == $r or (.cwd | startswith($r + "/")) or (.cwd | startswith($r + "-outside-")))) | .id'); do
    claude stop "$i" || true
  done
  pty_server_stop
}

"cmd_$1" "${@:2}"
