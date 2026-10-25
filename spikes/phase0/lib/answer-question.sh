#!/bin/sh
# A PermissionRequest or PreToolUse command hook for Phase 0 test 4. It allows
# an AskUserQuestion call and adds the answers to its input. Each question's
# answer is its last option's label. With SB_ANSWER=defer, a PermissionRequest
# hook denies the call instead, with a message that says the answer arrives
# later. SB_HOLD sets the seconds it waits before it answers. It prints nothing
# for other tools, which leaves the decision to Claude Code.
input=$(cat)
[ "$(printf '%s' "$input" | jq -r .tool_name)" = AskUserQuestion ] || exit 0
sleep "${SB_HOLD:-0}"
printf '%s' "$input" | jq -c --arg mode "${SB_ANSWER:-now}" \
  --arg later "Switchboard recorded your question and shows it to the user. End your turn now. The answer arrives as your next message." '
  (.tool_input + {answers: (.tool_input.questions | map({(.question): (.options | last | .label)}) | add)}) as $input
  | {hookSpecificOutput: ({hookEventName: .hook_event_name} + if .hook_event_name == "PreToolUse"
      then {permissionDecision: "allow", updatedInput: $input}
      elif $mode == "defer" then {decision: {behavior: "deny", message: $later}}
      else {decision: {behavior: "allow", updatedInput: $input}} end)}'
