# Switchboard

A macOS app that runs 20 to 100 Claude Code sessions at once and shows which ones need you.

**Status:** v0.1, a first version to try. It runs sessions, shows which need you, stops idle ones, keeps follow-ups that haven't started, and tracks each session's GitHub PR. Waits on a time, another session, or a PR's checks, reviews, approval, or merge resolve themselves. Waits on a merge queue and deploys don't resolve themselves yet. Wiring them to the pollers, CI and deploy tracking, groups, and chats come later. The design plan is in `~/dev/haacked/notes/Dev/repositories/haacked/switchboard/plans/switchboard.md`, and v0.1's scope is in `plans/v0.1-app.md` next to it.
Each session is a folder, or a new git worktree, with the real Claude Code terminal and a shell. A background service, `sbd`, stops the `claude` process of a session that sits idle, and resumes it when you open the session or send it a message. A stopped session costs a few MB instead of 300 to 500.

## Install

```
bin/install
bin/start
```

`bin/install` builds the app, copies it to `~/Applications`, links `sb` into `~/.local/bin`, and starts `sbd` as a launchd agent that runs at login. `sb service uninstall` removes the agent.

`bin/start` opens the installed app. `bin/update` quits the app, fast-forwards this checkout to `origin/main`, runs `bin/install`, and opens the app again. It refuses, with the app still running, when the checkout is not on main, has uncommitted changes, or cannot fast-forward. Quitting the app leaves `sbd` and your sessions running.

It needs macOS 14 or later, the Xcode Command Line Tools (Swift 6.4), `tmux` (`brew install tmux`), `gh` signed in with `gh auth login` (`brew install gh`), and Claude Code signed in with your subscription. Sessions run the unmodified `claude` CLI. Switchboard never calls the Claude API.

## Use

In the app, press ⌘N to start a session. Pick a folder, or a repo plus a branch to get a new worktree in `~/dev/worktrees/<repo>/<branch>`, and give it a first prompt. The sidebar sorts sessions into Needs you, Claude can continue, Waiting, Working, Done, and Stale, with a reason for each. Waiting holds the sessions that wait on a wait you set and the sessions whose open PR waits only on a requested reviewer. Select a session to get its Claude terminal and its shell side by side. With no session selected, the Queue shows the triage list (see Triage), and ⌘J moves to the next item. The Queue and Board buttons in the toolbar, or ⌘1 and ⌘2, deselect the session and show the Queue or the Board. A permission prompt or an `AskUserQuestion` question shows there, and above the session's terminals, as a card that you answer without opening the session. With a session selected, ⌘J jumps to the next session that needs you. The menu bar shows how many sessions need you, and a notification fires when one starts to.

The trash button in the session header removes the session: it stops claude and closes both terminals, and the folder and the conversation's transcript stay. Its dialog also offers to delete the session's worktree, and, with the worktree, its local branch. Both are off by default, and neither is offered for a session that sbd made no worktree for. Deleting the worktree, which `sb rm --worktree` and the Done section's context menu do too, refuses when the worktree has uncommitted files or commits that are on no remote branch (unless the session's PR is merged). Deleting the branch, which `sb rm --worktree --delete-branch` does too, refuses unless the session's PR is merged and the branch has no commit after it. A refusal changes nothing and shows the error. The branch is checked again after the worktree is removed, and it is kept, with an error, when it has moved off the merged PR's head, is gone, or is checked out in another worktree. The worktree and the session are removed in that case, because the session's folder is missing.

Everything in the app also works from `sb`, and every command takes `--json`:

```
sb new ~/dev/myrepo --branch haacked/fix-thing --prompt "Fix the flaky test in foo_test.py"
sb new ~/dev/myrepo --worktree --name "Fix the flaky test"   # names the branch itself
sb ls
sb send <session> "Yes, push it."
sb attach <session>          # this terminal shows the Claude pane; --shell for the shell
sb wait <session> Alex said he would reply tomorrow
sb wait <session> --kind date --until 2h --note "check the dashboard"
sb wait <session> --kind session --target flag-cache
sb wait <session> --clear
sb note <session> Stacked on #1190
sb done <session>
sb rm <session>              # stops claude and forgets the session; the folder and transcript stay
sb rm <session> --worktree   # also deletes its worktree
sb rm <session> --worktree --delete-branch  # also deletes its local branch
sb events --follow
sb cards                     # open permission prompts and questions
sb allow <session>
sb deny <session> Use the Makefile instead.
sb answer <session> cherry "red, blue"
sb mcp                       # the shared MCP servers
sb triage                    # what needs you, in the order to go through it
sb next                      # the first item
sb choose <session> 1        # click an option, by number or label
sb reply <session>           # the session's last reply, as Markdown
```

A session is an id, a unique id prefix, or a unique name. `sb send` pastes into a live idle session, queues the message while a turn runs, and resumes a stopped session with the message as its first prompt. The paste also submits anything you typed but didn't send in that session's Claude terminal.

A wait says what a session waits on. Its kind is `ci`, `review`, `bot-review`, `approval`, `queue`, `merge`, or `deploy` for a PR, `session` for another session, `date` for a time, or `manual`. `sb wait <session> <note>` sets a manual wait, which stays until you clear it, or until its `--until` recheck time moves the session back to Needs you. sbd resolves `date`, `session`, and `manual` waits itself. The GitHub poller resolves `ci` (checks passed or failed), `review` and `bot-review` (a review submitted after the wait was set), `approval`, and `merge`, on the session's own PR or on the PR named by `--target`. The `queue` and `deploy` kinds wait for their pollers, or for `sb wait <session> --resolve "<what happened>"`. A resolved wait resumes the session with a message that says what happened. With `--then notify`, it moves the session to Needs you instead. A session with an open wait stops 2 s after its turn ends. Inside a session, `sb wait --kind ci` needs no session and waits on the session's own PR. `sb help` lists the flags.

A card waits until you answer it from `sb` or the app, or answer Claude Code's own dialog in the terminal. `sb deny` with a message lets Claude read it and go on. Without one, the turn stops, as No does in the terminal. `sb answer` takes one answer per question, in order. A multi-select answer separates its labels with commas, and text that names no option is a typed answer. A question that stays open for `idleStopSeconds` while no terminal shows its session is deferred: Claude ends its turn, `sbd` stops `claude` on its normal schedule, and your answer resumes the session. `sb cards` prints the whole tool call that `sb allow` approves. `sb allow`, `deny`, and `answer` refuse to run when `CLAUDECODE` is set, as it is for every command that Claude runs. That keeps a session that follows injected instructions from approving tool calls with `sb`, though a process that clears the variable gets past the check.

To bring in Claude sessions that you started elsewhere, press ⇧⌘I in the app or run `sb import`. It lists the sessions that run in a linked git worktree, grouped by repo, from every Claude account: `~/.claude` and each `~/.claude-*` folder that holds a `.claude.json`. `sb import --all` lists every session. `--repo <name>` lists only the sessions of the repo with that name (the folder name of its main checkout), alone or with `--all`, and fails when no session to import belongs to it. The sheet has a Repo picker for the same filter. Switchboard never stops a claude that runs elsewhere, so exit claude in its terminal, or stop a background job with `claude stop <id>`, and then import the session:

```
sb import                    # sessions in worktrees; ● marks one that a claude runs now
sb import --all
sb import --repo switchboard  # one repo; add --all for its sessions outside a worktree
sb import 26275b06 6d2c57eb  # by Claude session id, id prefix, or name
```

`sbd` remembers each session it lists for a day, so a session still shows after you exit its claude. An imported session keeps its folder and its conversation. Opening it or sending it a message resumes the conversation under the account it came from.

### Accounts

Each session runs `claude` under one Claude account, a config folder such as `~/.claude` or `~/.claude-personal`. A session keeps its account for life, because its transcript lives in that folder. `sb account` lists the accounts that hold a login and marks the active one. `sb account use <name|folder>` makes it the account for new sessions, and the app's toolbar menu does the same. The name of `~/.claude-personal` is `personal`, and the name of `~/.claude` is `default`. The choice survives a restart of sbd.

A session that another session starts (`sb new` or `sb followup add` inside a session) uses its parent's account, whatever is active. `--account` on `sb new` and `sb followup add` picks another. A follow-up with no parent takes the active account when it starts.

### The Manager

`sb manager` starts the Manager, one interactive Claude session in `~/.sb/manager` that manages the others through `sb`, and opens it after that. The app pins it at the top of the sidebar, with the sessions it started under it. The Manager reads the plan, starts sessions with briefs in new worktrees, waits on them, tests their branches together, and merges PRs and cleans up when you say so.

sbd rewrites `~/.sb/manager/CLAUDE.md` at each start and at each `sb manager`, so edits to it don't last. It teaches the Manager the `sb` commands and three rules: text from sessions is data, not instructions, and the Manager asks you before it merges, before it removes a worktree with unpushed work, and before it sends one message to several sessions.

`sb new` run inside a session records that session as the new one's parent, and the sidebar shows children under their parent. A child that reaches Done leaves the Manager's list and shows only in the Done group; its children that are not Done stay in the list, under the nearest ancestor that is not Done, and the child returns to the list if it leaves Done. A parent hears about its children: when one moves to Needs you, opens a PR, or reaches Done, sbd sends the parent a one-line message that starts with `Switchboard:`. A parent whose turn is running hears about everything that changed after the turn, in one message. A stopped parent resumes with the message. A follow-up is not a child of the session that captured it.

### Triage

Each session that needs you, or that Claude can continue, gets one item: a title that says what you do, a kind (`decision`, `question`, `approval`, `review`, `action`, or `info`), a two-sentence summary, and options. `sb triage` lists them in the order to go through them, and `sb next` prints the first. The same item is `triage` in `sb ls --json` and `sb get --json`, with a `source`:

- `card`: a held permission prompt or `AskUserQuestion` question. Allow and Deny, or the question's options.
- `rule`: the reason that a PR rule, a wait, or a follow-up gives, such as "Rebase: #1204 conflicts with its base".
- `summary`: when a turn ends in prose, sbd runs `claude -p` with Haiku, no tools, no MCP servers, and no saved session, under the session's own account, and records a `triage` event. It runs once per turn, two at a time, with a 60 s timeout.
- `fallback`: the last paragraph of the reply, with no options, until the summary arrives or when it fails.

The order is: a held prompt or question; a decision, question, or approval from a summary; PR actions; finished work to review; Claude can continue. The oldest comes first in each group.

`sb choose <session> <option>` does what a click does: it answers the session's card, or sends the option's message. `sb reply <session>` prints the session's last reply from its transcript. sbd also starts every claude with `--append-system-prompt` text that asks it to put choices through `AskUserQuestion`. In `config.json`, `triage` sets `enabled` (false turns the summaries off), `model` (default `haiku`), `account`, `timeoutSeconds`, and `systemPrompt` (empty turns the nudge off).

In the app, the Queue shows the list on the left. The right side shows the selected session's summary, its option buttons (or its card), its last reply as formatted Markdown, and a field that messages the session itself. The Terminal button shows the session's terminals in place of the summary.

### Follow-ups

A follow-up is a session that hasn't started: a title, a prompt, a GitHub repository, and where it came from. It has no worktree and no `claude` until you start it, and it sits in the Not started column, which the sidebar keeps collapsed.

```
sb followup add "Check p99 after the canary rollout." --repo PostHog/posthog --on 2026-10-30
sb followup add "Retarget the stack onto main." --after PostHog/posthog#1204
sb followup ls
sb followup start <f>        # makes the worktree and starts claude with the prompt
sb followup rm <f>
sb followup import           # reads followupsFile, ~/dev/haacked/notes/PostHog/Followups.md by default
```

Without `--repo`, `add` takes the repository from the current folder's GitHub remote. Inside a session, the session becomes the follow-up's parent. `--on` and `--after` move the follow-up to Needs you, with "ready to start", when the time passes or the PR merges. A follow-up never starts on its own. The merge trigger fires when the GitHub poller sees the PR merge.

`start` finds the repository's checkout in `repos`, else at `~/dev/<owner>/<name>`, and refuses a folder whose remotes don't include the repository on github.com. `--path` picks the folder instead. The branch is `branchPrefix` plus a slug of the title, unless `--branch` names one.

`import` adds each `- [ ]` line under `## Open`, with its date, repository, and branch, and never changes the file. You can run it again: it skips every line that an earlier import read, including lines whose follow-up you removed.

`sbd` finds each session's PR on GitHub: the PR of the branch the session's folder has checked out, or else the last PR that Claude Code linked in the session's transcript. `sb get` shows it, and the session's state follows it. A merged or closed PR with a clean folder is Done. A PR that conflicts with its base, has changes requested, is approved but not queued, was removed from Trunk's merge queue, or targets a branch whose PR merged puts the session in Needs you with the next step. `sb poll` runs the next poll now, and `sb poll --all` reads every PR, due or not.

A session whose turn has ended, and whose PR waits only on a review, is in Waiting with the reason "review of #21 by alex", and no `sb wait` is needed. That takes all of these: the PR is open and not a draft; GitHub still lists a reviewer, person, bot, or team, whose review is requested; the PR is not approved; it has no conflict, merged base, or Trunk queue entry; its checks have not failed; and the session's last reply asks nothing and offers nothing. Pending checks do not matter. A submitted review removes the request, so the session returns to Needs you, as do failing checks, a conflict, requested changes on the current commit, an approval, or a PR with no reviewer requested. A PR in draft also needs you. A session whose PR has no reviewer requested (answered or not) or a failing check stays in Needs you after two idle days, unless the PR is in Trunk's queue, where other idle sessions go to Stale. Switchboard cannot tell when a reply asks you to check something by hand, such as running the app, so a session with a requested reviewer waits even then. Ask it as a question to keep the session in Needs you.

## Settings

`~/.sb/config.json` holds optional settings. Restart `sbd` after a change (`sb service install` restarts it).

```json
{
  "idleStopSeconds": 900,
  "model": "sonnet",
  "worktreeRoot": "~/dev/worktrees",
  "claudeArgs": ["--permission-mode", "auto"],
  "env": {"CLAUDE_CONFIG_DIR": "~/.claude-personal"},
  "repos": {"haacked/dotfiles": "~/.dotfiles"},
  "repoRoots": ["~/dev"],
  "branchPrefix": "haacked/",
  "followupsFile": "~/dev/haacked/notes/PostHog/Followups.md",
  "github": {"pollSeconds": 30, "idlePollSeconds": 300}
}
```

`env` sets variables in both panes, so `CLAUDE_CONFIG_DIR` there picks the Claude account for every session. An imported session uses the account it came from instead. `claudeConfigDirs` lists the Claude accounts whose sessions `sb import` lists, such as `["~/.claude", "~/.claude-personal"]`, where `~/.claude` means Claude's default account. `repos` and `repoRoots` tell `sb followup start` where checkouts live: `repoRoots` folders hold them at `<root>/<owner>/<name>`, and `repos` names the rest. `branchPrefix` goes before the branch name that `sb followup start` makes from a title, and before the name that the New Session dialog makes when "Create a worktree" is checked and Branch is blank. `followupsFile` is the file that `sb followup import` reads without `--file`. `github` sets how often a PR polls: every `pollSeconds` while its checks run, every `idlePollSeconds` otherwise. `"pollSeconds": 0` turns off the poll timer, so `sbd` asks GitHub only when you run `sb poll`. Its `gh` picks the `gh` that gives the token. Its `url`, the GitHub API base, exists for the tests. `SB_HOME` moves the whole state folder, which is how the tests run a private `sbd`.

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

- `type` is `http` (streamable HTTP) or `sse`. `sbd` replaces `{port}` in `command`, `args`, and `env` with a port that it picks and keeps, or with `port` when you set one. It picks a new port when another program took the old one while `sbd` wasn't running. `path` overrides the URL path, which is `/mcp` for `http` and `/sse` for `sse`.
- tmux starts the command with your shell, so it gets the PATH that your shell sets for a non-interactive command, such as in `~/.zshenv`. A full path doesn't depend on that.
- Every session gets `--mcp-config ~/.sb/mcp-config.json`. A server there replaces the server with the same name in your Claude config, and the session keeps its other servers, such as remote ones, the claude.ai connectors, and a project's `.mcp.json` servers.
- `sbd` starts the servers before any session, and starts a server again on the same port when it exits. A server that keeps exiting waits longer each time, up to a minute. `sb mcp` lists the servers, and for one that exited, its exit status and last output.
- A session connects to its MCP servers when `claude` starts. A session that started while a server was down lacks that server until it stops and resumes.
- The servers have no authentication. Any local process can call them, with whatever token the server holds.

## How it works

- `sbd` keeps sessions and their event log in SQLite in `~/.sb`. It answers `sb` and the app on `~/.sb/sbd.sock`.
- A private tmux server on `~/.sb/tmux.sock` holds every terminal and every shared MCP server, so the app can quit, and `sbd` can restart, without touching a session. The Claude pane runs only `claude`. When `claude` exits, the pane keeps its last screen until `sbd` starts it again.
- Every session gets Claude Code hooks that run `sb hook`, which forwards each event to `sbd`. The state and the reason come from those events, following the rules of the `/sessions` skill.
- Escape at a running tool or a permission dialog sends no hook. A turn that has had no event for 10 s makes `sbd` run `claude agents --json` under the session's account, and a row that says `idle` ends the turn. A long tool call reads `busy`, so it keeps its turn. A turn that stays busy is checked again after 20 s, 40 s, and then every 60 s.
- `sb send` pastes into a live session with bracketed paste, so Claude Code treats the message as typed by you. A write to Claude Code's inbox socket would reach Claude as a message from another Claude session, which Claude doesn't take as your approval.
- `sbd` stops a session's `claude` with SIGTERM when the session has been idle for `idleStopSeconds` (2 s with an open wait), has no open prompt, no background job or subagent, and no terminal showing it.
- For a permission prompt or a question, `sbd` holds the `PermissionRequest` hook open for up to a day and answers it from the card. When the terminal answers first, `sbd` removes the card.
- `sbd` asks GitHub's GraphQL API about every session's PR, in chunks of 20 PRs per request, with the token from `gh auth token`. A PR polls every 30 s while it is pending and every 5 min otherwise, which keeps the polls inside GitHub's rate limits.

## Develop

```
swift build
bin/test            # unit tests, and integration tests that run a private sbd against a stub claude
bin/test --claude   # also the tests that run the installed claude with Haiku, in about 4 minutes
bin/bundle          # build/Switchboard.app
bin/icon            # re-renders assets/icon/AppIcon.icns from AppIcon.svg after you edit it; needs rsvg-convert
```

The app draws its terminals with SwiftTerm. An experimental libghostty backend needs full Xcode and `mise` with zig 0.15.2 (`mise install zig@0.15.2`). `bin/build-ghostty` builds libghostty from the commit in `ghostty.pin` in about a minute, and `SB_GHOSTTY=1 swift build` links it. Then `SB_TERMINAL=ghostty` picks it when the app starts. It loads `~/.config/ghostty/config`, and `SB_GHOSTTY_CONFIG=<file>` adds more settings, such as `window-vsync = false` on a Mac whose displays are asleep. `bin/test` never builds it. See `plans/libghostty.md` next to the design plan.

The stub plays the hook payloads that `bin/test --claude` records in `Tests/IntegrationTests/Fixtures/claude/`. After a Claude Code update, run `bin/test --claude` and read `git diff` on that folder to see what the new version sends.

`spikes/phase0/` holds the Phase 0 tests that measured the Claude Code and GitHub behaviors this relies on.

`SwitchboardCore/Deploys.swift` reads PostHog's deploy signals for the deploy poller that comes later: the deploy comment on PostHog/posthog PRs, the PostHog/charts state files, and the charts deploy runs' sync jobs.
