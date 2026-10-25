#!/usr/bin/env bash
# Phase 0 test 3: hooks over HTTP.
#
# Usage: t3-http-hooks.sh <command> [args]
#   setup               creates the work folder, starts the tmux server, and
#                       accepts workspace trust for the folder
#   events              a permission prompt, a subagent, a failing Bash call,
#                       /compact, idle_prompt, and SIGTERM
#   perm <mode>         a Bash call that needs permission while the listener
#                       holds the PermissionRequest hook (modes under cmd_perm)
#   down                every HTTP hook points at a port with no listener
#   slow                the listener holds every hook for 5 s, and every hook times out at 2 s
#   screen|hooks|http <run>  shows a run's pane, command hook log, or listener log
#   teardown            stops the tmux server
#
# Each run starts its own listener (lib/hook-listener.py). Its settings send
# every event to the command hook logger and to the listener. SessionStart
# takes only command hooks, so a command hook posts it with curl, as sbd would.
# The URL path carries the run name. The X-SB-Session and X-SB-Token headers
# show which variables Claude Code interpolates. An `ask` rule for `touch`
# makes the test's Bash call open a permission prompt, because the user's
# settings allow many commands.
# T3_ROOT holds the work folder and one folder per run. Each session writes a
# debug log to its run folder, which records every HTTP hook POST and its result.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T3_ROOT="${T3_ROOT:?set T3_ROOT to a scratch folder}"
work="$T3_ROOT/work"
runs="$T3_ROOT/runs"
model="${T3_MODEL:-haiku}"

# Every event in the 2.1.308 hooks reference except three. Setup takes only
# command hooks. WorktreeCreate's hook takes over creating worktrees.
# WorktreeRemove fires only for worktrees that WorktreeCreate's hook created.
hook_events=(SessionStart UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest
  PermissionDenied PostToolUse PostToolUseFailure PostToolBatch Notification MessageDisplay
  SubagentStart SubagentStop TaskCreated TaskCompleted Stop StopFailure TeammateIdle
  InstructionsLoaded ConfigChange CwdChanged DirectoryAdded FileChanged PreCompact PostCompact
  PreModelSwitch PostModelSwitch Elicitation ElicitationResult SessionEnd)

cmd_setup() {
  mkdir -p "$work" "$runs"
  [ -d "$work/.git" ] || git -C "$work" init -q
  # InstructionsLoaded fires when Claude Code reads this file.
  echo "Keep replies short." >"$work/CLAUDE.md"
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$work"
  echo "root: $T3_ROOT"
}

# t3_settings <timeouts>: writes $settings. <timeouts> is a JSON object that
# maps an event, or "*" for every event, to its HTTP hook timeout in seconds.
# Other events get Claude Code's default.
t3_settings() {
  local url="http://127.0.0.1:$port/hook/$run" post
  post="curl -s -o /dev/null --max-time 5 -H 'Content-Type: application/json' -H \"X-SB-Session: \$SB_SESSION_ID\" --data-binary @- $(sh_quote "$url") || true"
  write_settings "$dir/hooks.jsonl" | jq --arg url "$url" --arg post "$post" --argjson timeouts "$1" '
    .permissions = {ask: ["Bash(touch:*)"]}
    | .hooks |= with_entries(.key as $e | .value[0].hooks += [
        if $e == "SessionStart" then {type: "command", command: $post, timeout: 5}
        else {type: "http", url: $url,
          headers: {"X-SB-Session": "$SB_SESSION_ID", "X-SB-Token": "$SB_HOOK_TOKEN"},
          allowedEnvVars: ["SB_SESSION_ID", "SB_HOOK_TOKEN"]}
          + ($timeouts[$e] // $timeouts["*"] | if . then {timeout: .} else {} end)
        end])' >"$settings"
}

# new_run <kind> [policy] [timeouts]: sets run, dir, settings, and uuid, starts
# the run's listener with the policy (see lib/hook-listener.py) and sets
# listener and port, and opens a pane that exports SB_SESSION_ID and
# SB_HOOK_TOKEN. The EXIT trap closes the pane, which stops a claude still
# running in it, and stops the listener.
new_run() {
  local token
  pty_server_start
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  settings="$dir/settings.json"
  uuid=$(uuidgen | tr 'A-Z' 'a-z')
  token="token-$uuid"
  mkdir -p "$dir"
  echo "${2:-"{}"}" >"$dir/policy.json"
  trap on_exit EXIT
  python3 "$here/lib/hook-listener.py" "$dir" &
  listener=$!
  wait_until 5 0.1 test -s "$dir/port" >/dev/null
  port=$(<"$dir/port")
  t3_settings "${3:-"{}"}"
  record claude_version "$(claude --version)"
  record session "$uuid"
  record token "$token"
  pty_new "$run" "$work"
  pty_type "$run" "export SB_SESSION_ID=$run SB_HOOK_TOKEN=$token"
  pty_key "$run" Enter
}

on_exit() {
  pty_kill "$run"
  [ -z "${listener:-}" ] || kill "$listener" 2>/dev/null || true
}

start() {
  record start_ms "$(start_claude --session-id "$uuid" --permission-mode default --debug-file "$dir/debug.log")"
}

# http_of <event>: the listener's entries for one event, oldest first.
http_of() { hooks_of "$1" "$dir/listener.jsonl"; }

http_seen() { [ -n "$(http_of "$1")" ]; }

# http_t <event>: when the listener received the event's first request.
http_t() { http_of "$1" | head -1 | jq -r .t; }

# notified <type>: the listener received a Notification of that type.
notified() { http_of Notification | jq -e --arg k "$1" 'select(.body.notification_type == $k)' >/dev/null; }

claude_rss_kb() { ps -o rss= -p "$(claude_pid)" | tr -d ' '; }

touch_prompt() {
  echo "Use the Bash tool to run exactly this command: touch $1.txt . Then reply with only the word DONE."
}

# turn <label> <prompt>: ask, plus the ms from the prompt's UserPromptSubmit to
# Stop. A background subagent's result arrives as a UserPromptSubmit of its own.
turn() {
  local n
  n=$(hook_count UserPromptSubmit)
  ask "$1" "$2" 180
  record "$1_turn_ms" $(($(last_hook Stop | jq -r .t) - $(hooks_of UserPromptSubmit | sed -n "$((n + 1))p" | jq -r .t)))
}

# subagent_reported: the turn that the last subagent's result started has ended.
# While fork mode is on, which is the default, a subagent in an interactive
# session always runs in the background. Its result arrives as a
# <task-notification> prompt that starts a turn. The next ask would otherwise
# take that turn's Stop.
subagent_reported() {
  local id t
  id=$(hooks_of SubagentStart | tail -1 | jq -r .agent_id)
  t=$(hooks_of UserPromptSubmit | jq -r --arg tag "<task-id>$id</task-id>" 'select(.prompt | contains($tag)) | .t')
  [ -n "$t" ] && (($(last_hook Stop | jq -r .t) > t))
}

# parity: for each event, how often the command hook and the listener saw it,
# whether they saw the same payloads, and the range of the listener's arrival
# time minus the command hook's time. Events that fire together, such as two
# InstructionsLoaded, can reach the two in different orders.
parity() {
  jq -n -r --slurpfile cmd "$dir/hooks.jsonl" --slurpfile http "$dir/listener.jsonl" '
    ($http | map(select(.event | startswith("_") | not))) as $h
    | [$cmd[].event, $h[].event] | unique[] as $e
    | ($cmd | map(select(.event == $e))) as $c
    | ($h | map(select(.event == $e))) as $he
    | [range([$c, $he] | map(length) | min) | $he[.].t - $c[.].t] as $gaps
    | "parity_\($e)=cmd \($c | length) http \($he | length) same \(if ($c | map(del(.t, .event, .sb_env)) | sort) == ($he | map(.body) | sort) then "yes" else "no" end) gap_ms \($gaps | min) to \($gaps | max)"' |
    while IFS= read -r line; do record "${line%%=*}" "${line#*=}"; done
  # The SessionStart curl sends only X-SB-Session, which its own shell expands.
  record headers "$(jq -c 'select((.event | startswith("_")) or .event == "SessionStart" | not) | .headers | with_entries(.key |= ascii_downcase) | {s: .["x-sb-session"], k: .["x-sb-token"]}' "$dir/listener.jsonl" | sort | uniq -c | tr -s ' ')"
  record debug_http "$(grep -o -E 'HTTP hook (POST|response status [0-9]+|error: .{0,60}|not sent: .{0,60}|blocked: .{0,60})' "$dir/debug.log" | sort | uniq -c | tr -s ' ')"
}

cmd_events() {
  local nonce=$RANDOM n idle_t idle_since
  new_run events
  start
  turn touch "$(touch_prompt "ev-$nonce")"
  turn subagent "Use the Agent tool to start a general-purpose subagent. Its only job is to reply with the word PONG without using any tools. Then reply with what it said."
  record subagent_reported_ms "$(wait_until 180 0.5 subagent_reported)"
  turn fail "Use the Bash tool to run exactly this command: ls /nonexistent-sb-$nonce . Then reply with only the word DONE."
  turn pong "Reply with only the word PONG."
  n=$(hook_count PostCompact)
  slash_command /compact
  record compact_ms "$(claude_until 180 hook_count_above PostCompact "$n")"
  # /compact ends with PostCompact, not Stop.
  if wait_until 120 1 notified idle_prompt >/dev/null; then
    idle_t=$(http_of Notification | jq -s -r 'map(select(.body.notification_type == "idle_prompt")) | last | .t')
    idle_since=$(jq -s 'map(select(.event == "Stop" or .event == "PostCompact")) | max_by(.t) | .t' "$dir/hooks.jsonl")
    record idle_prompt_after_ms $((idle_t - idle_since))
  else
    record idle_prompt none
  fi
  stop_claude term end || true
  parity
}

# release <behavior>: writes the hook's answer, which the listener returns to
# the held PermissionRequest within 50 ms.
release() {
  jq -nc --arg b "$1" '{hookSpecificOutput: {hookEventName: "PermissionRequest",
    decision: ({behavior: $b} + if $b == "deny" then {message: "Denied by the Switchboard test listener."} else {} end)}}' \
    >"$dir/release.json.tmp"
  mv "$dir/release.json.tmp" "$dir/release.json"
  record "release_$1_at_ms" $(($(now_ms) - perm_t))
}

# answer_in_pane [item regex]: picks Yes, or the matching item, if the dialog shows.
answer_in_pane() {
  if screen_matches "$run" "$claude_proceed_title"; then
    pty_select "$run" "$claude_proceed_title" "${1:-^(1\. )?Yes}" || record dialog_unanswered "$(pty_menu_cursor "$run" "$claude_proceed_title")"
    record answered_in_pane_at_ms $(($(now_ms) - perm_t))
  else
    record answered_in_pane no-dialog
  fi
}

# cmd_perm <mode>: the listener holds PermissionRequest for up to 900 s.
#   allow     the hook allows 20 s after the request
#   deny      the hook denies 20 s after the request
#   terminal  Yes in the pane after 5 s, then the hook denies
#   no        No in the pane after 5 s, then the hook allows
#   esc       Escape in the pane after 5 s, then the hook allows
#   timeout   the hook times out at 15 s, then Yes in the pane if it asks
#   long      the hook allows 660 s after the request, under a 900 s timeout
#   overflow  a 2147484 s timeout, just over 2^31 ms. Yes in the pane if the
#             hook ends at once, otherwise the hook allows after 20 s
cmd_perm() {
  local mode=$1 timeout=900 after=20 nonce=$RANDOM stops wait=120
  case $mode in
  allow | deny | terminal | no | esc) ;;
  timeout) timeout=15 ;;
  long) after=660 ;;
  overflow) timeout=2147484 ;;
  *)
    echo "perm: unknown mode '$mode' (use allow, deny, terminal, no, esc, timeout, long, or overflow)" >&2
    return 2
    ;;
  esac
  new_run "perm-$mode" '{"PermissionRequest": {"hold": 900}}' "{\"PermissionRequest\": $timeout}"
  start
  stops=$(hook_count Stop)
  send_prompt "$(touch_prompt "perm-$nonce")"
  if ! wait_until 120 0.1 http_seen PermissionRequest >/dev/null; then
    record perm_request none
    snap no-request
    return 1
  fi
  perm_t=$(http_t PermissionRequest)
  record pre_tool_to_perm_ms $((perm_t - $(http_t PreToolUse)))
  sleep_until $((perm_t + 3000))
  snap hold
  record dialog_during_hold "$(screen_matches "$run" "$claude_proceed_title" && echo yes || echo no)"
  record agents_row "$(claude agents --json | jq -c --arg s "$uuid" '.[] | select(.sessionId == $s) | {status, waitingFor}')"
  record claude_rss_kb "$(claude_rss_kb)"
  case $mode in
  allow | long) sleep_until $((perm_t + after * 1000)) && release allow ;;
  deny) sleep_until $((perm_t + after * 1000)) && release deny ;;
  terminal)
    sleep_until $((perm_t + 5000))
    answer_in_pane
    wait_until 30 0.1 http_seen PostToolUse >/dev/null || true
    sleep 2
    release deny
    ;;
  no)
    sleep_until $((perm_t + 5000))
    answer_in_pane '^(2\. )?No'
    sleep 5
    snap after-no
    release allow
    wait=10
    ;;
  esc)
    sleep_until $((perm_t + 5000))
    pty_key "$run" Escape
    record esc_at_ms $(($(now_ms) - perm_t))
    sleep 5
    snap after-esc
    release allow
    wait=10
    ;;
  timeout)
    wait_until 30 0.2 http_seen _closed >/dev/null || true
    sleep 1
    snap after-timeout
    answer_in_pane
    ;;
  overflow)
    if http_seen _closed; then
      answer_in_pane
    else
      sleep_until $((perm_t + after * 1000)) && release allow
    fi
    ;;
  esac
  record before_answer_rss_kb "$(claude_rss_kb)"
  if wait_until "$wait" 0.2 hook_count_above Stop "$stops" >/dev/null; then
    record reply "$(last_hook Stop | jq -r .last_assistant_message)"
  else
    record reply none
  fi
  record tool_ran "$([ -e "$work/perm-$nonce.txt" ] && echo yes || echo no)"
  ! http_seen PostToolUse || record post_tool_at_ms $(($(http_t PostToolUse) - perm_t))
  record held "$(jq -r --argjson t0 "$perm_t" 'select(.of == "PermissionRequest") | "\(.event) at \(.t - $t0) ms \(.outcome // "")"' "$dir/listener.jsonl")"
  record notifications "$(http_of Notification | jq -r --argjson t0 "$perm_t" '"\(.body.notification_type) at \(.t - $t0) ms"')"
  snap after
  stop_claude term end || true
  parity
}

cmd_down() {
  new_run down
  kill "$listener"
  wait "$listener" 2>/dev/null || true
  listener=
  start
  turn touch "$(touch_prompt "down-$RANDOM")"
  turn pong "Reply with only the word PONG."
  snap down
  record hook_errors_on_screen "$(pty_screen "$run" | grep -c -i 'hook' || true)"
  stop_claude term end || true
  record debug_http "$(grep -o -E 'HTTP hook (error: .{0,60}|response status [0-9]+)' "$dir/debug.log" | sort | uniq -c | tr -s ' ')"
}

cmd_slow() {
  new_run slow '{"*": {"hold": 5}}' '{"*": 2}'
  start
  turn touch "$(touch_prompt "slow-$RANDOM")"
  turn pong "Reply with only the word PONG."
  snap slow
  record closed "$(http_of _closed | jq -r '"\(.of) \(.held_ms)"' | sort | uniq -c | tr -s ' ')"
  stop_claude term end || true
  parity
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() { jq -c '{t, event, tool: .tool_name, type: .notification_type}' "$runs/$1/hooks.jsonl"; }

cmd_http() { jq -c '{t, n, event, of, held_ms, outcome, type: .body.notification_type}' "$runs/$1/listener.jsonl"; }

cmd_teardown() { pty_server_stop; }

"cmd_$1" "${@:2}"
