# The sb command

Everything in the app also works from `sb`, and every command takes `--json`:

```
sb new ~/dev/myrepo --branch haacked/fix-thing --prompt "Fix the flaky test in foo_test.py"
sb new ~/dev/myrepo --worktree --name "Fix the flaky test"   # names the branch itself
sb new ~/dev/myrepo --worktree --prompt "Fix the login redirect"  # a model renames it, e.g. to fix-login-redirect, once it answers
sb new '~/dev/myrepo' --host devbox --branch haacked/fix-thing  # runs it on the remote host devbox of config.json; the quotes keep ~ for the host
sb spawn --repo PostHog/posthog --branch haacked/flag-cache --prompt "Cache flag lookups."
sb spawn --repo PostHog/posthog --host devbox --branch haacked/flag-cache --prompt "Cache flag lookups."  # on devbox, in a worktree of the checkout that devbox's repos name
sb new ~/dev/myrepo --worktree --name "Rework the cache" --plan-mode   # plans first, edits after you approve
sb ls
sb ls --brief                # one line per session: id, name, state, reason, PR, open waits, and url
sb get <session> --brief --json  # the same fields as JSON, in a few hundred bytes
sb send <session> "Yes, push it."
sb send <session> --image ~/Desktop/shot.png "What is wrong on this page?"
sb attach <session>          # this terminal shows the Claude pane; --shell for the shell
sb focus <session>           # shows the session in the app, launching the app if needed
sb shell <session> --close     # ends the shell pane; --open starts it again
sb wait <session> Alex said he would reply tomorrow
sb wait <session> --kind date --until 2h --note "check the dashboard"
sb wait <session> --kind session --target flag-cache
sb wait <session> --clear
sb schedule <session> --every 30m "Run the Waiting audit"
sb schedule Operator --every 30m --topup --group Infra --repo owner/name --target 5 --template-file template.md --rubric-file rubric.md
sb schedule ls                # the schedules, the next due first; ls <session> for one session's
sb schedule pause|resume|rm <id>
sb schedule edit <id> --every 1h "Run the Waiting audit"   # change the interval, the prompt, or both
sb schedule run <id>          # run it now, or once its session is free
sb note <session> Stacked on #1190
sb note <session> --todo Tell Alex in #flags that the fix shipped
sb note <session> --resolve <id>   # resolves a to-do; only you can
sb note --resolved            # the resolved to-dos, newest first; --limit N (default 50)
sb issue <session> 174       # sets the issue that the tile shows; also owner/name#174 or an issue URL
sb issue <session> --clear
sb done <session>
sb pause <session> --reason "free CPU" --until "#1190"   # stops claude and holds its messages until #1190 merges or you resume it
sb pause <group> --until 2h  # pauses each session in the group; --group <group> when a session has the same name
sb resume <session>          # starts it again with the pause's message, then the messages that waited
sb rm <session>              # stops claude and forgets the session; the folder and transcript stay
sb rm <session> --worktree   # also deletes its worktree
sb rm <session> --worktree --delete-branch  # also deletes its local branch
sb rm <session> --resolve <id> --resolve <id>  # resolves each open to-do and removes the session
sb rm --done --worktree       # deletes every Done session that passes the checks, after listing them; skips the rest
sb rm --keep <session>       # cancels the session's failed delete and keeps the session, as Keep does
sb cleanup <session>         # removes a merged PR's worktree and local branch; the session stays in Done
sb merge <session|#N>        # merges or enqueues a Ready to merge session's PR, then resumes the session
sb review <session|#N>       # lists the suggested reviewers of a PR that shows the review card
sb review <session> ann @copilot  # requests a review from them with gh
sb events --follow
sb cards                     # open permission prompts and questions
sb allow <session>
sb allow --auto <session>    # allow, and switch the session to auto mode
sb deny <session> Use the Makefile instead.
sb answer <session> cherry "red, blue"
sb mcp                       # the shared MCP servers
sb mcp-server [--group G]    # the MCP server for Claude, on stdin and stdout
sb host                      # the remote hosts in config.json and each host's ssh link
sb host connect <host>       # opens the host's ssh link, keeps it open, and sets up ~/.sb there (needs tmux, git, python3); an open link keeps a devbox running
sb host disconnect <host>    # closes the host's ssh link
sb repo                      # the repositories that the New Session sheet offers, most recently used first
sb repo add <path>           # adds the repository that holds the folder; a worktree adds its main checkout
sb triage                    # what needs you, in the order to go through it
sb next                      # the first item
sb choose <session> 1        # click an option, by number or label
sb choose <session> 3 --text "Use v2"   # a reply option sends the text
sb decide <session>          # the item's decisions, with your answers so far
sb decide <session> 2 to-do  # answer decision 2 with an option, by number or label
sb decide <session> 3 --skip # or --text "..." for a typed answer
sb decide <session> --submit # send every answer as one message
sb decide <session> --resend # send them again when sbd can't tell whether they arrived
sb decide <session> --ask 2 "why not B?"  # ask the session about decision 2 and print its reply
sb reply <session>           # the session's last reply, as Markdown
sb context <session>         # Claude's steps up to the session's Inbox item (--steps N)
sb summary set < card.json   # inside a session: write its Inbox card for this turn
sb summary help              # the card's format
sb draft post <session> 1    # outside the sessions: post draft 1 to GitHub as you (--text to edit, --text - for stdin)
sb draft check <session> 1   # read the comment that draft 1 replies to again, or look for a post that sbd lost track of
```

## Naming a session

A session is an id, a unique id prefix, or a unique name. A session id looks like `swb_eb4ec`, and sessions made before that form have ids like `seb4ec`. Both forms work wherever an id does. `sb send` pastes into a live idle session, queues the message while a turn runs, and resumes a stopped session with the message as its first prompt. The paste also submits anything you typed but didn't send in that session's Claude terminal.

## Brief output

`sb get --brief` and `sb ls --brief` show only what a caller needs to decide whether to act on a session, for a few hundred bytes per session where the full form takes 2 to 13 KB. The text form is one line per session. With `--json`, each session is an object with `id`, `name`, `url`, `state`, and `reason`, plus `acknowledged` and `snoozedUntil` when set, `pr` with the PR's `number`, `repo`, `state`, `status`, and `checks` when the session has a PR, and `waitLine` when it has open waits. `reason` is the reason on one line, cut at 200 characters. `waitLine` names what each open wait waits on, joined with `; `, and stops at 200 characters with a count of the waits left out. The MCP `list_sessions` and `get_session` tools return this form unless they are called with `full: true`. Plain `sb get` and `sb ls` don't change.

## Session links

`sb focus` brings the app to the front, launching it if it isn't running, and selects the session as a sidebar click does. A `switchboard://session/<id>` link does the same from any app, and `sb focus` opens that link. A link can also name a session, as `switchboard://session/<name>` with the name percent-encoded, such as `switchboard://session/Fix%20CI%20chat`. A name link matches an exact, case-sensitive name, and an id link matches a full id only, never an id prefix. Names aren't unique and change on rename, so the links that Switchboard writes always carry the id. A link clicked in the app selects its session at once, or the error banner says why it can't: the session was removed, the app has no session with that id or name, more than one session has the name, or the link isn't one Switchboard can open. A link from another app also fails at once for a removed session or a name that more than one session has. An id or name the app doesn't list yet, such as a session that `sb new` just made, is selected when a refresh lists it, and after three refreshes that don't, the error banner says the app has no such session. `sb get --json`, `sb ls --json`, and the MCP `get_session` and `list_sessions` tools show a session's link as `url`. The Manager guide, each group chat's guide, and the default `triage.systemPrompt` tell Claude to write a session it names as a Markdown link to that URL, such as `[fix-cache](switchboard://session/swb_eb4ec)`.

In the app, text that `sbd` or Claude wrote links the sessions it names: Manager and chat replies, Inbox cards and their Details, notes, and wait lines. A live session's id shows as the session's name, linked to the session, and a removed session's id shows its name with no link. A Markdown link to a session's URL, such as `[docs-refresh](switchboard://session/sdcs7r)`, shows as its label, and a bare `switchboard://session/…` URL shows as a link. Wait lines parse no other Markdown, but they also draw the `[label](switchboard://session/…)` form as its label, so a pasted Copy Link reads as the session's name. A session wait's line, such as `docs-refresh to reach Done`, links the name to the session that the wait is on. The line keeps the name that the session had when the wait was set. Text inside a button, such as an Inbox row's title or a Board card's line, shows names with no link. A click on a session link selects the session as described above. On macOS 15 and later, resting the pointer on a session link shows a card with the session's name, id, state, and PR. For a link that doesn't resolve, the card shows the written name or id and the reason that the error banner would give. macOS 14 shows no card, and text that names a session by its id has a tooltip with the session's name and id.

Copy Link puts a session's link on the clipboard as plain text, in the form `[name](switchboard://session/<id>)`. It is in the right-click menu of a sidebar row, a Board card, an Inbox item, a conversation, and the session's name in its header, and in the Session menu for the selected session. A newline in the name becomes a space, and a backslash goes before each Markdown character in it, so the label reads as the name where Markdown renders.
