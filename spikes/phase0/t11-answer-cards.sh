#!/usr/bin/env bash
# Phase 0 test 11: answer cards with the real claude.
#
# Usage: t11-answer-cards.sh <command>
#   setup                 creates the work folder, whose project settings ask
#                         before `touch`, and accepts workspace trust for it
#   allow|deny|interrupt  the session asks to run touch, and sb answers its
#                         card: allow, deny with a message, or deny without one
#   yes|esc               the session asks to run touch, and the terminal
#                         answers first with Yes or Escape
#   questions             the session asks two questions with AskUserQuestion,
#                         the second one multi-select. sb answers the first
#                         with typed text and the second with two labels
#   defer stopped|live    sbd defers the question after 20 s. The answer
#                         resumes the stopped session, or reaches the live one
#                         as a paste
#   teardown              stops sbd and its tmux server
#
# Every run starts a private sbd from this branch's debug build, with Haiku,
# no MCP servers, and T11_MODE as the permission mode (default "default").
# T11_ROOT holds the work folder, sbd's home, and one folder per run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T11_ROOT="${T11_ROOT:?set T11_ROOT to a scratch folder}"
work="$T11_ROOT/work"
runs="$T11_ROOT/runs"
home="$T11_ROOT/home"
# sbd runs sb by its resolved path, which held_hooks matches.
build="$(cd "$here/../../.build/debug" && pwd -P)"
mode="${T11_MODE:-default}"

sb() { SB_HOME="$home" "$build/sb" "$@"; }

# sbd_start <idle stop seconds>: restarts the private sbd with that setting.
sbd_start() {
  sbd_stop
  mkdir -p "$home"
  jq -n --arg claude "$(command -v claude)" --argjson idle "$1" --arg mode "$mode" \
    --arg config "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" '{
      claude: $claude, model: "haiku", idleStopSeconds: $idle, tickSeconds: 0.5,
      claudeArgs: ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--permission-mode", $mode],
      env: {CLAUDE_CONFIG_DIR: $config}}' >"$home/config.json"
  SB_HOME="$home" nohup "$build/sbd" >>"$home/sbd.log" 2>&1 &
  wait_until 10 0.1 sb ping >/dev/null 2>&1
}

sbd_stop() {
  local pid
  pid=$(sb ping --json 2>/dev/null | jq -r .pid) || return 0
  kill "$pid"
  pty_wait_gone "$pid" 10 >/dev/null || true
}

cmd_setup() {
  mkdir -p "$work/.claude" "$runs"
  [ -d "$work/.git" ] || git -C "$work" init -q
  echo '{"permissions": {"ask": ["Bash(touch:*)"], "allow": ["Write"]}}' >"$work/.claude/settings.json"
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$work"
  pty_server_stop
  echo "root: $T11_ROOT"
}

cmd_teardown() {
  sbd_stop
  tmux -S "$home/tmux.sock" kill-server 2>/dev/null || true
}

# new_run <kind> <prompt> [idle stop seconds]: starts sbd and a session with
# the prompt, and sets run, dir, nonce, and sid. The prompt's {nonce} becomes
# the run's nonce.
new_run() {
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  nonce="SB$RANDOM"
  mkdir -p "$dir"
  sbd_start "${3:-600}"
  record claude_version "$(claude --version)"
  record mode "$mode"
  sid=$(sb new --json "$work" --name "$run" --prompt "${2//\{nonce\}/$nonce}" | jq -r .id)
  record session "$sid"
  trap finish EXIT
}

# finish: saves the event log and the screen, and removes the session.
finish() {
  sb events --json --session "$sid" --since 0 >"$dir/events.jsonl" 2>/dev/null || true
  sb screen "$sid" >"$dir/screen-end.txt" 2>/dev/null || true
  sb rm "$sid" >/dev/null 2>&1 || true
  sbd_stop
}

session() { sb get --json "$sid"; }

# until_session <timeout> <jq filter>: waits until the session matches.
until_session() {
  local filter=$2
  matches() { session | jq -e "$filter" >/dev/null; }
  wait_until "$1" 0.2 matches
}

events() { sb events --json --session "$sid" --since 0; }

# event_t <kind> [jq filter]: the time of the last event of that kind.
event_t() { events | jq -s -r --arg k "$1" "map(select(.kind == \$k ${2:+and ($2)})) | last | .t // empty"; }

has_event() { [ -n "$(event_t "$@")" ]; }

key() { tmux -S "$home/tmux.sock" send-keys -t "=$sid-claude:" "$1"; }

held_hooks() { pgrep -f "$build/sb hook" | wc -l | tr -d ' '; }

snap_screen() { sb screen "$sid" >"$dir/screen-$1.txt"; }

touch_prompt() {
  echo "Run exactly this command with the Bash tool, and nothing else: touch perm-{nonce}.txt. If it is denied, do what the denial says instead. When you are done, reply with only the word FINISHED."
}

questions_prompt() {
  echo "Call the AskUserQuestion tool once, with two questions. The first asks \"Which fruit should I use?\" with the header \"Fruit\" and the options apple, banana, and cherry. The second asks \"Which colors should I use?\" with the header \"Colors\", multiSelect true, and the options red, green, and blue. After I answer, write a file named answers-{nonce}.txt that contains my fruit answer on the first line and my colors answer on the second line, exactly as I gave them, and reply with only the word FINISHED."
}

# card_opened: waits for the card and records how long it took from the
# PermissionRequest event.
card_opened() {
  if ! until_session 120 '.cards | length > 0' >/dev/null; then
    record card timeout
    snap_screen no-card
    return 1
  fi
  snap_screen card
  record card "$(session | jq -c '.cards[0] | {id, kind, summary, input, questions}')"
  record card_after_request_ms $(($(now_ms) - $(event_t PermissionRequest)))
  record held_hooks "$(held_hooks)"
}

# turn_ended <ms>: waits for a Stop after <ms> and records the reply.
turn_ended() {
  local t0=$1
  if wait_until 120 0.2 has_event Stop ".t > $t0" >/dev/null; then
    record answer_to_stop_ms $(($(event_t Stop) - t0))
    record reply "$(session | jq -r .lastReply)"
  else
    record stop timeout
  fi
}

cmd_permission() {
  local how=$1 t0 answer
  new_run "$how" "$(touch_prompt)"
  card_opened || return 1
  t0=$(now_ms)
  case $how in
  allow) answer=$(sb allow --json "$sid") ;;
  deny) answer=$(sb deny --json "$sid" "Do not create that file. Reply with only the word PINEAPPLE.") ;;
  interrupt) answer=$(sb deny --json "$sid") ;;
  esac
  record answer "$answer"
  case $how in
  allow | deny) turn_ended "$t0" ;;
  interrupt)
    wait_until 90 0.5 has_event Notification ".data.notification_type == \"idle_prompt\" and .t > $t0" >/dev/null || true
    record idle_prompt_after_ms $(($(event_t Notification '.data.notification_type == "idle_prompt"') - t0))
    record stop_after_answer "$(has_event Stop ".t > $t0" && echo yes || echo no)"
    snap_screen interrupted
    ;;
  esac
  record post_tool_use "$(has_event PostToolUse ".data.tool_name == \"Bash\"" && echo yes || echo no)"
  record file "$(ls "$work"/perm-"$nonce".txt 2>/dev/null || echo none)"
  record cards_after "$(session | jq -c '.cards | length')"
  record held_hooks_after "$(held_hooks)"
}

cmd_terminal() {
  local how=$1 t0
  new_run "$how" "$(touch_prompt)"
  card_opened || return 1
  t0=$(now_ms)
  case $how in
  yes) key Enter ;;
  esc) key Escape ;;
  esac
  if until_session 30 '.cards | length == 0' >/dev/null; then
    record card_gone_after_key_ms $(($(now_ms) - t0))
  else
    record card_gone timeout
  fi
  record card_closed_event "$(has_event card_closed && echo yes || echo no)"
  [ "$how" = yes ] && turn_ended "$t0"
  sleep 1
  record held_hooks_after "$(held_hooks)"
  record file "$(ls "$work"/perm-"$nonce".txt 2>/dev/null || echo none)"
  record state "$(session | jq -c '{state, reason}')"
  snap_screen after
}

cmd_questions() {
  local t0
  new_run questions "$(questions_prompt)"
  card_opened || return 1
  t0=$(now_ms)
  record answer "$(sb answer --json "$sid" "a ripe mango" "Blue,red")"
  turn_ended "$t0"
  record tool_answers "$(events | jq -s -c 'map(select(.kind == "PostToolUse" and .data.tool_name == "AskUserQuestion")) | last | .data.tool_response.answers')"
  record file "$(cat "$work/answers-$nonce.txt" 2>/dev/null || echo none)"
}

cmd_defer() {
  local how=$1 t0
  new_run "defer-$how" "$(questions_prompt)" 20
  card_opened || return 1
  if ! until_session 60 '.cards[0].deferred' >/dev/null; then
    record deferred timeout
    return 1
  fi
  record deferred_after_request_ms $(($(event_t deferred) - $(event_t PermissionRequest)))
  wait_until 60 0.2 has_event Stop ".t > $(event_t deferred)" >/dev/null || true
  record deferred_to_stop_ms $(($(event_t Stop) - $(event_t deferred)))
  record deferred_reply "$(session | jq -r .lastReply)"
  record tools_after_defer "$(events | jq -s -c --argjson t "$(event_t deferred)" 'map(select(.kind == "PreToolUse" and .t > $t) | .data.tool_name)')"
  snap_screen deferred
  if [ "$how" = stopped ]; then
    until_session 60 '.live == false' >/dev/null || record idle_stop timeout
  fi
  record state_before_answer "$(session | jq -c '{state, reason, live, cards: (.cards | map(.deferred))}')"
  t0=$(now_ms)
  record answer "$(sb answer --json "$sid" cherry "green, blue")"
  wait_until 120 0.5 test -s "$work/answers-$nonce.txt" >/dev/null || true
  record answer_to_file_ms $(($(now_ms) - t0))
  record answer_prompts "$(events | jq -s -c --argjson t "$t0" 'map(select(.kind == "UserPromptSubmit" and .t > $t) | .data.prompt)')"
  record file "$(cat "$work/answers-$nonce.txt" 2>/dev/null || echo none)"
  record cards_after "$(session | jq -c '.cards | length')"
}

case "${1:-}" in
setup) cmd_setup ;;
allow | deny | interrupt) cmd_permission "$1" ;;
yes | esc) cmd_terminal "$1" ;;
questions) cmd_questions ;;
defer) cmd_defer "${2:?defer stopped|live}" ;;
teardown) cmd_teardown ;;
*)
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
