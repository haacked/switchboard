# Settings

The app's Settings window (Switchboard ▸ Settings…, or ⌘,) changes the most common settings through `sbd`, which saves them in config.json:

- **General:** this Mac's live cap, whether new sessions start in auto mode, and the account that new sessions use.
- **Issues:** the issue sources, labels, people, backlog, and default preset of the Issues view.
- **Advanced:** opens config.json for the settings that the window doesn't show.

`~/.sb/config.json` holds optional settings. Restart `sbd` after a change by hand (`sb service install` restarts it). A change through the Settings window, `sb live --set`, `sb auto-mode`, `sb account use`, `sb manager model`, or `sb issues` applies without a restart.

```json
{
  "idleStopSeconds": 900,
  "model": "opus",
  "worktreeRoot": "~/dev/worktrees",
  "autoMode": true,
  "claudeArgs": ["--strict-mcp-config"],
  "env": {"CLAUDE_CONFIG_DIR": "~/.claude-personal"},
  "repos": {"haacked/dotfiles": "~/.dotfiles"},
  "repoRoots": ["~/dev"],
  "branchPrefix": "haacked/",
  "followupsFile": "~/dev/haacked/notes/PostHog/Followups.md",
  "github": {"pollSeconds": 30, "idlePollSeconds": 300, "deployPollSeconds": 120},
  "gitlab": {"hosts": ["git.example.com"]},
  "depot": {"enabled": true},
  "trunk": {"path": "trunk", "timeoutSeconds": 30},
  "docket": {"path": "docket", "pollSeconds": 30, "timeoutSeconds": 120, "startTimeoutSeconds": 240},
  "recheckSeconds": {"ci": 7200, "review": 86400, "acknowledged": 3600},
  "removalDelaySeconds": 5,
  "conversationHintTokens": 120000
}
```

`gitlab.hosts` lists GitLab hosts besides gitlab.com and any host whose name contains `gitlab`, such as `git.example.com`. `gitlab.glab` (default `glab`) is the CLI whose `glab auth login` stores the token sbd reads. A merge request polls on the same intervals as a GitHub pull request.

`model` (default `opus`) is the model that each new work session starts on: one from `sb new`, the app's New Session sheet, `sb spawn`, the `spawn` MCP tool, an issue, a follow-up, or the work queue. `manager.model` (default `sonnet`) is the model of Manager conversations and group chats, and `operator.model` (default `sonnet`) is the operator's. sbd passes the model to claude with `--model`, so the account's own `model` setting, which `/model` in any session changes, doesn't pick it, and a session never takes its parent's model. A `--model` on `sb new` or `sb spawn`, or `model` on the `spawn` tool, wins. A work session stores its model when it is created and resumes on it. A Manager conversation and a group chat read `manager.model` each time their claude starts, so `sb manager model <name>` moves them at their next start. The operator reads `operator.model` the same way. A work session created before work sessions stored their model resumes without `--model`, on the model it ran. `"default"` gives the account's own model. sbd logs a value that is empty, contains a space, or starts with a dash, and keeps the default.

`recheckSeconds` sets how long each kind of wait holds a session in Waiting before the session moves to Needs you, in whole seconds, `acknowledged` sets how long an acknowledgment holds it, and `requested` sets how long a message that answers a rule's item can hold it (see [The Inbox](inbox.md)). The defaults are `ci` 7200 (2 h), `bot-review` 3600 (1 h), `review`, `approval`, `merge`, `session`, and `manual` 86400 (1 d), `queue` and `deploy` 14400 (4 h), and `acknowledged` and `requested` 3600 (1 h). A missing key keeps its default. `sbd` logs an unknown key or a value that isn't a whole number from 1 to 315360000 (10 years), and keeps the default for it. A wait's recheck time is set when the wait is set, so a change applies to new waits. A wait set before `sbd` had recheck times gets one that counts from the next `sbd` start.

`removalDelaySeconds` (default 5, from 0 to 86400) sets how long the removal job waits after a delete from the app or `sb rm --done` before it starts a session, which is how long the Removing row offers Undo. 0 starts each session at once and turns Undo off. `sbd` logs a value that isn't a whole number from 0 to 86400 (1 d), and keeps the default. Retry starts a failed delete again with no wait.

`conversationHintTokens` (default 120000, from 0 to 10,000,000) sets the context size in tokens at which a Manager conversation suggests ending it. 0 turns that suggestion off. `sbd` logs a value that isn't a whole number from 0 to 10,000,000, and keeps the default.

`sessionNames` names a session that `sb new` or the app's New Session sheet starts with a prompt but without a name or a branch. Such a session starts at once under its fallback name: its auto branch with `--worktree`, else its folder's name. sbd then asks a model for a 2 to 5 word kebab-case name, such as `fix-login-redirect`, and renames the session when the answer comes. The branch and the worktree keep their names, because claude already runs in that folder. The call is a `claude -p` call with no tools, under `triage.account` or else the session's account. It reads only the first 4000 characters of the prompt, marked as data, and the repository's `owner/name`, the folder's branch when sbd made no worktree, and the session's issue, when present. It never reads a local path or a remote's URL. A name that another session already has gets `-2`, `-3`, and so on. The session keeps its fallback name when the call fails, times out, answers something that is not such a name, or the account has no quota left, and when the session was renamed before the answer came. A session that `sb spawn` starts names its branch, so it keeps that name. Each call records a `session-name` event with `name` and `from`, `error`, or `skipped`. `enabled` (default true) turns it off, `model` (default `claude-haiku-5-5`) picks the model, and `timeoutSeconds` (default 30, at most 120) ends a call that takes longer, such as `"sessionNames": {"enabled": false}`.

`autoMode` (default true) starts every new session in auto mode: sessions from `sb new`, `sb spawn`, the app, follow-ups, imports, group chats, and the Manager. Every launch of such a session, resumes included, passes `--permission-mode auto`, after `claudeArgs`, so it wins over a `--permission-mode` there. `sb new --no-auto` and `sb spawn --no-auto` start a session without sbd's mode, so `claudeArgs` or your Claude settings choose it. A session started with `--plan-mode` passes `--permission-mode plan` instead, on its first launch and on every resume while claude last reported plan mode, so a session that stops before you approve its plan resumes in plan mode. Once claude reports another mode, as after you approve the plan, later launches pass `--permission-mode auto`, or no mode under `--no-auto`. A session that you switch into plan mode with shift+tab resumes in auto mode as before. Sessions that existed before the setting keep starting without a mode. `sb auto-mode on|off` and Settings ▸ General change the setting without a restart, for the sessions created after the change. Sessions that exist keep their mode. `sb auto-mode` with no word prints the setting. A change refuses to run inside Claude Code. `env` sets variables in both panes, so `CLAUDE_CONFIG_DIR` there picks the Claude account for every session. An imported session uses the account it came from instead. `claudeConfigDirs` lists the Claude accounts whose sessions `sb import` lists, such as `["~/.claude", "~/.claude-personal"]`, where `~/.claude` means Claude's default account. `repos` and `repoRoots` tell `sb followup start` where checkouts live: `repoRoots` folders hold them at `<root>/<owner>/<name>`, and `repos` names the rest. `branchPrefix` goes before the branch name that `sb followup start` makes from a title, and before the name that `sb new --worktree` and the New Session dialog make when no branch is given. `followupsFile` is the file that `sb followup import` reads without `--file`. `github` sets how often a PR polls: every `pollSeconds` while its checks run or while it waits on a review (an open PR that is not a draft and that review does not yet let merge, including one with changes requested), every `idlePollSeconds` otherwise. A service that a deploy wait names reads its state file every `deployPollSeconds`. `"pollSeconds": 0` turns off the poll timer, so `sbd` asks GitHub only when you run `sb poll`. Its `gh` picks the `gh` that gives the token. Its `url`, the GitHub API base, exists for the tests. `usage` sets how often sbd reads the accounts' usage, `pollSeconds` (default 300, 0 for only `sb usage`). Its `url` and `keychain` exist for the tests. `depot` sets the Depot poller, which polls with the GitHub poller: `enabled` turns it off, `token` and `org` override the `depot` CLI's login, `config` names that login's file (`~/Library/Application Support/depot/depot.yaml`), and `url`, the Depot API base, exists for the tests. `trunk.path` names the trunk CLI. `sbd` looks a bare name up on `PATH`, then in Trunk's launcher cache, `~/.cache/trunk/cli/<version>/trunk`. `trunk.timeoutSeconds` (default 30) limits how long one `trunk merge status` run may take. `docket.path` names the docket CLI, which `sbd` looks up on `PATH`, in the usual bin folders, and then in `GOBIN` and `~/go/bin`, where `go install` puts it. Set a full path when another program named `docket`, such as pydocket's CLI, comes first on `PATH`. `docket.pollSeconds` sets how often sbd asks docket about the open docket rows, and 0 turns that poll off, so a row changes only when `sb docket` runs. `docket.timeoutSeconds` (default 120) limits one poll's `docket mcp` run. `docket.startTimeoutSeconds` limits the run that `sb docket` makes to start a review, which fetches the PR and provisions docket's clone. Its default is 240, or `timeoutSeconds` when that is larger. docket records the review before it fetches, so a start that times out leaves a review that only docket's dashboard clears. `sb docket` waits 300 seconds for sbd, so a longer limit makes `sb docket` fail while sbd still adds the row when docket answers. `docket mcp` gets `sbd`'s environment plus `env`, so `DOCKET_HOME` and `CLAUDE_CONFIG_DIR` set there reach docket. `SB_HOME` moves the whole state folder, which is how the tests run a private `sbd`.

## Shared MCP servers

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
