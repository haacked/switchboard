# Switchboard

A macOS app that runs 20 to 100 Claude Code sessions at once and shows which ones need you.

**Status:** not yet functional. Only the design plan exists.

Each session is a git worktree with the real Claude Code terminal and a shell. A background service stops the `claude` process of any session that isn't working. It resumes the process when you open the session or when something the session waits on happens. That keeps 100 sessions within about 5 GB, where keeping every process alive would take about 55 GB.

Sessions group themselves. Each session shows what it waits on: CI, a reviewer, the merge queue, a deploy, or another session. A session can start other sessions and follow-ups, which join its group. A CLI (`sb`) and an MCP server can do everything the app can.

## How it will work

- `sbd`, a launchd agent, owns session state, the terminals, the Claude Code hooks, and one shared poller for GitHub, Trunk, Depot, and deploy status.
- The app, `sb`, and the MCP server all talk to `sbd`, so the app can quit without stopping a session.
- Sessions run the unmodified `claude` CLI, signed in with your own Claude subscription. Switchboard never calls the Claude API with that login.

## Requirements

- macOS, with Xcode or its Command Line Tools (planned against Swift 6.4).
- Claude Code (`claude`), signed in with a Claude subscription.
- `git`, and `gh` signed in to GitHub.
- Optional: `trunk`, signed in with `trunk login`, for exact merge queue state. `depot`, for Depot CI logs and retries.
