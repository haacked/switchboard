#!/usr/bin/env bash
# Phase 0 test 5: shared MCP servers.
#
# Usage: t5-shared-mcp.sh <command> [args]
#   setup                     creates the work folder, starts the tmux server,
#                             and accepts workspace trust for the folder
#   parity <sse|http>         compares each shared server's tools, RSS, and
#                             connect ms with a stdio copy's, then calls one
#                             tool on each shared server
#   concurrent <sse|http>     12 clients call each shared server at once
#   session <stdio|sse|http>  a claude session calls one tool on each server
#   restart <sse|http>        the grafana server restarts between two calls
#   down <sse|http>           the grafana server starts after the session does
#   agent <sse|http>          a subagent calls a tool on the shared grafana
#                             server, and the run records which servers the
#                             subagent was offered
#   screen|hooks <run>        shows a run's pane or hook log
#   teardown                  stops the tmux server
#
# The servers have the names that the user's MCP configs give them. grafana,
# grafana-eu, and grafana-dev run mcp-grafana through the PostHog wrapper for
# the us, eu, and dev instances. posthog-db runs postgres-mcp against the
# local database. An sse or http run starts its own servers on 127.0.0.1 and
# stops them when it exits. The Grafana servers run with -disable-write.
# postgres-mcp has only stdio and SSE, so posthog-db uses SSE in http runs
# too. A session gets the servers through --mcp-config and
# --strict-mcp-config. Its settings allow every tool on them.
# T5_ROOT holds the work folder and one folder per run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pty.sh
. "$here/lib/pty.sh"
# shellcheck source=lib/claude.sh
. "$here/lib/claude.sh"

T5_ROOT="${T5_ROOT:?set T5_ROOT to a scratch folder}"
work="$T5_ROOT/work"
runs="$T5_ROOT/runs"
model="${T5_MODEL:-haiku}"
hook_events=(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
  SubagentStart SubagentStop Notification Stop SessionEnd)

grafana_wrapper="$HOME/dev/posthog/posthog/tools/infra-scripts/mcp/mcp-grafana-wrapper.sh"
servers=(grafana grafana-eu grafana-dev posthog-db)
# shfmt reads an unquoted key with a hyphen as arithmetic, so those keys are quoted.
declare -A region=(["grafana"]=us ["grafana-eu"]=eu ["grafana-dev"]=dev)
declare -A probe_tool=(["grafana"]=list_datasources ["grafana-eu"]=list_datasources
  ["grafana-dev"]=list_datasources ["posthog-db"]=list_schemas)
declare -A server_port server_pid

cmd_setup() {
  mkdir -p "$work" "$runs"
  [ -d "$work/.git" ] || git -C "$work" init -q
  pty_server_start
  run=setup-trust
  dir="$runs/$run"
  mkdir -p "$dir"
  accept_trust "$work"
  echo "root: $T5_ROOT"
}

# server_cmd <name> [args]: the shell command that starts the server.
server_cmd() {
  if [ "$1" = posthog-db ]; then
    echo "exec env DATABASE_URI=postgresql://posthog:posthog@localhost:5432/posthog $(sh_quote "$HOME/.local/bin/postgres-mcp") --access-mode=restricted ${*:2}"
  else
    echo "exec env MCP_GRAFANA_BIN=$(sh_quote "$HOME/go/bin/mcp-grafana") GRAFANA_REGION=${region[$1]} $(sh_quote "$grafana_wrapper") -disable-write ${*:2}"
  fi
}

# kind <name>: the transport that the shared server uses in this run.
kind() { if [ "$1" = posthog-db ]; then echo sse; else echo "$transport"; fi; }

url() { if [ "$(kind "$1")" = sse ]; then echo "http://127.0.0.1:${server_port[$1]}/sse"; else echo "http://127.0.0.1:${server_port[$1]}/mcp"; fi; }

tool_of() { echo "mcp__$1__${probe_tool[$1]}"; }

port_open() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# start_server <name>: starts the shared server and waits until its port
# accepts connections. A server that ran before gets the same port.
start_server() {
  local name=$1 cmd
  server_port[$name]=${server_port[$name]:-$(free_port)}
  if [ "$name" = posthog-db ]; then
    cmd=$(server_cmd "$name" --transport sse --sse-host 127.0.0.1 --sse-port "${server_port[$name]}")
  else
    cmd=$(server_cmd "$name" -t "${transport/http/streamable-http}" -address "127.0.0.1:${server_port[$name]}")
  fi
  sh -c "$cmd" >>"$dir/server-$name.log" 2>&1 &
  server_pid[$name]=$!
  wait_until 15 0.1 port_open "${server_port[$name]}" >/dev/null
}

# stop_server <name>: SIGTERM, then SIGKILL if the server still runs 5 s later.
stop_server() {
  local p=${server_pid[$1]:-}
  [ -n "$p" ] || return 0
  kill "$p" 2>/dev/null || true
  pty_wait_gone "$p" 5 >/dev/null || kill -9 "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  server_pid[$1]=
}

start_servers() {
  local name
  for name in "$@"; do start_server "$name"; done
}

on_exit() {
  local name
  pty_kill "$run"
  for name in "${servers[@]}"; do stop_server "$name"; done
}

rss_mb() { echo $(($(ps -o rss= -p "$1" | tr -d ' ') / 1024)); }

probe() { python3 -I "$here/lib/mcp-probe.py" "$@"; }

target() { echo "$(kind "$1"):$(url "$1")"; }

# new_run <kind> <transport> <allowed transport>...: sets run, dir, transport,
# settings, and uuid. Exits with status 2 unless the transport is allowed.
# The EXIT trap stops the run's servers and closes its pane.
new_run() {
  transport=$2
  if [[ " ${*:3} " != *" $transport "* ]]; then
    echo "$1: unknown transport '$transport' (use ${*:3})" >&2
    exit 2
  fi
  run="$1-$transport-$(date +%H%M%S)"
  dir="$runs/$run"
  settings="$dir/settings.json"
  uuid=$(uuidgen | tr 'A-Z' 'a-z')
  mkdir -p "$dir"
  trap on_exit EXIT
  write_settings | jq '.permissions = {allow: [$ARGS.positional[] | "mcp__" + .]}' --args "${servers[@]}" >"$settings"
  record claude_version "$(claude --version)"
  record session "$uuid"
}

# mcp_config: writes the run's --mcp-config file for the four servers.
mcp_config() {
  local name
  for name in "${servers[@]}"; do
    if [ "$transport" = stdio ]; then
      jq -n --arg n "$name" --arg c "$(server_cmd "$name")" '{($n): {type: "stdio", command: "sh", args: ["-c", $c]}}'
    else
      jq -n --arg n "$name" --arg t "$(kind "$name")" --arg u "$(url "$name")" '{($n): {type: $t, url: $u}}'
    fi
  done | jq -s '{mcpServers: add}' >"$dir/mcp.json"
}

# start [claude args]: opens the pane and starts claude with the run's servers.
start() {
  mcp_config
  pty_server_start
  pty_new "$run" "$work"
  record start_ms "$(start_claude --session-id "$uuid" --mcp-config "$dir/mcp.json" --strict-mcp-config "$@")"
}

tool_prompt() {
  local name tools=()
  for name in "$@"; do tools+=("$(tool_of "$name")"); done
  echo "Call each of these MCP tools once, in this order, with no arguments: ${tools[*]}. Then reply with only the word DONE."
}

# calls <label> <ms> <agent> <name>...: records <label>_<name> for each
# server's probe tool calls that started after <ms>. <agent> is main for the
# session's own calls, or sub for a subagent's. The value is the number of
# calls and the first call's outcome: "ok <ms> ms: <result start>",
# "failed: <error>", or "running". It is "none" without a call. Returns 1
# unless every server's first call is ok.
calls() {
  local label=$1 t0=$2 who=$3 name line status=0
  shift 3
  for name in "$@"; do
    line=$(jq -R -s -r --arg tool "$(tool_of "$name")" --argjson t0 "$t0" --arg who "$who" '
      [split("\n")[] | fromjson? // empty | select(.tool_name == $tool and (.agent_id != null) == ($who == "sub"))]
      | map(select(.event == "PreToolUse" and .t > $t0)) as $pres
      | if ($pres | length) == 0 then "none" else
          $pres[0] as $pre
          | (map(select(.tool_use_id == $pre.tool_use_id and (.event == "PostToolUse" or .event == "PostToolUseFailure"))) | first) as $post
          | "\($pres | length) call(s), first " + (
              if $post == null then "running"
              elif $post.event == "PostToolUseFailure" then "failed: \($post.error // "" | tostring | .[0:160])"
              else "ok \($post.t - $pre.t) ms: \($post.tool_response | tostring | .[0:80])" end)
        end' "$dir/hooks.jsonl")
    record "${label}_$name" "$line"
    [[ $line == *"first ok "* ]] || status=1
  done
  return "$status"
}

# probe_turn <label> <name>...: asks the session to call each server's probe
# tool, then runs calls. Returns 1 unless every first call is ok.
probe_turn() {
  local t0
  t0=$(now_ms)
  ask "$1" "$(tool_prompt "${@:2}")" 180 || true
  calls "$1" "$t0" main "${@:2}"
}

# mcp_children: records claude's RSS and the count and RSS of the MCP server
# processes below claude.
mcp_children() {
  local tree cpid n mb
  cpid=$(claude_pid)
  tree=$(proc_tree "$cpid")
  record claude_rss_mb "$(rss_mb "$cpid")"
  read -r n mb < <(awk '/mcp-grafana|postgres-mcp/ {n++; s += $4} END {print n + 0, int(s / 1024)}' <<<"$tree")
  record mcp_children "$n"
  record mcp_children_rss_mb "$mb"
}

cmd_parity() {
  local name stdio shared
  new_run parity "$1" sse http
  start_servers "${servers[@]}"
  for name in "${servers[@]}"; do
    stdio=$(probe "stdio:$(server_cmd "$name")" tools)
    shared=$(probe "$(target "$name")" tools)
    record "${name}_tools" "$(jq -nr --argjson a "$stdio" --argjson b "$shared" '"stdio \($a.tools | length) shared \($b.tools | length) same \(if $a.tools == $b.tools then "yes" else "no" end)"')"
    record "${name}_rss_mb" "stdio $(($(jq .rss_kb <<<"$stdio") / 1024)) shared $(rss_mb "${server_pid[$name]}")"
    record "${name}_connect_ms" "stdio $(jq .connect_ms <<<"$stdio") shared $(jq .connect_ms <<<"$shared")"
    record "${name}_call" "$(probe "$(target "$name")" call "${probe_tool[$name]}" | jq -c '{ms, isError, text: .text[0:60]}')"
  done
}

cmd_concurrent() {
  local name
  new_run concurrent "$1" sse http
  start_servers "${servers[@]}"
  for name in "${servers[@]}"; do
    record "${name}_parallel" "$(probe "$(target "$name")" parallel 12 "${probe_tool[$name]}")"
    record "${name}_rss_mb_after" "$(rss_mb "${server_pid[$name]}")"
  done
}

cmd_session() {
  new_run session "$1" stdio sse http
  [ "$transport" = stdio ] || start_servers "${servers[@]}"
  start
  probe_turn call "${servers[@]}" || true
  mcp_children
  snap tools
  stop_claude term end || true
}

# cmd_restart: one call, a restart of the grafana server on the same port, and
# a retry if the call after the restart fails.
cmd_restart() {
  new_run restart "$1" sse http
  start_servers "${servers[@]}"
  start
  probe_turn before grafana || true
  stop_server grafana
  start_server grafana
  record restarted_rss_mb "$(rss_mb "${server_pid[grafana]}")"
  probe_turn after grafana || probe_turn retry grafana || true
  snap after
  stop_claude term end || true
}

# cmd_down: the session starts while the grafana server is down. The server
# starts after the first call.
cmd_down() {
  new_run down "$1" sse http
  server_port[grafana]=$(free_port)
  start_servers grafana-eu grafana-dev posthog-db
  start
  snap started
  probe_turn down grafana || true
  start_server grafana
  probe_turn up grafana || true
  snap up
  stop_claude term end || true
}

# offered_servers: the MCP servers whose tools the last subagent's transcript
# lists, which Claude Code offers it at its start.
offered_servers() {
  local file
  file=$(ls "$(dirname "$(transcript)")/$uuid/subagents/agent-"*.jsonl 2>/dev/null | head -1)
  [ -n "$file" ] || return 0
  grep -o 'mcp__[a-z0-9-]*__' "$file" | sort -u | sed 's/^mcp__//; s/__$//' | paste -sd ',' -
}

cmd_agent() {
  local t0 agents
  new_run agent "$1" sse http
  start_servers "${servers[@]}"
  agents=$(jq -nc '{"grafana-reader": {
    description: "Lists the datasources of the us Grafana instance.",
    prompt: "Call the mcp__grafana__list_datasources tool once with no arguments, and reply with how many datasources it returned.",
    mcpServers: ["grafana"]}}')
  start --agents "$(sh_quote "$agents")"
  t0=$(now_ms)
  ask launch "Use the grafana-reader agent to count the Grafana datasources. Then reply with the number it reports." 120 || true
  record reported_ms "$(wait_until 180 0.5 subagent_reported)"
  record subagents "$(hooks_of SubagentStart | jq -r .agent_type | paste -sd ',' -)"
  record agent_tool_calls "$(hooks_of PreToolUse | jq -r --argjson t0 "$t0" 'select(.t > $t0 and .agent_id) | .tool_name' | paste -sd ',' -)"
  record offered_servers "$(offered_servers)"
  calls call "$t0" sub grafana || true
  record final_reply "$(last_hook Stop | jq -r .last_assistant_message)"
  mcp_children
  snap reported
  stop_claude term end || true
}

cmd_screen() { pty_screen "$1" | grep -v '^[[:space:]]*$' || true; }

cmd_hooks() {
  jq -c '{t, event, tool: .tool_name, agent: .agent_id, prompt: (.prompt // "" | .[0:60]), error: (.error // "" | tostring | .[0:80])}' \
    "$runs/$1/hooks.jsonl"
}

cmd_teardown() { pty_server_stop; }

"cmd_$1" "${@:2}"
