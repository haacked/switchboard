import Foundation
import SwitchboardCore

let usage = """
  Usage: sb <command> [arguments] [--json]

  Sessions:
    ls                            list sessions by state
    new <folder> [--branch B | --worktree] [--base REF] [--name N] [--prompt P]
        [--model M] [--account A] start a session in the folder, or in a new
                                  worktree of its repo with --branch or
                                  --worktree. --worktree names the branch from
                                  --name. It runs under the account A, else its
                                  parent's, else the active account
    account                       list the Claude accounts and the active one
    account use <name|folder> [--move | --new-only]
                                  run new sessions under this account. --move
                                  moves the sessions whose claude is stopped
                                  too. A terminal asks when neither is given
    account move <name|folder> [--dry-run]
                                  move the sessions whose claude is stopped
    usage                         show each account's use of its 5-hour and
                                  weekly limits, and when each resets
    manager                       start the Manager, a session that manages the others,
                                  or open it
    get <session>                 show one session
    send <session> <text>         send a message: paste it, queue it, or resume with it
    send --group G [--yes] <text> send a message to every session in the group, after
                                  listing them and asking. Without a terminal, or
                                  inside a Claude session, it needs --yes
    open <session>                resume the session if its claude is stopped
    stop <session>                stop the session's claude
    resume <session> [--prompt P] resume the session's claude
    done <session>, undone <session>
    wait <session> <note>         wait on something by hand
    wait [<session>] --kind K [--target T] [--who W] [--env E] [--service S]
         [--state S] [--until WHEN] [--note N] [--then resume|notify]
                                  wait on a PR, a deploy, another session, or a
                                  time. Inside a session, the session is optional
    wait <session> --clear [--id W]
    wait <session> --resolve <what happened> [--id W]
    note <session> [<text>]       add a note, or list the notes
    note <session> --rm <id>
    rename <session> <name>
    rm <session> [--worktree [--delete-branch [--delete-remote-branch]]]
                                  remove the session, and its worktree with --worktree, which refuses
                                  uncommitted files, unpushed commits, and a folder sbd didn't make.
                                  --delete-branch also deletes the local branch, and refuses unless the
                                  session's PR is merged and the branch has no commit after it.
                                  --delete-remote-branch also deletes the branch on its remote, and keeps
                                  it, with an error, unless it is at the merged PR's head
    cleanup <session>             remove the worktree and the local branch of a session whose PR merged,
                                  and keep the session in Done. Refuses uncommitted files, commits
                                  after the merge, a running turn, and a folder sbd didn't make.
    import [--all] [--repo R]     list the Claude sessions outside Switchboard that
                                  run in a worktree, or every one with --all, and
                                  only those of the repo named R with --repo
    import <ref>... [--name N] [--stop]
                                  import Claude sessions by id, id prefix, or name.
                                  --stop first exits the claude of a session that
                                  waits idle at its prompt in another terminal
    attach <session> [--shell]    attach this terminal to the Claude pane or the shell
    screen <session> [--shell]    print the pane's screen
    watch <session> --until <state> [--timeout S]
    events [--session S] [--since ID] [--follow]
                                  the newest events, or those after an id

  What needs you:
    triage                        the sessions that need you or that Claude can
                                  continue, in the order to go through them, each
                                  with a title, a summary, and options
    next                          the first of them
    choose <session> <option>     click an option, by number or label: answer the
                                  session's prompt, or send its message
    reply <session>               the session's last reply, as Markdown

  Permission prompts and questions:
    cards [<session>]             list the open ones
    allow [--card N] <session>    allow the session's permission prompt
    deny [--card N] <session> [message]
                                  deny it. With a message, Claude reads it and
                                  goes on. Without one, the turn stops.
    answer [--card N] <session> <answer>...
                                  answer the session's question, one answer per
                                  question in order. Separate the labels of a
                                  multi-select answer with commas. Text that
                                  is no option's label goes as typed.

  Groups:
    group ls                      list the groups with their sessions, then Ungrouped
    group add <name> [<session>...] [--note N]
    group rm <group>              remove the group; its sessions become ungrouped
    group move <session>... --to <group> | --ungrouped
    group note <group> <text>
    group suggest [--accept <id>] list groups suggested from branch names and PR
                                  titles, or accept one. A session that you moved
                                  to Ungrouped is never suggested

  Follow-ups, sessions that haven't started:
    followup add <text> [--title T] [--repo owner/name] [--branch B] [--on WHEN]
                 [--after owner/name#N] [--link URL] [--parent S] [--account A]
                                  add one. Without --repo, the current folder's
                                  GitHub repo. --on and --after move it to Needs
                                  you when the time passes or the PR merges
    followup ls                   list follow-ups that haven't started
    followup start <f> [--path FOLDER] [--branch B] [--base REF]
                                  make its worktree and start claude with its text
    followup rm <f>               remove a follow-up that hasn't started
    followup import [--file F]    add the open items of Followups.md that no
                                  earlier import read

  Service:
    poll [--all]                  ask GitHub and Depot about the sessions' PRs
                                  now; --all reads every PR, not only those due
    snapshots [--write]           show how the last start built each session,
                                  from a snapshot or a full replay; --write
                                  first saves a snapshot of every session
    ping                          check that sbd answers
    mcp                           list the shared MCP servers that sbd runs
    autocontinue [on|off|status]  send "Claude can continue" sessions their
                                  next step on their own, or show what holds
                                  each one back. Off by default
    service install|uninstall|status
    version

  A <session> is an id, a unique id prefix, or a unique name. For send, rename,
  and the text forms of wait, note, deny, and answer, every word after the
  session is text, so put --json and --card before the session. SB_HOME picks
  the state folder (default ~/.sb).

  Wait kinds: ci, review (needs --who), bot-review, approval, queue, merge, and
  deploy (--env dev, prod-us, prod-eu, or prod) take a PR as --target, or wait
  on the session's own PR. session takes another session as --target and a
  --state (default done). date needs --until (2h, 2026-10-26, or
  2026-10-26T09:00). manual takes an optional --until that returns it to Needs
  you. --then notify moves the session to Needs you instead of resuming it.
  """

struct Args {
  var positional: [String] = []
  var values: [String: String] = [:]
  var switches: Set<String> = []

  /// After `literalAfter` positional arguments, every argument is text, even
  /// one that starts with --. Flags for those commands go before the session.
  init(_ argv: ArraySlice<String>, literalAfter: Int = .max) {
    let valued = Set([
      "--branch", "--base", "--name", "--prompt", "--model", "--account", "--until", "--timeout", "--session",
      "--since",
      "--id", "--resolve", "--rm", "--card",
      "--title", "--repo", "--on", "--after", "--link", "--parent", "--path", "--file",
      "--group", "--to", "--note", "--accept",
    ]).union(waitFlags.keys)
    var rest = argv
    while let arg = rest.popFirst() {
      if positional.count >= literalAfter {
        positional.append(arg)
      } else if valued.contains(arg) {
        guard let value = rest.popFirst() else { die("\(arg) needs a value") }
        values[arg] = value
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

func warn(_ message: String) {
  FileHandle.standardError.write(Data("sb: \(message)\n".utf8))
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
    print(
      "  \(live) \(s.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(ago(s.since).padding(toLength: 4, withPad: " ", startingAt: 0))  \(s.reason)"
        .printable
    )
  }
}

func printSession(_ s: SessionSummary) {
  print("\(s.id)  \(s.name)".printable)
  print("  state:   \(s.state.title): \(s.reason) (\(ago(s.since)))".printable)
  if s.waitsToStart {
    printFollowup(s)
    return printWaitsAndNotes(s)
  }
  print(
    "  claude:  \(s.live ? "running, pid \(s.claudePid.map(String.init) ?? "?")" : "stopped")\(s.attached ? ", attached" : "")"
  )
  print("  folder:  \(s.cwd)")
  if let account = s.account { print("  account: \(ClaudeAccount.name(account))") }
  if let b = s.branch { print("  branch:  \(b)") }
  if let pr = s.pr { print("  pr:      \(pr.line)  \(pr.url)") }
  if let run = s.pr?.depot { print("  depot:   \(run.line)".printable) }
  for d in s.dependencies ?? [] {
    let deploy = d.deploy ? (d.deployed == true ? ", deployed" : ", deploy") : ""
    let session = d.session.map { " (session \($0))" } ?? ""
    print(
      "  depends: \(d.label(from: s.pr?.repo ?? d.repo)) \(d.state?.rawValue.lowercased() ?? "unknown")\(deploy)\(session)"
    )
  }
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
    let plain = repo?.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    let command = "sb import --all" + (repo.map { " --repo \(plain ? $0 : shellQuote($0))" } ?? "")
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
  _ = call("open", ["session": .string(id)])
  let terminals: Terminals
  do { terminals = try client.terminals(id) } catch { die("\(error)") }
  let command = terminals.attachCommand(a.switches.contains("--shell") ? .shell : .claude)
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
  var since = a.values["--since"].flatMap(Int.init)
  while true {
    var args: [String: JSON] = [:]
    if let since { args["since"] = .number(Double(since)) }
    if let s = a.values["--session"] { args["session"] = .string(s) }
    let list = decode(call("events", args), as: [Event].self)
    for e in list {
      if a.json {
        printJSON((try? JSON(encoding: e)) ?? .null)
      } else {
        let detail =
          e.data["tool_name"]?.string ?? e.data["prompt"]?.string ?? e.data["last_assistant_message"]?.string ?? e.data[
            "text"]?.string ?? ""
        print("\(e.id)  \(e.session)  \(e.kind)  \(oneLine(detail, max: 80))".printable)
      }
      since = Int(e.id)
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
// one.
let flagsAfterSession = ["wait", "note", "deny", "answer"]
var a = Args(argv, literalAfter: (["send", "rename", "choose"] + flagsAfterSession).contains(command) ? 1 : .max)
// The text of `sb group note` is everything after the group.
if ["group", "groups"].contains(command), argv.first == "note" { a = Args(argv, literalAfter: 2) }
if flagsAfterSession.contains(command), a.positional.count > 1, a.positional[1].hasPrefix("--") { a = Args(argv) }

switch command {
case "hook":
  hook()
case "ls", "list":
  let result = call("ls")
  if a.json { printJSON(result) } else { printSessionList(decode(result, as: [SessionSummary].self)) }
case "new":
  guard let path = a.positional.first else { die("new needs a folder") }
  let folder = URL(fileURLWithPath: path.expandingTilde).path
  let args = NewSession(
    path: folder, branch: a.values["--branch"], base: a.values["--base"], name: a.values["--name"],
    worktree: a.switches.contains("--worktree"),
    prompt: a.values["--prompt"], model: a.values["--model"],
    parent: author == .claude ? ProcessInfo.processInfo.environment["SB_SESSION_ID"] : nil,
    account: a.values["--account"])
  let result = call("new", (try? JSON(encoding: args).object) ?? [:], timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
case "account", "accounts":
  account(a)
case "usage":
  usageCommand(a)
case "manager":
  let result = call("manager", timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
case "get", "show":
  sessionCommand("get", a)
case "open":
  sessionCommand("open", a)
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
case "rename":
  guard a.positional.count >= 2 else { die("rename needs a session and a name") }
  sessionCommand("rename", a, extra: ["name": .string(a.positional.dropFirst().joined(separator: " "))])
case "send" where a.values["--group"] != nil:
  sendGroup(a, group: a.values["--group"]!)
case "send":
  let text = a.positional.dropFirst().joined(separator: " ")
  if text.isEmpty { die("send needs text") }
  let result = call("send", ["session": .string(a.session("send")), "text": .string(text)])
  if a.json { printJSON(result) } else { print(result["delivery"]?.string ?? "sent") }
case "rm":
  let result = call(
    "rm",
    [
      "session": .string(a.session("rm")), "worktree": .bool(a.switches.contains("--worktree")),
      "branch": .bool(a.switches.contains("--delete-branch")),
      "remote_branch": .bool(a.switches.contains("--delete-remote-branch")),
    ])
  if a.json { printJSON(result) } else { print("removed \(result["removed"]?.string ?? "")") }
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
    ["session": .string(a.session("screen")), "pane": .string(a.switches.contains("--shell") ? "shell" : "claude")])
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
case "reply":
  replyCommand(a)
case "allow", "deny", "answer":
  answer(command, a)
case "mcp":
  mcp(a)
case "autocontinue":
  autoContinue(a)
case "group", "groups":
  group(a)
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
  }
  if let error = result["depotError"]?.string { warn(error) }
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
