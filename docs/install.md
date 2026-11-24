# Install

On a new Mac, run:

```
curl -fsSL https://raw.githubusercontent.com/haacked/switchboard/main/bin/bootstrap | bash
```

`bin/bootstrap` checks for the Xcode Command Line Tools, clones the repo to `~/dev/haacked/switchboard` (or to `$SWITCHBOARD_DIR` when that is set), then runs `bin/install` and `bin/start`. It reuses a checkout that is already there. When the app is already installed, it doesn't change anything, so a dotfiles bootstrap can run it every time.

From a checkout, run:

```
bin/install
bin/start
```

`bin/install` first checks for `tmux` and `gh` and lists the command that installs each one it can't find. It looks only in the folders where `sbd` looks: the system folders, `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`. For a tool elsewhere, set its full path in `config.json`. It warns when it can't find `claude` or `gh` isn't signed in. Then it builds the app, with the model prompts in `Contents/Resources/Prompts`, copies it to `~/Applications`, links `sb` into `~/.local/bin`, and starts `sbd` as a launchd agent that runs at login. `sb service uninstall` removes the agent.

`bin/start` opens the installed app. `bin/update` quits the app, fast-forwards this checkout to `origin/main`, runs `bin/install`, opens the app again, and prints the changes since the last update: one line per merged PR, from the installed build's commit to the new one. It refuses, with the app still running, when the checkout is not on main, has uncommitted changes, or cannot fast-forward. Quitting the app leaves `sbd` and your sessions running. `bin/changelog FROM [TO]` prints the same list for any range.

It needs macOS 14 or later, Xcode 26 or later selected with `xcode-select -s` (with Swift older than 6.3, `bin/test` warns that its time limits can fail under load), `tmux` (`brew install tmux`), `gh` signed in with `gh auth login` (`brew install gh`), and Claude Code signed in with your subscription. Sessions run the unmodified `claude` CLI. Switchboard never calls the Claude API.
