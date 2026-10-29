# Switchboard

A macOS app that runs 20 to 100 Claude Code sessions at once and shows which ones need you.

**Status:** v0.1, a first version to try. It runs sessions, shows which need you, and stops idle ones. Waits on a time or another session resolve themselves. Waits on PRs and deploys wait for the GitHub, CI, and deploy pollers, which come later with groups and chats. The design plan is in `~/dev/haacked/notes/Dev/repositories/haacked/switchboard/plans/switchboard.md`, and v0.1's scope is in `plans/v0.1-app.md` next to it.

Each session is a folder, or a new git worktree, with the real Claude Code terminal and a shell. A background service, `sbd`, stops the `claude` process of a session that sits idle, and resumes it when you open the session or send it a message. A stopped session costs a few MB instead of 300 to 500.

## Install

```
bin/install
open ~/Applications/Switchboard.app
```

`bin/install` builds the app, copies it to `~/Applications`, links `sb` into `~/.local/bin`, and starts `sbd` as a launchd agent that runs at login. `sb service uninstall` removes the agent.

It needs macOS 14 or later, the Xcode Command Line Tools (Swift 6.4), `tmux` (`brew install tmux`), and Claude Code signed in with your subscription. Sessions run the unmodified `claude` CLI. Switchboard never calls the Claude API.

## Use

In the app, press ⌘N to start a session. Pick a folder, or a repo plus a branch to get a new worktree in `~/dev/worktrees/<repo>/<branch>`, and give it a first prompt. The sidebar sorts sessions into Needs you, Claude can continue, Waiting, Working, Done, and Stale, with a reason for each. Select a session to get its Claude terminal and its shell side by side. With no session selected, the Queue lists the sessions that need you, oldest first, and ⌘J moves to the next one. A permission prompt or an `AskUserQuestion` question shows there, and above the session's terminals, as a card that you answer without opening the session. With a session selected, ⌘J jumps to the next session that needs you. The menu bar shows how many sessions need you, and a notification fires when one starts to.

Everything in the app also works from `sb`, and every command takes `--json`:

```
sb new ~/dev/myrepo --branch haacked/fix-thing --prompt "Fix the flaky test in foo_test.py"
sb ls
sb send <session> "Yes, push it."
sb attach <session>          # this terminal shows the Claude pane; --shell for the shell
sb wait <session> Alex said he would reply tomorrow
sb wait <session> --kind date --until 2h --note "check the dashboard"
sb wait <session> --kind session --target flag-cache
sb wait <session> --clear
sb note <session> Stacked on #1190
sb done <session>
sb events --follow
sb cards                     # open permission prompts and questions
sb allow <session>
sb deny <session> Use the Makefile instead.
sb answer <session> cherry "red, blue"
sb mcp                       # the shared MCP servers
```

A session is an id, a unique id prefix, or a unique name. `sb send` pastes into a live idle session, queues the message while a turn runs, and resumes a stopped session with the message as its first prompt. The paste also submits anything you typed but didn't send in that session's Claude terminal.

A wait says what a session waits on. Its kind is `ci`, `review`, `bot-review`, `approval`, `queue`, `merge`, or `deploy` for a PR, `session` for another session, `date` for a time, or `manual`. `sb wait <session> <note>` sets a manual wait, which stays until you clear it, or until its `--until` recheck time moves the session back to Needs you. sbd resolves `date`, `session`, and `manual` waits itself. The PR and deploy kinds wait for the pollers, or for `sb wait <session> --resolve "<what happened>"`. A resolved wait resumes the session with a message that says what happened. With `--then notify`, it moves the session to Needs you instead. A session with an open wait stops 2 s after its turn ends. Inside a session, `sb wait --kind ci` needs no session and waits on the session's own PR. `sb help` lists the flags.

A card waits until you answer it from `sb` or the app, or answer Claude Code's own dialog in the terminal. `sb deny` with a message lets Claude read it and go on. Without one, the turn stops, as No does in the terminal. `sb answer` takes one answer per question, in order. A multi-select answer separates its labels with commas, and text that names no option is a typed answer. A question that stays open for `idleStopSeconds` while no terminal shows its session is deferred: Claude ends its turn, `sbd` stops `claude` on its normal schedule, and your answer resumes the session. `sb cards` prints the whole tool call that `sb allow` approves. `sb allow`, `deny`, and `answer` refuse to run when `CLAUDECODE` is set, as it is for every command that Claude runs. That keeps a session that follows injected instructions from approving tool calls with `sb`, though a process that clears the variable gets past the check.

## Settings

`~/.sb/config.json` holds optional settings. Restart `sbd` after a change (`sb service install` restarts it).

```json
{
  "idleStopSeconds": 900,
  "model": "sonnet",
  "worktreeRoot": "~/dev/worktrees",
  "claudeArgs": ["--permission-mode", "auto"],
  "env": {"CLAUDE_CONFIG_DIR": "~/.claude-personal"}
}
```

`env` sets variables in both panes, so `CLAUDE_CONFIG_DIR` there picks the Claude account for every session. `SB_HOME` moves the whole state folder, which is how the tests run a private `sbd`.

### Shared MCP servers

`mcpServers` lists local MCP servers that `sbd` runs once on 127.0.0.1 and shares with every session, instead of each session starting its own copies:

```json
{
  "mcpServers": {
    "grafana": {
      "type": "http",
      "command": "~/dev/posthog/posthog/tools/infra-scripts/mcp/mcp-grafana-wrapper.sh",
      "args": ["-t", "streamable-http", "-address", "127.0.0.1:{port}", "-disable-write"],
      "env": {"GRAFANA_REGION": "us", "MCP_GRAFANA_BIN": "~/go/bin/mcp-grafana"}
    },
    "posthog-db": {
      "type": "sse",
      "command": "~/.local/bin/postgres-mcp",
      "args": ["--access-mode=restricted", "--transport", "sse", "--sse-host", "127.0.0.1", "--sse-port", "{port}"],
      "env": {"DATABASE_URI": "postgresql://posthog:posthog@localhost:5432/posthog"}
    }
  }
}
```

- `type` is `http` (streamable HTTP) or `sse`. `sbd` replaces `{port}` in `command`, `args`, and `env` with a port that it picks and keeps, or with `port` when you set one. It picks a new port when another program took the old one while the server wasn't running. `path` overrides the URL path, which is `/mcp` for `http` and `/sse` for `sse`.
- tmux starts the command with your shell, so it gets the PATH that your shell sets for a non-interactive command, such as in `~/.zshenv`. A full path doesn't depend on that.
- Every session gets `--mcp-config ~/.sb/mcp-config.json`. A server there replaces the server with the same name in your Claude config, and the session keeps its other servers, such as remote ones, the claude.ai connectors, and a project's `.mcp.json` servers.
- `sbd` starts the servers before any session, and starts a server again on the same port when it exits. A server that keeps exiting waits longer each time, up to a minute. `sb mcp` lists the servers, and for one that exited, its exit status and last output.
- A session connects to its MCP servers when `claude` starts. A session that started while a server was down lacks that server until it stops and resumes.
- The servers have no authentication. Any local process can call them, with whatever token the server holds.

## How it works

- `sbd` keeps sessions and their event log in SQLite in `~/.sb`. It answers `sb` and the app on `~/.sb/sbd.sock`.
- A private tmux server on `~/.sb/tmux.sock` holds every terminal and every shared MCP server, so the app can quit, and `sbd` can restart, without touching a session. The Claude pane runs only `claude`. When `claude` exits, the pane keeps its last screen until `sbd` starts it again.
- Every session gets Claude Code hooks that run `sb hook`, which forwards each event to `sbd`. The state and the reason come from those events, following the rules of the `/sessions` skill.
- `sb send` pastes into a live session with bracketed paste, so Claude Code treats the message as typed by you. A write to Claude Code's inbox socket would reach Claude as a message from another Claude session, which Claude doesn't take as your approval.
- `sbd` stops a session's `claude` with SIGTERM when the session has been idle for `idleStopSeconds` (2 s with an open wait), has no open prompt, no background job or subagent, and no terminal showing it.
- For a permission prompt or a question, `sbd` holds the `PermissionRequest` hook open for up to a day and answers it from the card. When the terminal answers first, `sbd` removes the card.

## Develop

```
swift build
bin/test        # unit tests, and integration tests that run a private sbd against a stub claude
bin/bundle      # build/Switchboard.app
```

`spikes/phase0/` holds the Phase 0 tests that measured the Claude Code behaviors this relies on.

`SwitchboardCore/Deploys.swift` reads PostHog's deploy signals for the deploy poller that comes later: the deploy comment on PostHog/posthog PRs, the PostHog/charts state files, and the charts deploy runs' sync jobs.
