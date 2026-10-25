#!/usr/bin/env bash
# Phase 0 test 1: stop and resume a terminal session.
#
# Usage: t1-stop-resume.sh <command> [args]
#   setup                         creates the work folder and starts the tmux server
#   basic <method>                one turn, stop, two timed resumes, a recall turn
#   long <method> <src> <marker>  times resumes of a copy of a large transcript
#   bgbash <method>               stops a session while a background Bash job runs
#   bgagent <method>              stops a session while a background subagent runs
#   race <signal> <count>         sends the signal as soon as the Stop hook fires
#   screen|hooks|tree|modes <run> shows a run's pane, hook log, process tree, or modes
#   teardown                      stops the tmux server
#
# <method> is term (SIGTERM), hup (SIGHUP), or exit (pasted /exit).
# SB_EXIT_CHOICE picks the answer to the dialog that /exit opens while
# background work runs (see lib/claude.sh).
# T1_ROOT holds the work folder, the hook settings, and one folder per run.
# Each run writes summary.txt and screen and process snapshots to its folder.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T1_ROOT="${T1_ROOT:?set T1_ROOT to a scratch folder}"
work="$T1_ROOT/work"
settings="$T1_ROOT/hooks.json"
runs="$T1_ROOT/runs"
model="${T1_MODEL:-haiku}"

cmd_setup() {
  mkdir -p "$work" "$runs"
  [ -d "$work/.git" ] || git -C "$work" init -q
  # A stand-in for a long test run. Claude Code refuses a bare foreground sleep.
  cat >"$work/slow-task.sh" <<'EOF'
#!/bin/sh
i=0
while [ "$i" -lt 120 ]; do i=$((i + 1)); echo "step $i"; sleep 1; done
echo "AGENT-DONE-$1"
EOF
  chmod +x "$work/slow-task.sh"
  write_settings >"$settings"
  pty_server_start
  echo "root: $T1_ROOT"
}

# new_run <kind>: sets run, dir, and uuid, and opens the run's pane. The pane
# closes when the script exits, which also stops a claude still running in it.
new_run() {
  pty_server_start
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  uuid=$(uuidgen | tr 'A-Z' 'a-z')
  mkdir -p "$dir"
  trap 'pty_kill "$run"' EXIT
  pty_new "$run" "$work"
  record session "$uuid"
  record baseline_modes "$(pty_modes "$run")"
}

running() { pgrep -f -- "$1" >/dev/null; }

cmd_basic() {
  local method=$1 nonce i
  new_run "basic-$method"
  nonce="SB1-$RANDOM$RANDOM"
  record start_ms "$(start_claude --session-id "$uuid")"
  ask turn1 "Reply with exactly this code and nothing else: $nonce" 60
  check_transcript before "$nonce"
  for i in 1 2; do
    stop_claude "$method" "stop$i" || return 1
    shell_ok "stop$i"
    check_transcript "stop$i" "$nonce"
    resume_timed "resume$i" "$uuid" "⏺ $nonce"
  done
  ask recall "What exact code did you reply with earlier in this conversation? Reply with only that code." 60
  stop_claude term cleanup || true
  echo "run: $dir"
}

# cmd_long <method> <source transcript> <marker regex>
# Copies the transcript under a new session id, then resumes it twice.
# Needs an earlier run, whose transcript path names the work folder's project folder.
cmd_long() {
  local method=$1 src=$2 marker=$3 project
  new_run "long-$method"
  project=$(dirname "$(transcript "$runs"/*/hooks.jsonl)")
  sed "s/$(basename "$src" .jsonl)/$uuid/g" "$src" >"$project/$uuid.jsonl"
  record source "$src"
  record source_bytes "$(wc -c <"$src" | tr -d ' ')"
  resume_timed resume1 "$uuid" "$marker"
  stop_claude "$method" stop1 || return 1
  shell_ok stop1
  check_transcript stop1 "$marker"
  resume_timed resume2 "$uuid" "$marker"
  stop_claude "$method" stop2 || return 1
  check_transcript stop2 "$marker"
  echo "run: $dir"
}

# bg_stop <method> <nonce>: stops claude, then records what is left of the
# background work, which runs a command that contains the nonce.
bg_stop() {
  local method=$1 nonce=$2
  snap running
  record running_children "$(awk 'NR > 2 {print $5, $6, $7, $8}' "$dir/tree-running.txt" | cut -c1-80)"
  stop_claude "$method" stop1 || return 1
  sleep 2
  record bg_procs_after_stop "$(pgrep -fl -- "$nonce" | cut -c1-120 || true)"
  record bg_procs_ppids "$(for p in $(pgrep -f -- "$nonce"); do ps -o ppid= -p "$p"; done | tr -d ' ' | paste -sd ',' - || true)"
  record agents_after_stop "$(claude agents --json --cwd "$work" | jq -c '.' | cut -c1-400)"
  shell_ok stop1
}

# bg_resume <nonce> <question>: resumes the stopped session and asks what it
# believes about its background work.
bg_resume() {
  check_transcript stop1 "$1"
  resume_timed resume1 "$uuid" "STARTED $1"
  ask belief "$2" 120
  snap belief
  stop_claude term cleanup || true
  # A fork left by SB_EXIT_CHOICE=2 would run a turn when the job ends.
  stop_background_sessions "$work"
  kill_bg "$1"
  echo "run: $dir"
}

cmd_bgbash() {
  local method=$1 nonce
  new_run "bgbash-$method"
  nonce="SB1BG$RANDOM$RANDOM"
  record start_ms "$(start_claude --session-id "$uuid")"
  ask turn1 "Use the Bash tool with run_in_background set to true to run exactly this command: sleep 120 && touch $work/bg-done-$nonce. Do not wait for it or check on it. After you start it, reply with only: STARTED $nonce" 90
  record bash_pretool "$(hooks_of PreToolUse | jq -c 'select(.tool_name == "Bash") | .tool_input' | tail -1)"
  sleep 2
  bg_stop "$method" "$nonce" || return 1
  bg_resume "$nonce" "Is the background command you started earlier still running? Check with your tools if you can. Answer in one sentence that starts with BG:"
}

cmd_bgagent() {
  local method=$1 nonce sub
  new_run "bgagent-$method"
  nonce="SB1AG$RANDOM$RANDOM"
  record start_ms "$(start_claude --session-id "$uuid")"
  ask turn1 "Use the Agent tool with run_in_background set to true to start a general-purpose subagent with this task: 'Run the Bash command ./slow-task.sh $nonce in the foreground with a 300000 ms timeout. It is a test run that takes about two minutes. Then report its last line.' Do not wait for the subagent or check on it. After you launch it, reply with only: STARTED $nonce" 90
  wait_until 30 0.2 hook_count_above SubagentStart 0 >/dev/null || record subagent_start none
  wait_until 60 0.5 running "slow-task.sh $nonce" >/dev/null || record subagent_task none
  bg_stop "$method" "$nonce" || return 1
  record subagent_stops "$(subagent_stop_count)"
  sub=$(ls "$(dirname "$(transcript)")/$uuid/subagents/"*.jsonl 2>/dev/null | head -1 || true)
  record subagent_transcript "${sub:-none}"
  if [ -n "$sub" ]; then
    record subagent_transcript_last "$(tail -1 "$sub" | jq -c '{type, content: (.message.content // "" | tostring | .[0:120])}' 2>/dev/null || echo unparsable)"
  fi
  bg_resume "$nonce" "Did the background subagent you started earlier finish? Check with your tools if you can. Answer in one sentence that starts with AGENT:"
}

# cmd_race <signal> <count>: sends the signal as soon as the Stop hook fires,
# then checks whether the turn's reply reached the transcript. Repeats <count>
# times in one session, resuming between turns.
cmd_race() {
  local sig=$1 count=$2 i nonce stops pid kill_t
  new_run "race-$sig"
  start_claude --session-id "$uuid" >/dev/null
  for ((i = 1; i <= count; i++)); do
    ((i == 1)) || resume_timed "resume$i" "$uuid" "$claude_ready_re"
    nonce="SB1R$i-$RANDOM$RANDOM"
    stops=$(hook_count Stop)
    pid=$(claude_pid)
    send_prompt "Reply with exactly this code and nothing else: $nonce"
    wait_until 60 0.02 hook_count_above Stop "$stops" >/dev/null || return 1
    kill "-$sig" "$pid"
    kill_t=$(now_ms)
    record "turn${i}_kill_after_stop_hook_ms" $((kill_t - $(last_hook Stop | jq -r .t)))
    record "turn${i}_exit_ms" "$(pty_wait_gone "$pid" 10)"
    check_transcript "turn$i" "$nonce"
    clear_pane
  done
  echo "run: $dir"
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() {
  jq -c '{t, event, source, reason, tool: .tool_name, agent: .agent_type, msg: (.last_assistant_message // .message // "" | .[0:80])}' \
    "$runs/$1/hooks.jsonl"
}

cmd_tree() { proc_tree "$(pty_shell_pid "$1")" | cut -c1-200; }

cmd_modes() { pty_modes "$1"; }

cmd_teardown() { pty_server_stop; }

"cmd_$1" "${@:2}"
