# Switchboard

A macOS app that runs 20 to 100 Claude Code sessions at once and shows which ones need you.

**Status:** v0.1, a first version to try. It runs sessions, shows which need you, and stops idle ones. Groups, waits that resolve themselves, GitHub and CI tracking, and chats come later. The design plan is in `~/dev/haacked/notes/Dev/repositories/haacked/switchboard/plans/switchboard.md`, and v0.1's scope is in `plans/v0.1-app.md` next to it.

Each session is a folder, or a new git worktree, with the real Claude Code terminal and a shell. A background service, `sbd`, stops the `claude` process of a session that sits idle, and resumes it when you open the session or send it a message. A stopped session costs a few MB instead of 300 to 500.

## Install

```
bin/install
open ~/Applications/Switchboard.app
```

`bin/install` builds the app, copies it to `~/Applications`, links `sb` into `~/.local/bin`, and starts `sbd` as a launchd agent that runs at login. `sb service uninstall` removes the agent.

It needs macOS 14 or later, the Xcode Command Line Tools (Swift 6.4), `tmux` (`brew install tmux`), and Claude Code signed in with your subscription. Sessions run the unmodified `claude` CLI. Switchboard never calls the Claude API.

## Use

In the app, press ⌘N to start a session. Pick a folder, or a repo plus a branch to get a new worktree in `~/dev/worktrees/<repo>/<branch>`, and give it a first prompt. The sidebar sorts sessions into Needs you, Claude can continue, Waiting, Working, Done, and Stale, with a reason for each. Select a session to get its Claude terminal and its shell side by side. ⌘J jumps to the next session that needs you. The menu bar shows how many sessions need you, and a notification fires when one starts to.

Everything in the app also works from `sb`, and every command takes `--json`:

```
sb new ~/dev/myrepo --branch haacked/fix-thing --prompt "Fix the flaky test in foo_test.py"
sb ls
sb send <session> "Yes, push it."
sb attach <session>          # this terminal shows the Claude pane; --shell for the shell
sb wait <session> CI on #1204
sb done <session>
sb events --follow
```

A session is an id, a unique id prefix, or a unique name. `sb send` pastes into a live idle session, queues the message while a turn runs, and resumes a stopped session with the message as its first prompt.

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

## How it works

- `sbd` keeps sessions and their event log in SQLite in `~/.sb`. It answers `sb` and the app on `~/.sb/sbd.sock`.
- A private tmux server on `~/.sb/tmux.sock` holds every terminal, so the app can quit without touching a session. The Claude pane runs only `claude`. When `claude` exits, the pane keeps its last screen until `sbd` starts it again.
- Every session gets Claude Code hooks that run `sb hook`, which forwards each event to `sbd`. The state and the reason come from those events, following the rules of the `/sessions` skill.
- `sbd` stops a session's `claude` with SIGTERM when the session has been idle for `idleStopSeconds`, has no open prompt, no background job or subagent, and no terminal showing it.

## Develop

```
swift build
bin/test        # unit tests, and integration tests that run a private sbd against a stub claude
bin/bundle      # build/Switchboard.app
```

`spikes/phase0/` holds the Phase 0 tests that measured the Claude Code behaviors this relies on.
