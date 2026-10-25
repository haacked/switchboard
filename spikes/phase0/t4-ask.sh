#!/usr/bin/env bash
# Phase 0 test 4: answering questions.
#
# Usage: t4-ask.sh <command> [args]
#   setup               creates the work folder and the sb stand-in, starts the
#                       tmux server, and accepts workspace trust for the folder
#   ask stopped|live    the session asks which fruit to name a file after with
#                       sb ask and ends its turn. The answer is the first prompt
#                       of a resume after SIGTERM, or a paste into the live session
#   choice              the same request, with AskUserQuestion not denied
#   native <event> [s]  the session asks with AskUserQuestion, and a
#                       PermissionRequest or PreToolUse hook answers it after
#                       s seconds
#   pane                a PermissionRequest hook holds the question for 30 s,
#                       and the pane picks an answer first
#   defer               the session asks with AskUserQuestion, and a
#                       PermissionRequest hook denies the call with a message
#                       that says the answer comes later. The answer is the
#                       first prompt of a resume after SIGTERM
#   screen|hooks <run>  shows a run's pane or hook log
#   teardown            stops the tmux server
#
# Each pane puts lib/sb-stub.sh first on PATH as sb. The stub records the
# question in the run folder and returns at once. In ask and choice, the
# session gets sb's instructions through --append-system-prompt, as sbd would
# give them. Every run's settings allow `sb ask` and Write, because the user's
# default permission mode may ask for them. The settings of an ask run also
# deny AskUserQuestion.
# T4_ROOT holds the work folder, the sb link, and one folder per run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T4_ROOT="${T4_ROOT:?set T4_ROOT to a scratch folder}"
work="$T4_ROOT/work"
runs="$T4_ROOT/runs"
bin="$T4_ROOT/bin"
model="${T4_MODEL:-haiku}"
hook_events=(SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse
  PostToolUseFailure Notification Stop SessionEnd)

# shellcheck disable=SC2016 # The backticks are Markdown, not a command.
sb_prompt_arg="--append-system-prompt $(sh_quote 'You run inside Switchboard, which runs many Claude Code sessions for one user. When you need a decision from the user before you can go on, run `sb ask "<question>" "<option>" "<option>"` with the Bash tool, with one argument per option. Then end your turn without doing more work. Switchboard shows the question to the user, and their answer arrives as your next message.')"

# AskUserQuestion's dialog starts with the question's header chip.
ask_dialog_re='^ ☐ '

cmd_setup() {
  mkdir -p "$work" "$runs" "$bin"
  [ -d "$work/.git" ] || git -C "$work" init -q
  ln -sf "$here/lib/sb-stub.sh" "$bin/sb"
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$work"
  echo "root: $T4_ROOT"
}

# new_run <kind> <deny|allow> [event] [hook env]: sets run, dir, settings,
# and uuid, and opens a pane that exports SB_SESSION_ID and SB_HOME and puts
# sb on PATH. The second argument says what the settings do with
# AskUserQuestion. With an event, lib/answer-question.sh runs as that event's
# hook. The hook env, such as SB_HOLD=10, goes in front of the hook's command.
# The EXIT trap closes the pane, which stops a claude still running in it.
new_run() {
  local hook
  pty_server_start
  run="$1-$(date +%H%M%S)"
  dir="$runs/$run"
  settings="$dir/settings.json"
  uuid=$(uuidgen | tr 'A-Z' 'a-z')
  mkdir -p "$dir"
  trap 'pty_kill "$run"' EXIT
  hook="${4:-} $(sh_quote "$here/lib/answer-question.sh")"
  # The 3600 s timeout leaves room for SB_HOLD. The hook exits at once for other tools.
  write_settings | jq --arg ask "$2" --arg event "${3:-}" --arg hook "$hook" '
    .permissions = {allow: ["Bash(sb ask:*)", "Write"]}
    | if $ask == "deny" then .permissions.deny = ["AskUserQuestion"] else . end
    | if $event != "" then .hooks[$event][0].hooks += [{type: "command", command: $hook, timeout: 3600}] else . end' \
    >"$settings"
  record claude_version "$(claude --version)"
  record session "$uuid"
  pty_new "$run" "$work"
  pty_type "$run" "export SB_SESSION_ID=$run SB_HOME=$dir PATH=$bin:\$PATH"
  pty_key "$run" Enter
}

# start [claude args]: starts claude and saves the args in start_args.
start() {
  start_args=("$@")
  record start_ms "$(start_claude --session-id "$uuid" "$@")"
}

fruit_prompt() {
  echo "I want a text file in this folder named after a fruit, as <fruit>-$1.txt, that contains only the word DONE. Ask me which fruit to use, with apple, banana, and cherry as the options. Don't create any file until I answer."
}

ask_tool_prompt() {
  echo "Use the AskUserQuestion tool to ask me which fruit to use, with apple, banana, and cherry as the options. Then create a text file in this folder named <fruit>-$1.txt that contains only the word DONE."
}

# fruit_files <nonce>: the names of the work folder's files that end in
# -<nonce>.txt, joined with commas, or none.
fruit_files() {
  local files
  files=$(cd "$work" && find . -maxdepth 1 -name "*-$1.txt" | sed 's|^\./||' | paste -sd ',' -)
  echo "${files:-none}"
}

# tools_since <ms>: the tool calls that started after the time, each with the
# start of its command or file path.
tools_since() {
  hooks_of PreToolUse | jq -r --argjson t0 "$1" 'select(.t > $t0)
    | "\(.tool_name) \(.tool_input.command // .tool_input.file_path // "" | .[0:100])"'
}

# ask_tool_hooks <event>: the event's logged payloads for AskUserQuestion.
ask_tool_hooks() { hooks_of "$1" | jq -c 'select(.tool_name == "AskUserQuestion")'; }

used_ask_tool() { [ -n "$(ask_tool_hooks PreToolUse)" ]; }

question_answers() { ask_tool_hooks PostToolUse | jq -c .tool_response.answers; }

# asked <nonce> <ms>: records the asking turn's tool calls, the ms from <ms> to
# the last Stop, how many calls started after <ms>, and the fruit files that
# exist so far. <ms> is when the asking call ended.
asked() {
  record asking_tools "$(tools_since 0)"
  record ask_to_stop_ms $(($(last_hook Stop | jq -r .t) - $2))
  record tools_after_ask "$(tools_since "$2" | wc -l | tr -d ' ')"
  record files_before_answer "$(fruit_files "$1")"
}

# sb_asked <nonce>: records the question that sb ask received. If the sb ask
# call finished, it then runs asked from the time that call ended. Returns 1 if
# sb ask recorded no question.
sb_asked() {
  local post
  record question "$(cat "$dir/questions.jsonl" 2>/dev/null || echo none)"
  post=$(hooks_of PostToolUse | jq -r 'select(.tool_name == "Bash" and (.tool_input.command | contains("sb ask"))) | .t' | tail -1)
  [ -z "$post" ] || asked "$1" "$post"
  [ -s "$dir/questions.jsonl" ]
}

# answer <stopped|live> <nonce> <question> <fruit>: sends the answer as sbd
# would, as the first prompt of a resume after SIGTERM or as a paste into the
# live session. The resume passes start_args. It then records how the session
# continued.
answer() {
  local path=$1 nonce=$2 fruit=$4 text stops prompts t0 sent got
  text="Answer to your question \"$3\": $fruit"
  record answer "$text"
  snap asked
  stops=$(hook_count Stop)
  prompts=$(hook_count UserPromptSubmit)
  if [ "$path" = stopped ]; then
    stop_claude term stop1 || return 1
    clear_pane
    pty_type "$run" "$(claude_cmd --resume "$uuid" "${start_args[@]}" "$(sh_quote "$text")")"
  else
    # A person's answer comes some seconds after the reply.
    sleep 3
    pty_paste "$run" "$text"
    sleep 0.3
  fi
  t0=$(now_ms)
  pty_key "$run" Enter
  if ! await_reply answered "$stops" 120; then
    snap no-answer
    return 1
  fi
  sent=$(hooks_of UserPromptSubmit | sed -n "$((prompts + 1))p")
  record to_prompt_ms $(($(jq -r .t <<<"$sent") - t0))
  record to_stop_ms $(($(last_hook Stop | jq -r .t) - t0))
  record prompts_after_answer $(($(hook_count UserPromptSubmit) - prompts))
  got=$(jq -r .prompt <<<"$sent")
  record answer_prompt_matches "$([ "$got" = "$text" ] && echo yes || echo "no: ${got:0:120}")"
  record answer_tools "$(tools_since "$t0")"
  record files_after_answer "$(fruit_files "$nonce")"
  record file_content "$(cat "$work/$fruit-$nonce.txt" 2>/dev/null || echo none)"
  snap answered
  stop_claude term end || true
}

# cmd_ask <stopped|live>: the answer is the last option.
cmd_ask() {
  local path=$1 nonce="SB4$RANDOM$RANDOM"
  case $path in
  stopped | live) ;;
  *)
    echo "ask: unknown path '$path' (use stopped or live)" >&2
    return 2
    ;;
  esac
  new_run "ask-$path" deny
  start "$sb_prompt_arg"
  ask asking "$(fruit_prompt "$nonce")" 120 || return 1
  if ! sb_asked "$nonce"; then
    snap no-question
    return 1
  fi
  answer "$path" "$nonce" "$(jq -r -s 'last | .question' "$dir/questions.jsonl")" \
    "$(jq -r -s 'last | .options | last // "cherry"' "$dir/questions.jsonl")"
}

asked_or_stopped() { hook_count_above Stop 0 || used_ask_tool; }

cmd_choice() {
  local nonce="SB4C$RANDOM$RANDOM"
  new_run choice allow
  start "$sb_prompt_arg"
  send_prompt "$(fruit_prompt "$nonce")"
  if ! claude_until 120 asked_or_stopped >/dev/null; then
    record asked none
    snap none
    return 1
  fi
  ! used_ask_tool || pty_wait "$run" 5 "$ask_dialog_re" >/dev/null || true
  snap asked
  record used_ask_user_question "$(used_ask_tool && echo yes || echo no)"
  sb_asked "$nonce" || true
  ! hook_count_above Stop 0 || record asking_reply "$(last_hook Stop | jq -r .last_assistant_message)"
  stop_claude term end || true
}

# ask_tool_run <kind> <event> <hold> <nonce>: starts a run whose <event> hook
# answers AskUserQuestion after <hold> seconds, and asks for the fruit file
# through AskUserQuestion. Returns when the session calls the tool. Records
# ask_user_question=none and returns 1 if it does not call it within 60 s.
# A caller doesn't test its status, so that set -e still covers new_run.
ask_tool_run() {
  new_run "$1" allow "$2" "SB_HOLD=$3"
  start
  send_prompt "$(ask_tool_prompt "$4")"
  if ! claude_until 60 used_ask_tool >/dev/null; then
    record ask_user_question none
    return 1
  fi
}

cmd_native() {
  local event=$1 hold=${2:-0} nonce="SB4N$RANDOM$RANDOM"
  case $event in
  PermissionRequest | PreToolUse) ;;
  *)
    echo "native: unknown event '$event' (use PermissionRequest or PreToolUse)" >&2
    return 2
    ;;
  esac
  ask_tool_run "native-$event-$hold" "$event" "$hold" "$nonce"
  # With a hold, the snapshot comes halfway through it, while the dialog shows.
  sleep $((hold / 2 + 1))
  snap question
  await_reply answered 0 $((60 + hold)) || snap no-stop
  record tools "$(tools_since 0)"
  record permission_requests "$(hooks_of PermissionRequest | jq -r .tool_name | paste -sd ',' -)"
  record answers "$(question_answers)"
  record files "$(fruit_files "$nonce")"
  stop_claude term end || true
}

# cmd_pane: the PermissionRequest hook holds for 30 s while the dialog shows.
# The pane picks apple 3 s after the question opens. The hook answers cherry
# when its hold ends.
cmd_pane() {
  local nonce="SB4P$RANDOM$RANDOM" hold=30 asked_t
  ask_tool_run pane PermissionRequest "$hold" "$nonce"
  asked_t=$(ask_tool_hooks PreToolUse | head -1 | jq -r .t)
  sleep 3
  snap question
  pty_select "$run" "$ask_dialog_re" '^1\. apple' || record dialog_unanswered "$(pty_menu_cursor "$run" "$ask_dialog_re")"
  record picked_at_ms $(($(now_ms) - asked_t))
  await_reply answered 0 60 || true
  record hook_running_after_pick "$(pgrep -f answer-question.sh >/dev/null && echo yes || echo no)"
  record answers "$(question_answers)"
  record files "$(fruit_files "$nonce")"
  # The hold starts with PermissionRequest, about 20 ms after PreToolUse.
  sleep_until $((asked_t + (hold + 2) * 1000))
  record files_after_hold "$(fruit_files "$nonce")"
  record stops_after_hold "$(hook_count Stop)"
  snap after-hold
  stop_claude term end || true
}

# cmd_defer: the answer is the last option of the first question.
cmd_defer() {
  local nonce="SB4D$RANDOM$RANDOM" request
  new_run defer allow PermissionRequest SB_ANSWER=defer
  start
  ask asking "$(ask_tool_prompt "$nonce")" 120 || return 1
  request=$(ask_tool_hooks PermissionRequest | tail -1)
  if [ -z "$request" ]; then
    record permission_request none
    snap no-request
    return 1
  fi
  record question "$(jq -c '.tool_input.questions' <<<"$request")"
  record failure "$(hooks_of PostToolUseFailure | jq -c '{tool_name, error: (.error // "" | tostring | .[0:200])}')"
  asked "$nonce" "$(jq -r .t <<<"$request")"
  answer stopped "$nonce" "$(jq -r '.tool_input.questions[0].question' <<<"$request")" \
    "$(jq -r '.tool_input.questions[0].options | last | .label' <<<"$request")"
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() {
  jq -c '{t, event, tool: .tool_name, cmd: (.tool_input.command // "" | .[0:60]), prompt: (.prompt // "" | .[0:60]), type: .notification_type}' \
    "$runs/$1/hooks.jsonl"
}

cmd_teardown() { pty_server_stop; }

"cmd_$1" "${@:2}"
