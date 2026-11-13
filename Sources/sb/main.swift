import Foundation
import SwitchboardCore

let usage = """
  Usage: sb <command> [arguments] [--json]

  Sessions:
    ls [--org O1,O2] [--local]    list sessions by state, or only those in the
                                  GitHub orgs O1 and O2, or with no GitHub remote
    new <folder> [--branch B | --worktree] [--base REF] [--name N] [--prompt P]
        [--model M] [--account A] [--group G] [--no-auto] [--host H]
                                  start a session in the folder, or in a new
                                  worktree of its repo with --branch or
                                  --worktree. --worktree names the branch from
                                  --name. It joins the group G, else its
                                  parent's group. It runs under the group's
                                  account, else the account A, else its
                                  parent's, else the active account. It fails
                                  when the group has an account and A names
                                  another. It starts in auto mode unless
                                  --no-auto or the autoMode setting is false.
                                  --host runs it on the remote host H of
                                  config.json, in a folder there that is
                                  absolute or starts with ~
    spawn --repo R --branch B --prompt P [--followup [--after pr:N]] [--name N]
        [--base REF] [--model M] [--account A] [--no-auto] [--wait STATE]
                                  start a session on a new branch B in a new
                                  worktree of R, which is owner/name, a name, or
                                  a folder. Inside a session, that session is
                                  its parent. --followup adds it unstarted.
                                  --after makes it ready when PR N of R merges.
                                  --wait, inside a session, resumes that session
                                  once the new one reaches STATE, such as done
    account                       list the Claude accounts and the active one
    account use <name|folder> [--move | --new-only]
                                  run new sessions under this account. --move
                                  moves the sessions whose claude is stopped
                                  too. A terminal asks when neither is given
    account move <name|folder> [--dry-run]
                                  move the sessions whose claude is stopped
    usage                         show each account's use of its 5-hour and
                                  weekly limits, and when each resets
    manager [<conv>] [<text>]     open a Manager conversation, a session that manages
                                  the others: the one named by id or name, else the
                                  most recent, starting one the first time. With
                                  text, send it a message
    manager new [--name N] [<text>]
                                  start a conversation. Without --name, its first
                                  prompt names it
    manager ls                    list the conversations, newest activity first
    manager <conv> --log          the conversation's last messages
    manager mcp <conv> [add <server>… | rm <server>… | --all | --none]
                                  show or change the MCP servers that the
                                  conversation loads besides switchboard. A new
                                  conversation loads none. --all loads the full
                                  setup, which a claude.ai connector needs. A change
                                  restarts its claude, after the turn when one runs
    get <session>                 show one session
    send <session> <text>         send a message: paste it, queue it, or resume with it
    send <session> --image <path> [--image <path>…] [<text>]
                                  send images with the message. sbd keeps a copy of
                                  each (png, jpg, gif, webp, heic, up to 20 MB) until
                                  the session is removed
    send --group G [--yes] <text> send a message to every session in the group, after
                                  listing them and asking. Without a terminal, it
                                  needs --yes. Inside a Claude session, it sends
                                  nothing and shows the message in Switchboard,
                                  where the user sends or cancels it
    send --pending N [--timeout S] wait up to S seconds (default 60) for the user's
                                  decision on group message N
    open <session> [--terminals]  resume the session if its claude is stopped.
                                  --terminals also starts the panes and prints
                                  their tmux targets as JSON
    stop <session>                stop the session's claude
    resume <session> [--prompt P] resume the session's claude
    done <session>, undone <session>
    wait <session> <note>         wait on something by hand
    wait [<session>] --kind K [--target T] [--who W] [--env E] [--service S]
         [--state S] [--until WHEN] [--since WHEN] [--note N] [--then resume|notify]
                                  wait on a PR, a deploy, another session, or a
                                  time. Inside a session, the session is optional
    wait [<session>] --block [--timeout S] --kind K ...
                                  set the wait and block until it resolves, then
                                  print the wait-resolved event as JSON. Exits 0
                                  when it resolves, 2 after S seconds, 3 when sbd
                                  can't be reached, and 1 when it is cleared. The
                                  session doesn't resume. The timeout and Ctrl-C
                                  clear the wait
    wait <session> --clear [--id W]
    wait <session> --resolve <what happened> [--id W]
    note <session> [<text>]       add a note, or list the notes: open to-dos,
                                  then plain notes, then resolved to-dos
    note <session> --todo <text>  add a to-do, a task for you that blocks
                                  removing the session until you resolve it
    note <session> --resolve <id> resolve a to-do. It doesn't run inside Claude
    note <session> --rm <id>      remove a note. It refuses an open to-do
    note --resolved [--limit N]   list the resolved to-dos, newest first
                                  (default 50). The record outlives the session
    rename <session> <name>
    issue <session> <ref>|--clear set the GitHub issue that the session's tile
                                  shows: 123, #123, owner/name#123, or an issue
                                  URL. It replaces the issue that sbd finds in
                                  the PR body or the branch name
    rm <session> [--worktree [--delete-branch [--delete-remote-branch]]] [--resolve <id>]...
                                  remove the session, and its worktree with --worktree, which refuses
                                  uncommitted files, unpushed commits, and a folder sbd didn't make.
                                  --delete-branch also deletes the local branch, and refuses unless the
                                  session's PR is merged and the branch has no commit after it.
                                  --delete-remote-branch also deletes the branch on its remote, and keeps
                                  it, with an error, unless it is at the merged PR's head.
                                  It refuses a session with an open to-do unless a
                                  --resolve names each one, which resolves them all.
                                  --resolve doesn't run inside Claude
    rm --done [--worktree [--delete-remote-branch]] [--yes]
                                  remove every Done session the same way, after listing
                                  them and the ones whose checks fail, which it skips.
                                  --worktree also deletes each branch whose PR merged.
                                  Without a terminal or inside Claude, it needs --yes.
                                  With --json and without --yes, it removes nothing
    cleanup <session>             remove the worktree and the local branch of a session whose PR merged,
                                  and keep the session in Done. Refuses uncommitted files, commits
                                  after the merge, a running turn, and a folder sbd didn't make.
    merge <session|PR> [--dismiss]
                                  merge a Ready to merge session's PR with a merge commit, then resume
                                  the session. In a repo with GitHub's merge queue or Trunk, add it to
                                  the queue instead, and resume the session once it merges. A PR (#N,
                                  owner/name#N, or a URL) names the session by its open PR. --dismiss
                                  acknowledges the session's Ready to merge item, as sb ack does.
                                  Refuses inside Claude Code
    review <session|PR> [<reviewer>...] [--dismiss]
                                  list the suggested reviewers of a session whose PR shows the
                                  review card, or request a review from each login, org/team,
                                  or @copilot with gh. --dismiss acknowledges the card, as ack
                                  does. Refuses inside Claude Code
    ack <session> [--undo]        acknowledge the session's Inbox item: it moves to Waiting until its
                                  reason or its PR's head commit changes or a new turn starts. Nothing
                                  else about the session changes. --undo puts it back in the Inbox.
                                  Refuses the session that runs it
    import [--all] [--repo R]     list the Claude sessions outside Switchboard that
                                  run in a worktree, or every one with --all, and
                                  only those of the repo named R with --repo
    import <ref>... [--name N] [--stop]
                                  import Claude sessions by id, id prefix, or name.
                                  --stop first exits the claude of a session that
                                  waits idle at its prompt in another terminal
    attach <session> [--shell]    attach this terminal to the Claude pane or the shell.
                                  --shell starts a closed shell again
    shell <session> --open | --close
                                  start the session's shell pane, or end it. A shell
                                  that exits ends its pane too. A closed shell stays
                                  closed until --open or attach --shell
    screen <session> [--shell] [--colors]
                                  print the pane's screen, with --colors as SGR escapes
    watch <session> --until <state> [--timeout S]
    events [--session S] [--since ID] [--follow]
                                  the newest events, or those after an id

  What needs you:
    triage                        the sessions that need you or that Claude can
                                  continue, in the order to go through them, each
                                  with a title, a summary, and options
    next                          the first of them
    choose <session> <option> [--text T]
                                  click an option, by number or label: run its action,
                                  such as send its message or merge. A reply option
                                  sends T. On a pick-any card, options separated by
                                  commas (1,3) go as one reply. Request review requests
                                  the reviewers in T. Card, merge, and review options
                                  refuse inside Claude Code
    decide <session>              the decisions of the session's item, each with its
                                  options and its answer so far
    decide <session> <n> <option> | --text T | --skip
                                  answer decision n with an option by number or label,
                                  typed text, or a skip. On a pick-any decision, options
                                  separated by commas (1,3) go together. The first answer
                                  keeps a copy of the decisions until --submit or --discard
    decide <session> --submit [--stale] | --discard
                                  send every answer as one message, or drop the answers.
                                  After the session took another turn, --submit needs --stale
    decide <session> --resend     send the submitted answers again, only when sbd
                                  restarted while sending them and can't tell whether
                                  the session got them
    reply <session>               the session's last reply, as Markdown
    summary set [<session>]       record the session's Inbox card for this turn, as JSON
                                  on stdin. The session defaults to $SB_SESSION_ID
    summary help                  the card's format, for a session to follow

  Permission prompts and questions:
    cards [<session>]             list the open ones
    allow [--card N] [--auto] <session>
                                  allow the session's permission prompt. --auto
                                  also switches the session to auto mode, where
                                  Claude's classifier decides further
                                  permissions. A prompt from manual or accept
                                  edits mode offers it. On a folder trust
                                  prompt, it trusts the folder
    deny [--card N] <session> [message]
                                  deny it. With a message, Claude reads it and
                                  goes on. Without one, the turn stops. On a
                                  folder trust prompt, it exits claude and
                                  keeps the message that started it
    answer [--card N] <session> <answer>...
                                  answer the session's question, one answer per
                                  question in order. Separate the labels of a
                                  multi-select answer with commas. Text that
                                  is no option's label goes as typed.

  Groups:
    group ls                      list the groups with their sessions, then Ungrouped
    group add <name> [<session>...] [--note N] [--description D]
    group rm <group>              remove the group; its sessions become ungrouped
    group move <session>... --to <group> | --ungrouped
    group note <group> <text>
    group describe <group> <text> | --clear
                                  set or clear the group's description, at
                                  most \(SessionGroup.descriptionLimit) characters
    group account <group> [<account> | --clear]
                                  show, set, or clear the Claude account that the
                                  group's sessions run under. A stopped session
                                  moves to it at its next launch. New sessions in
                                  the group use it, and a different --account is
                                  refused
    group suggest [--accept <id> | --decline <id> | --declined | --undecline <id>]
                                  list at most 3 groups suggested from
                                  dependencies, branch prefixes of two or more
                                  words, and PR title scopes, or accept or decline
                                  one. A session that you placed by hand never
                                  moves, and a finished session joins nothing.
                                  --declined lists the declined ids, and
                                  --undecline lets one be suggested again
    chat <group> [<text> | --send <text>]
                                  open the group's chat, a session that manages
                                  the group's sessions, starting it the first
                                  time. With text, send it a message
    chat <group> --log            the chat's last messages

  Plan documents:
    plan attach <doc> (--group G | --session S) [--path P]
                                  attach a local markdown file, an issue
                                  (owner/name#N or its URL), or with --path a
                                  file in a PR. Sessions whose PRs a group's
                                  plan links join the group
    plan ls [--group G | --session S]
    plan get <plan>               show the plan and its out-of-date rows
    plan detach <plan>
    plan update <plan>            write the status table between
                                  <!-- sb:status --> and <!-- /sb:status -->
    plan auto <plan> on|off       write the table on its own when it changes,
                                  and apply model updates without asking
    plan propose <plan>           ask the model to rewrite the out-of-date
                                  rows' Status cells now
    plan proposals [--group G] [--plan P]
                                  the updates and new rows that wait for you
    plan apply <proposal>         write a proposal into the document
    plan reject <proposal>        drop it. A declined row stays declined

  Follow-ups, sessions that haven't started:
    followup add <text> [--title T] [--repo owner/name] [--branch B] [--on WHEN]
                 [--after owner/name#N] [--link URL] [--parent S] [--account A]
                                  add one. Without --repo, the current folder's
                                  GitHub repo. --on and --after move it to Needs
                                  you when the time passes or the PR merges
    followup ls                   list follow-ups that haven't started
    followup start <f> [--path FOLDER] [--branch B] [--base REF]
                                  make its worktree and start claude with its text
    followup rm <f> [--resolve <id>]...
                                  remove a follow-up that hasn't started. Each open
                                  to-do needs a --resolve
    followup import [--file F]    add the open items of Followups.md that no
                                  earlier import read

  docket reviews, rows with no terminal:
    docket <pr> [--existing append|overwrite] [--name N] [--group G] [--parent S]
                                  start a docket review of the PR, or track the
                                  one docket has open, and add its row. sb rm
                                  removes the row and leaves docket's review

  Service:
    poll [--all]                  ask GitHub and Depot about the sessions' PRs
                                  now; --all reads every PR, not only those due
    snapshots [--write]           show how the last start built each session,
                                  from a snapshot or a full replay; --write
                                  first saves a snapshot of every session
    ping                          check that sbd answers
    mcp                           list the shared MCP servers that sbd runs
    mcp-server [--group G]        run the MCP server for Claude on stdin and stdout.
                                  --group limits its tools to the group's sessions
    host [ls]                     list the remote hosts in config.json and each
                                  host's ssh link
    host connect <host>           open the host's ssh link and keep it open. An
                                  open link keeps a devbox running
    host disconnect <host>        close the host's ssh link
    repo [ls]                     list the repositories that the New Session
                                  sheet offers, most recently used first
    repo add <path>               add the repository that holds the folder. A
                                  worktree adds its main checkout
    autocontinue [on|off|status]  send "Claude can continue" sessions their
                                  next step on their own, or show what holds
                                  each one back. Off by default
    live [--set N]                list the sessions whose claude runs and the
                                  starts that queue behind the cap, for this Mac
                                  and for each remote host, whose own cap is its
                                  liveCap key, else the top-level liveCap. --set
                                  changes this Mac's cap and saves it in
                                  config.json
    service install|uninstall|status
    version

  A <session> is an id, a unique id prefix, or a unique name. For send, rename,
  and the text forms of wait, note, deny, and answer, every word after the
  session is text, except send's leading --image pairs, so put --json and
  --card before the session. SB_HOME picks the state folder (default ~/.sb).

  Wait kinds: ci, review (needs --who), bot-review, approval, queue, merge, and
  deploy (--env dev, prod-us, prod-eu, or prod) take a PR as --target, or wait
  on the session's own PR. session takes another session as --target and a
  --state (default done). date needs --until (2h, 2026-10-26, or
  2026-10-26T09:00). manual takes an optional --until that returns it to Needs
  you, a day later without one. --then notify moves the session to Needs you
  instead of resuming it. review, bot-review, and queue take --since WHEN, a
  past time after which a review or a queue change counts, instead of the time
  the wait was set. A wait still open past its recheck time
  (recheckSeconds in config.json) moves the session to Needs you.
  """

struct Args {
  var positional: [String] = []
  /// Every value of each valued flag, in order, for a flag that repeats.
  var allValues: [String: [String]] = [:]
  /// The last value of each valued flag.
  var values: [String: String] { allValues.compactMapValues(\.last) }
  var switches: Set<String> = []

  /// After `literalAfter` positional arguments, every argument is text, even
  /// one that starts with --. Flags for those commands go before the session.
  init(_ argv: ArraySlice<String>, literalAfter: Int = .max) {
    let valued = Set([
      "--branch", "--base", "--name", "--prompt", "--model", "--account", "--until", "--timeout", "--session",
      "--since", "--host",
      "--id", "--resolve", "--rm", "--card",
      "--title", "--repo", "--on", "--after", "--link", "--parent", "--path", "--file",
      "--group", "--to", "--note", "--accept", "--decline", "--undecline", "--existing", "--send", "--pending",
      "--plan", "--text", "--wait",
      "--set", "--description", "--artifact", "--kind", "--version", "--limit", "--org",
    ]).union(waitFlags.keys)
    var rest = argv
    while let arg = rest.popFirst() {
      if positional.count >= literalAfter {
        positional.append(arg)
      } else if valued.contains(arg) {
        guard let value = rest.popFirst() else { die("\(arg) needs a value") }
        allValues[arg, default: []].append(value)
      } else if arg.hasPrefix("--") {
        switches.insert(arg)
      } else {
        positional.append(arg)
      }
    }
  }

  var json: Bool { switches.contains("--json") }

  func session(_ command: String) -> String {
    guard let s = positional.first else { die("\(command) needs a session") }
    return s
  }
}

/// Escapes each control character but newline and tab. A refusal
/// from sbd can quote text that Claude wrote.
func warn(_ message: String) {
  FileHandle.standardError.write(Data("sb: \(controlsEscaped(message))\n".utf8))
}

func die(_ message: String) -> Never {
  warn(message)
  exit(1)
}

func printJSON(_ value: JSON) {
  print(value.text)
}

let client = Client()

func call(_ op: String, _ args: [String: JSON] = [:], timeout: TimeInterval = 60) -> JSON {
  do {
    return try client.call(op, args, timeout: timeout)
  } catch {
    die("\(error)")
  }
}

func decode<T: Decodable>(_ value: JSON, as type: T.Type) -> T {
  do { return try JSONCoding.convert(value, to: type) } catch { die("can't read sbd's answer: \(error)") }
}

func summary(_ value: JSON) -> SessionSummary { decode(value, as: SessionSummary.self) }

func ago(_ ms: Int64) -> String {
  let s = max(0, (nowMs() - ms) / 1000)
  if s < 60 { return "\(s)s" }
  if s < 3600 { return "\(s / 60)m" }
  if s < 86400 { return "\(s / 3600)h" }
  return "\(s / 86400)d"
}

func printTable(_ sessions: [SessionSummary]) {
  if sessions.isEmpty {
    print("No sessions. Start one with: sb new <folder>")
    return
  }
  let idWidth = max(2, sessions.map(\.id.count).max() ?? 0)
  let nameWidth = min(28, max(4, sessions.map(\.name.count).max() ?? 0))
  var lastState: AttentionState?
  for s in sessions {
    if s.state != lastState {
      if lastState != nil { print("") }
      print(s.state.title)
      lastState = s.state
    }
    let live = s.live ? "●" : "○"
    let name = oneLine(s.name, max: nameWidth)
    let todos = s.openTodos.count
    let marker = todos == 0 ? "" : "  [\(todos) to-do\(todos == 1 ? "" : "s")]"
    print(
      "  \(live) \(s.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(ago(s.since).padding(toLength: 4, withPad: " ", startingAt: 0))  \(s.reasonLine)\(marker)"
        .printable
    )
  }
}

func printSession(_ s: SessionSummary) {
  print("\(s.id)  \(s.name)".printable)
  print("  state:   \(s.state.title): \(s.reasonLine) (\(ago(s.since)))".printable)
  if s.waitsToStart {
    printFollowup(s)
    return printWaitsAndNotes(s)
  }
  if let docket = s.docket {
    printDocket(docket)
    return printWaitsAndNotes(s)
  }
  print(
    "  claude:  \(s.live ? "running, pid \(s.claudePid.map(String.init) ?? "?")" : "stopped")\(s.attached ? ", attached" : "")"
  )
  if let group = s.chat { print("  chat of: group \(group)") }
  if let group = s.group {
    let description = s.groupDescription.map { ": \($0)" } ?? ""
    print("  group:   \(s.groupName ?? group) (\(group))\(description)".printable)
  }
  print("  folder:  \(s.cwd)")
  if let account = s.account { print("  account: \(ClaudeAccount.name(account))") }
  if let mode = s.permissionMode { print("  mode:    \(PermissionMode.title(mode))".printable) }
  if let b = s.branch { print("  branch:  \(b)") }
  if let pr = s.pr { print("  pr:      \(pr.line)  \(pr.url)") }
  for issue in s.issues ?? [] {
    print(
      "  issue:   \(issue.label(from: s.pr?.repo)) (\(issue.via.title))\(issue.url.map { "  \($0)" } ?? "")".printable)
  }
  if let b = s.board {
    let back = b.back.map { "; \($0.text)" } ?? ""
    print("  column:  \(b.column.title) \(ago(b.since))\(b.line.map { "; \($0)" } ?? "")\(back)".printable)
  }
  if let owners = s.pr?.codeOwners { print("  owners:  \(owners.text(separator: "; "))".printable) }
  if let run = s.pr?.depot { print("  depot:   \(run.line)".printable) }
  for d in s.dependencies ?? [] {
    let deploy = d.deploy ? (d.deployed == true ? ", deployed" : ", deploy") : ""
    let session = d.session.map { " (session \($0))" } ?? ""
    print(
      "  depends: \(d.label(from: s.pr?.repo ?? d.repo)) \(d.state?.rawValue.lowercased() ?? "unknown")\(deploy)\(session)"
    )
  }
  for p in s.plans ?? [] { printPlan(p, indent: "  ") }
  print("  claude session: \(s.claudeSessionId)")
  if let r = s.lastReply { print("  last reply: \(oneLine(r, max: 200))".printable) }
  printWaitsAndNotes(s)
}

/// The sessions that `sb import` can import, grouped by repo. ● marks a
/// session that a claude runs now, which imports once that claude exits.
func printImportable(_ list: ImportList, repo: String? = nil) {
  let titleWidth = 40
  if list.sessions.isEmpty { print("No Claude sessions to import\(list.hidden > 0 ? " in a worktree" : "").") }
  for (i, group) in list.groups.enumerated() {
    if i > 0 { print("") }
    print(group.title.printable)
    for s in group.sessions {
      let title = oneLine(s.title, max: titleWidth).padding(toLength: titleWidth, withPad: " ", startingAt: 0)
      let account = (s.account as NSString).abbreviatingWithTildeInPath
      print("  \(s.running ? "●" : "○") \(s.idPrefix)  \(title)  \(s.summary), \(account)".printable)
    }
  }
  if list.hidden > 0 {
    let command = "sb import --all" + (repo.map { " --repo \(shellWord($0))" } ?? "")
    print("\n\(list.hidden) more outside a worktree. List them with: \(command)".printable)
  }
  if list.sessions.contains(where: \.running) {
    print("● claude runs the session now. Exit it there, or stop its background job, then import it.")
    if list.sessions.contains(where: \.stoppable) { print("  Import an idle one with --stop to exit its claude.") }
  }
}

func sessionCommand(_ op: String, _ a: Args, extra: [String: JSON] = [:]) {
  var args = extra
  args["session"] = .string(a.session(op))
  let result = call(op, args)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}

// MARK: Commands

/// Forwards a Claude Code hook payload to sbd and prints sbd's answer. It
/// prints nothing and exits 0 when sbd is down, because Claude Code shows a
/// failed hook in the conversation.
func hook() -> Never {
  let input = FileHandle.standardInput.readDataToEndOfFile()
  let env = ProcessInfo.processInfo.environment
  guard let session = env["SB_SESSION_ID"], let payload = try? JSONCoding.decoder.decode(JSON.self, from: input) else {
    exit(0)
  }
  // The timeout stays below the 30 s hook timeout in claude-settings.json. A
  // PermissionRequest waits for its card's answer until Claude Code's own
  // timeout ends the hook.
  let held = payload["hook_event_name"]?.string == "PermissionRequest"
  let timeout = held ? TimeInterval(Card.holdSeconds + 60) : 25
  if let answer = try? client.call("hook", ["session": .string(session), "payload": payload], timeout: timeout),
    answer.object?.isEmpty == false
  {
    print(answer.text)
  }
  exit(0)
}

func attach(_ a: Args) -> Never {
  let id = a.session("attach")
  let pane: Pane = a.switches.contains("--shell") ? .shell : .claude
  // The tmux server of a session on a host is on that host, so this terminal can't attach to its socket.
  if let host = summary(call("get", ["session": .string(id)])).host {
    die("\(id) runs on \(host), and sb attach can't reach a session on a host yet")
  }
  let terminals: Terminals
  do { terminals = try client.open(id) } catch { die("\(error)") }
  if pane == .shell { _ = call("shell", ["session": .string(id), "open": .bool(true)]) }
  let command = terminals.attachCommand(pane)
  let argv = command.map { strdup($0) } + [nil]
  execv(command[0], argv)
  die("can't run \(command[0]): \(UnixSocket.errnoText())")
}

func watch(_ a: Args) -> Never {
  let id = a.session("watch")
  guard let until = a.values["--until"], let state = AttentionState(rawValue: until) else {
    die("watch needs --until with one of: \(AttentionState.allCases.map(\.rawValue).joined(separator: ", "))")
  }
  let deadline = Date().addingTimeInterval(Double(a.values["--timeout"] ?? "60") ?? 60)
  while true {
    let s = summary(call("get", ["session": .string(id)]))
    if s.state == state {
      if a.json { printJSON((try? JSON(encoding: s)) ?? .null) } else { printSession(s) }
      exit(0)
    }
    if Date() > deadline { die("\(id) is \(s.state.rawValue), not \(state.rawValue), after the timeout") }
    usleep(200_000)
  }
}

/// Prints the newest events, or the events after --since, and with --follow
/// keeps printing new ones.
func events(_ a: Args) -> Never {
  var cursor = EventCursor(since: a.values["--since"].flatMap(Int64.init), session: a.values["--session"])
  while true {
    let list: [Event]
    do { list = try cursor.next() } catch { die("\(error)") }
    for e in list {
      if a.json {
        printJSON((try? JSON(encoding: e)) ?? .null)
      } else {
        let detail =
          e.data["tool_name"]?.string ?? e.data["prompt"]?.string ?? e.data["last_assistant_message"]?.string ?? e.data[
            "text"]?.string ?? ""
        let from = e.data["from"]?.string.map { "from \($0): " } ?? ""
        print("\(e.id)  \(e.session)  \(e.kind)  \(from)\(oneLine(detail, max: 80))".printable)
      }
    }
    if !a.switches.contains("--follow") { exit(0) }
    fflush(stdout)
    usleep(500_000)
  }
}

let label = "com.haacked.switchboard.sbd"
// SB_LAUNCH_AGENTS lets a test keep `service` away from the real folder.
let launchAgentsFolder = (ProcessInfo.processInfo.environment["SB_LAUNCH_AGENTS"] ?? "~/Library/LaunchAgents")
  .expandingTilde
let plistPath = "\(launchAgentsFolder)/\(label).plist"

func service(_ a: Args) {
  let uid = getuid()
  // SB_LAUNCHCTL lets a test keep `service` away from the real launchd.
  let launchctl = ProcessInfo.processInfo.environment["SB_LAUNCHCTL"] ?? "/bin/launchctl"
  func launch(_ args: [String]) { _ = try? runCommand(launchctl, args) }
  switch a.positional.first {
  case "install":
    let sbd = siblingExecutable("sbd")
    guard FileManager.default.isExecutableFile(atPath: sbd) else { die("no sbd next to sb at \(sbd)") }
    var plist: [String: Any] = [
      "Label": label, "ProgramArguments": [sbd], "RunAtLoad": true, "KeepAlive": true,
      "StandardErrorPath": client.home.log, "StandardOutPath": client.home.log, "ProcessType": "Interactive",
    ]
    if ProcessInfo.processInfo.environment["SB_HOME"] != nil {
      plist["EnvironmentVariables"] = ["SB_HOME": client.home.path]
    }
    do {
      try client.home.create()
      try FileManager.default.createDirectory(atPath: launchAgentsFolder, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: URL(fileURLWithPath: plistPath))
    } catch { die("can't write \(plistPath): \(error)") }
    launch(["bootout", "gui/\(uid)/\(label)"])
    let bootstrap: CommandResult
    do { bootstrap = try runCommand(launchctl, ["bootstrap", "gui/\(uid)", plistPath]) } catch {
      die("can't run \(launchctl): \(error)")
    }
    guard bootstrap.status == 0 else {
      let output = (bootstrap.stderr + bootstrap.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
      die("launchctl bootstrap failed" + (output.isEmpty ? "" : ": \(output)"))
    }
    for _ in 0..<50 {
      if (try? client.call("ping", timeout: 1)) != nil {
        print("sbd runs as a launchd agent (\(label)), with state in \(client.home.path)")
        return
      }
      usleep(100_000)
    }
    die("sbd did not answer. See \(client.home.log)")
  case "uninstall":
    launch(["bootout", "gui/\(uid)/\(label)"])
    try? FileManager.default.removeItem(atPath: plistPath)
    print("removed the launchd agent \(label)")
  case "status":
    let installed = FileManager.default.fileExists(atPath: plistPath)
    let ping = try? client.call("ping", timeout: 2)
    print("launchd agent: \(installed ? plistPath : "not installed")")
    print(
      "sbd: \(ping.map { "running, pid \($0["pid"]?.int ?? 0), \(client.home.socket)" } ?? "not answering on \(client.home.socket)")"
    )
  default:
    die("usage: sb service install|uninstall|status")
  }
}

// MARK: Dispatch

var argv = CommandLine.arguments.dropFirst()
guard let command = argv.popFirst() else {
  print(usage)
  exit(0)
}
// The text of these commands is everything after the session. All but
// `send` and `rename` read flags instead when the word after the session is
// one. `send` reads its leading --image pairs itself, in Send.swift.
let flagsAfterSession = ["wait", "note", "deny", "answer"]
var a = Args(argv, literalAfter: (["send", "rename", "choose"] + flagsAfterSession).contains(command) ? 1 : .max)
// The text of `sb group note` and `sb group describe` is everything after the
// group. `describe` reads flags instead when the word after the group is
// `--clear` or `--json`.
if ["group", "groups"].contains(command), ["note", "describe"].contains(argv.first) {
  a = Args(argv, literalAfter: 2)
  if argv.first == "describe", a.positional.count > 2, ["--clear", "--json"].contains(a.positional[2]) {
    a = Args(argv)
  }
}
if flagsAfterSession.contains(command), a.positional.count > 1, a.positional[1].hasPrefix("--") { a = Args(argv) }

switch command {
case "hook":
  hook()
case "ls", "list":
  let result = call("ls")
  var filter = OrgFilter(list: (a.allValues["--org"] ?? []).joined(separator: ","))
  if a.switches.contains("--local") { filter.insert(OrgFilter.localKey) }
  if a.json && filter.isAll {
    printJSON(result)
  } else {
    let shown = decode(result, as: [SessionSummary].self).filter(filter.shows)
    if a.json {
      let ids = Set(shown.map(\.id))
      printJSON(.array((result.array ?? []).filter { $0["id"]?.string.map(ids.contains) ?? false }))
    } else {
      printSessionList(shown, filter: filter)
    }
  }
case "new":
  guard let path = a.positional.first else { die("new needs a folder") }
  // With --host, the folder is on the host, which resolves its ~. sb passes it as typed.
  let host = a.values["--host"]
  let folder = host == nil ? URL(fileURLWithPath: path.expandingTilde).path : path
  let args = NewSession(
    path: folder, branch: a.values["--branch"], base: a.values["--base"], name: a.values["--name"],
    worktree: a.switches.contains("--worktree"),
    prompt: a.values["--prompt"], model: a.values["--model"],
    parent: author == .claude ? ProcessInfo.processInfo.environment["SB_SESSION_ID"] : nil,
    account: a.values["--account"], group: a.values["--group"],
    autoMode: a.switches.contains("--no-auto") ? false : nil, host: host)
  let result = call("new", (try? JSON(encoding: args).object) ?? [:], timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
case "spawn":
  spawn(a)
case "account", "accounts":
  account(a)
case "usage":
  usageCommand(a)
case "manager":
  manager(a)
case "get", "show":
  sessionCommand("get", a)
case "open":
  if a.switches.contains("--terminals") {
    printJSON(call("open", ["session": .string(a.session("open")), "terminals": true]))
  } else {
    sessionCommand("open", a)
  }
case "stop":
  sessionCommand("stop", a)
case "resume":
  sessionCommand("resume", a, extra: a.values["--prompt"].map { ["prompt": .string($0)] } ?? [:])
case "done":
  sessionCommand("done", a, extra: ["done": .bool(true)])
case "undone":
  sessionCommand("done", a, extra: ["done": .bool(false)])
case "wait":
  waitCommand(a)
case "note":
  noteCommand(a)
case "shell":
  let open = a.switches.contains("--open")
  guard open != a.switches.contains("--close") else { die("shell needs --open or --close") }
  sessionCommand("shell", a, extra: ["open": .bool(open)])
case "rename":
  guard a.positional.count >= 2 else { die("rename needs a session and a name") }
  sessionCommand("rename", a, extra: ["name": .string(a.positional.dropFirst().joined(separator: " "))])
case "issue":
  let clear = a.switches.contains("--clear")
  guard a.positional.count == (clear ? 1 : 2) else { die("issue needs a session and an issue, or --clear") }
  sessionCommand("issue", a, extra: clear ? ["clear": .bool(true)] : ["issue": .string(a.positional[1])])
case "send" where a.values["--pending"] != nil:
  awaitGroupMessage(a, id: a.values["--pending"]!)
case "send" where a.values["--group"] != nil:
  sendGroup(a, group: a.values["--group"]!)
case "send":
  sendCommand(a)
case "rm" where a.switches.contains("--done"):
  removeDone(a)
case "rm":
  var args: [String: JSON] = [
    "session": .string(a.session("rm")), "worktree": .bool(a.switches.contains("--worktree")),
    "branch": .bool(a.switches.contains("--delete-branch")),
    "remote_branch": .bool(a.switches.contains("--delete-remote-branch")),
  ]
  addResolveFlags(a, to: &args)
  let result = call("rm", args)
  if a.json { printJSON(result) } else { print("removed \(result["removed"]?.string ?? "")") }
case "merge":
  merge(a)
case "review":
  review(a)
case "ack":
  acknowledge(a)
case "cleanup":
  let result = call("cleanup", ["session": .string(a.session("cleanup"))], timeout: 300)
  if a.json { printJSON(result) } else { print("cleaned up \(result["cleaned"]?.string ?? "")") }
case "import":
  do {
    let repo = a.values["--repo"]
    if a.positional.isEmpty {
      let list = try client.importable(all: a.switches.contains("--all"), repo: repo)
      if let repo, !list.repos.contains(repo) {
        let known =
          list.repos.isEmpty ? "No repo has one." : "Repos with sessions: \(list.repos.joined(separator: ", "))."
        die("no Claude session to import in a repo named \(repo). \(known)".printable)
      }
      if a.json { printJSON(try JSON(encoding: list)) } else { printImportable(list, repo: repo) }
      exit(0)
    }
    if repo != nil { die("--repo narrows the listing, so it does not go with a session to import") }
    let stop = a.switches.contains("--stop") ? a.positional : []
    let r = try client.importSessions(a.positional, name: a.values["--name"], stop: stop)
    if a.json { printJSON(try JSON(encoding: r)) } else { r.imported.forEach(printSession) }
    r.refused.forEach { warn($0.reason.printable) }
    exit(r.refused.isEmpty ? 0 : 1)
  } catch {
    die("\(error)")
  }
case "attach":
  attach(a)
case "screen":
  let result = call(
    "screen",
    [
      "session": .string(a.session("screen")), "pane": .string(a.switches.contains("--shell") ? "shell" : "claude"),
      "colors": .bool(a.switches.contains("--colors")),
    ])
  print(result.string ?? "")
case "watch":
  watch(a)
case "events":
  events(a)
case "cards":
  cards(a)
case "triage":
  triage(a)
case "next":
  next(a)
case "choose":
  choose(a)
case "decide":
  decide(a)
case "reply":
  replyCommand(a)
case "summary":
  summaryCommand(a)
case "allow", "deny", "answer":
  answer(command, a)
case "mcp":
  mcp(a)
case "mcp-server":
  mcpServer(a)
case "host":
  host(a)
case "repo", "repos":
  repo(a)
case "autocontinue":
  autoContinue(a)
case "live":
  live(a)
case "group", "groups":
  group(a)
case "chat":
  chat(a)
case "plan", "plans":
  plan(a)
case "docket":
  docket(a)
case "followup", "followups":
  followup(a)
case "poll":
  let result = call("poll", ["all": .bool(a.switches.contains("--all"))], timeout: 300)
  if a.json {
    printJSON(result)
  } else {
    let n = { (key: String) in result[key]?.int ?? 0 }
    print(
      "read \(n("polled")) PRs and looked up \(n("lookups")) in \(n("requests")) requests for \(n("points")) points")
    if n("depotRequests") > 0 { print("read \(n("depotRuns")) Depot runs in \(n("depotRequests")) requests") }
    if n("trunkRuns") > 0 { print("read \(n("trunkRuns")) PRs from trunk") }
  }
  if let error = result["depotError"]?.string { warn(error) }
  if let error = result["trunkError"]?.string { warn(error) }
  if let error = result["codeOwnersError"]?.string { warn(error) }
  if let error = result["error"]?.string { die(error) }
case "snapshots":
  let result = call("snapshots", ["write": .bool(a.switches.contains("--write"))], timeout: 60)
  if a.json {
    printJSON(result)
  } else {
    for row in result.array ?? [] {
      print("\(row["session"]?.string ?? "")  \(row["loaded"]?.string ?? "")")
    }
  }
case "ping":
  let result = call("ping", timeout: 5)
  if a.json {
    printJSON(result)
  } else {
    print(
      "sbd \(result["version"]?.string ?? "") runs with pid \(result["pid"]?.int ?? 0), state in \(result["home"]?.string ?? "")"
    )
    if let trunk = result["trunk"]?.string { print("trunk: \(trunk)") }
  }
case "service":
  service(a)
case "version", "--version":
  print("sb \(Version.text)")
case "help", "--help", "-h":
  print(usage)
default:
  die("unknown command \(command)\n\(usage)")
}
