import Foundation
import SwitchboardCore
import Testing

/// A row of `claude agents --json`. A row with a job is a background session.
private func agent(
  _ id: String, cwd: String, name: String? = nil, pid: Int? = nil, status: String? = nil, job: String? = nil
) -> JSON {
  var row: [String: JSON] = [
    "sessionId": .string(id), "cwd": .string(cwd), "kind": .string(job == nil ? "interactive" : "background"),
    "startedAt": .number(Double(nowMs())),
  ]
  if let name { row["name"] = .string(name) }
  if let pid { row["pid"] = .number(Double(pid)) }
  if let status { row["status"] = .string(status) }
  if let job {
    row["id"] = .string(job)
    row["state"] = .string(pid == nil ? "stopped" : "blocked")
  }
  return .object(row)
}

/// A line of the main conversation. `role` is user or assistant.
private func transcriptLine(_ role: String, _ text: String, at ms: Int64) -> JSON {
  let content: JSON = role == "assistant" ? [["type": "text", "text": .string(text)]] : .string(text)
  let time = ISO8601DateFormatter()
  time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return [
    "type": .string(role), "isSidechain": false,
    "timestamp": .string(time.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))),
    "message": ["role": .string(role), "content": content],
  ]
}

/// The time in whole seconds, so that a transcript's ISO 8601 timestamp gives
/// back the same milliseconds.
private func secondsNow() -> Int64 { nowMs() / 1000 * 1000 }

private let hour: Int64 = 3600 * 1000
private let day = 24 * hour

private func newId() -> String { UUID().uuidString.lowercased() }

/// The sessions with `seen` cleared, because it holds the time of the listing.
private func unseen(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
  sessions.map { s in
    var s = s
    s.seen = 0
    return s
  }
}

private func reasons(_ result: ImportResult) -> [String: String] {
  Dictionary(result.refused.map { ($0.ref, $0.reason) }, uniquingKeysWith: { first, _ in first })
}

@Suite(.timeLimit(.minutes(2))) struct ImportTests {
  @Test func listsWorktreeSessionsByDefaultAndEverySessionWithAll() throws {
    let start = nowMs()
    let sbd = try Instance(accounts: ["A", "B"])
    let (a, b) = (sbd.account("A"), sbd.account("B"))
    let repo = try sbd.makeRepo("docket")
    let tree1 = try sbd.addWorktree(repo, "haacked/one")
    let tree2 = try sbd.addWorktree(repo, "haacked/two")
    let own = try sbd.new(name: "own")
    let me = Int(getpid())
    let (main, one, plain, two) = (newId(), newId(), newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(main, cwd: repo, name: "docket-main", pid: me, status: "idle"),
        agent(one, cwd: tree1, name: "docket-one", pid: me, status: "busy"),
        agent(plain, cwd: sbd.work, name: "scratch", pid: me, status: "waiting"),
        agent(own.claudeSessionId, cwd: sbd.work, name: "own", pid: me, status: "idle"),
      ])
    try sbd.writeAgents("B", [agent(two, cwd: tree2, name: "docket-two", job: "701cd24a")])
    let inTree1 = ClaudeSession(
      id: one, name: "docket-one", cwd: tree1, account: a, status: "busy", pid: me, repo: "docket",
      branch: "haacked/one", worktree: true)
    let inTree2 = ClaudeSession(
      id: two, name: "docket-two", cwd: tree2, account: b, job: "701cd24a", repo: "docket", branch: "haacked/two",
      worktree: true)
    let inMain = ClaudeSession(
      id: main, name: "docket-main", cwd: repo, account: a, status: "idle", pid: me, repo: "docket", branch: "main")
    let outsideGit = ClaudeSession(id: plain, name: "scratch", cwd: sbd.work, account: a, status: "waiting", pid: me)

    let worktrees = try sbd.client.importable()
    let every = try sbd.client.importable(all: true)

    #expect(unseen(worktrees.sessions) == [inTree1, inTree2])
    #expect(worktrees.hidden == 2)
    #expect(unseen(every.sessions) == [inTree1, inTree2, inMain, outsideGit])
    #expect(every.hidden == 0)
    #expect(every.sessions.allSatisfy { $0.seen >= start })
    #expect(Set(sbd.stubCalls().filter { $0.args == "agents --json" }.map(\.account)) == [a, b])
    #expect(try sbd.sb("import").contains("sb import --all"))
    let cli = try JSONCoding.decode(ImportList.self, from: sbd.sb("import", "--json"))
    #expect(unseen(cli.sessions) == [inTree1, inTree2])
    #expect(cli.hidden == 2)
    let cliAll = try JSONCoding.decode(ImportList.self, from: sbd.sb("import", "--all", "--json"))
    #expect(unseen(cliAll.sessions) == [inTree1, inTree2, inMain, outsideGit])
  }

  @Test func ordersByRepoIgnoringCaseThenByBranchElseNameElseFolder() throws {
    let sbd = try Instance(accounts: ["A"])
    let docket = try sbd.addWorktree(try sbd.makeRepo("docket"), "haacked/b-fix")
    let zed = try sbd.addWorktree(try sbd.makeRepo("Zed"), "a-fix")
    for folder in ["first", "second", "third"] {
      try FileManager.default.createDirectory(atPath: "\(sbd.work)/\(folder)", withIntermediateDirectories: true)
    }
    let ids = (docket: newId(), zed: newId(), unnamed: newId(), alpha: newId(), beta: newId())
    // A sort by name alone, by folder alone, by branch alone, or by repo with
    // case gives another order.
    try sbd.writeAgents(
      "A",
      [
        agent(ids.beta, cwd: "\(sbd.work)/first", name: "beta", job: "00000001"),
        agent(ids.zed, cwd: zed, name: "aaa", job: "00000002"),
        agent(ids.alpha, cwd: "\(sbd.work)/second", name: "alpha", job: "00000003"),
        agent(ids.docket, cwd: docket, name: "zzz", job: "00000004"),
        agent(ids.unnamed, cwd: "\(sbd.work)/third", job: "00000005"),
      ])

    let order = try sbd.client.importable(all: true).sessions.map(\.id)

    #expect(order == [ids.docket, ids.zed, ids.unnamed, ids.alpha, ids.beta])
  }

  @Test func findsTheRepoAndBranchFromAnyFolderInsideACheckout() throws {
    let sbd = try Instance(accounts: ["A"])
    let a = sbd.account("A")
    let repo = try sbd.makeRepo("docket")
    let tree = try sbd.addWorktree(repo, "haacked/one")
    let detached = "\(sbd.home.path)/trees/docket/detached"
    try sbd.git(repo, "worktree", "add", "--detach", detached)
    let bare = "\(sbd.home.path)/bare/docket.git"
    try sbd.git(sbd.home.path, "clone", "-q", "--bare", repo, bare)
    let bareTree = "\(sbd.home.path)/trees/bare/haacked/two"
    try sbd.git(bare, "worktree", "add", "-b", "haacked/two", bareTree)
    for folder in ["\(repo)/Sources", "\(tree)/Sources"] {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    let (inTree, inMain, inDetached, inBareTree) = (newId(), newId(), newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(inTree, cwd: "\(tree)/Sources", job: "00000001"),
        agent(inMain, cwd: "\(repo)/Sources", job: "00000002"),
        agent(inDetached, cwd: detached, job: "00000003"),
        agent(inBareTree, cwd: bareTree, job: "00000004"),
      ])
    let expected = [
      ClaudeSession(
        id: inTree, cwd: "\(tree)/Sources", account: a, job: "00000001", repo: "docket", branch: "haacked/one",
        worktree: true),
      ClaudeSession(id: inMain, cwd: "\(repo)/Sources", account: a, job: "00000002", repo: "docket", branch: "main"),
      ClaudeSession(id: inDetached, cwd: detached, account: a, job: "00000003", repo: "docket", worktree: true),
      ClaudeSession(
        id: inBareTree, cwd: bareTree, account: a, job: "00000004", repo: "docket", branch: "haacked/two",
        worktree: true),
    ]

    let found = unseen(try sbd.client.importable(all: true).sessions)

    #expect(found.sorted { $0.id < $1.id } == expected.sorted { $0.id < $1.id })
  }

  @Test func listsTheDefaultAccountWithClaudeConfigDirUnset() throws {
    let sbd = try Instance(accounts: ["A"])
    try sbd.restart(setting: "claudeConfigDirs", to: JSON.array(["~/.claude", .string(sbd.account("A"))]))

    _ = try sbd.client.importable()

    // The stub prints [] for the default account, because /agents.json doesn't exist.
    let accounts = sbd.stubCalls().filter { $0.args == "agents --json" }.map(\.account)
    #expect(Set(accounts) == ["", sbd.account("A")])
  }

  @Test func offersNoRememberedSessionOfAnAccountThatSbdNoLongerLists() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    let id = newId()
    try sbd.writeAgents("B", [agent(id, cwd: sbd.work, name: "elsewhere", pid: Int(getpid()), status: "idle")])
    #expect(try sbd.client.importable(all: true).sessions.map(\.id) == [id])
    try sbd.restart(setting: "claudeConfigDirs", to: JSON.array([.string(sbd.account("A"))]))

    let listed = try sbd.client.importable(all: true).sessions
    let result = try sbd.client.importSessions(["elsewhere"])

    // B's claude may still run the session, and sbd no longer asks B.
    #expect(listed.isEmpty)
    #expect(reasons(result) == ["elsewhere": "no Claude session matches elsewhere"])
  }

  @Test func forgetsASessionThatNoAccountListedForADay() throws {
    let sbd = try Instance(accounts: ["A"])
    sbd.stopSbd()
    let now = nowMs()
    let a = sbd.account("A")
    let recent = ClaudeSession(id: newId(), name: "recent", cwd: sbd.work, account: a, seen: now - (day - hour))
    let old = ClaudeSession(id: newId(), name: "old", cwd: sbd.work, account: a, seen: now - (day + hour))
    try Store(path: sbd.home.database).save(claudeSessions: [recent, old])
    try sbd.startSbd()

    let listed = try sbd.client.importable(all: true).sessions.map(\.id)
    let result = try sbd.client.importSessions(["old"])

    #expect(listed == [recent.id])
    #expect(reasons(result) == ["old": "no Claude session matches old"])
  }

  @Test func remembersASessionForADayAfterTheLastListingThatShowedIt() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "notes")])
    _ = try sbd.client.importable(all: true)
    try sbd.advanceClock(day - hour)
    _ = try sbd.client.importable(all: true)
    try sbd.writeAgents("A", [])
    try sbd.advanceClock(2 * hour)

    #expect(try sbd.client.importable(all: true).sessions.map(\.id) == [id])
  }

  @Test func importsASessionThatNoClaudeRunsAndResumesItUnderItsAccount() throws {
    let sbd = try Instance(accounts: ["A"])
    try sbd.restart(setting: "env", to: ["CLAUDE_CONFIG_DIR": .string("\(sbd.home.path)/env-account")])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/parser")
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: tree, name: "parser-work", job: "0badf00d")])
    let now = secondsNow()
    try sbd.writeTranscript(
      "A", id,
      [
        transcriptLine("user", "Write the parser.", at: now - 60_000),
        transcriptLine("assistant", "I wrote the parser. Want me to run the tests?", at: now - 30_000),
      ])
    #expect(try sbd.client.importable().sessions.map(\.id) == [id])

    let result = try sbd.client.importSessions([String(id.prefix(8))])

    #expect(result.refused.isEmpty)
    #expect(result.imported.count == 1)
    let s = try #require(result.imported.first)
    #expect(s.name == "haacked/parser")
    #expect(s.cwd == tree)
    #expect(s.branch == "haacked/parser")
    #expect(s.claudeSessionId == id)
    #expect(s.repo == nil)
    #expect(!s.live)
    #expect(s.state == .canContinue)
    #expect(s.reason == "offered: Want me to run the tests?")
    #expect(!sbd.stubCalls().contains { $0.args.hasPrefix("--resume") })
    #expect(try !sbd.client.importable(all: true).sessions.contains { $0.id == id })

    #expect(try sbd.sb("send", s.id, "run them") == "resumed\n")
    try sbd.waitFor(s.id, "the resumed turn's reply") { $0.lastReply == "Done: run them" }
    let resume = try #require(sbd.stubCalls().last { !$0.args.hasPrefix("agents") })
    #expect(resume.args == "--resume \(id) --settings \(sbd.home.claudeSettings) -- run them")
    #expect(resume.account == sbd.account("A"))
  }

  @Test func startsAnImportedSessionThatHasNoTranscriptWithItsId() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "unprompted", job: "0badf00d")])
    let s = try #require(try sbd.client.importSessions([id]).imported.first)

    #expect(try sbd.sb("send", s.id, "begin") == "resumed\n")
    try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: begin" }
    let start = try #require(sbd.stubCalls().last { !$0.args.hasPrefix("agents") })
    #expect(start.args == "--session-id \(id) --settings \(sbd.home.claudeSettings) -- begin")
  }

  @Test func namesAnImportedSessionByItsBranchElseClaudesNameElseItsFolder() throws {
    let sbd = try Instance(accounts: ["A"])
    let repo = try sbd.makeRepo()
    let tree = try sbd.addWorktree(repo, "haacked/parser")
    let (inTree, inMain, unnamed, renamed) = (newId(), newId(), newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(inTree, cwd: tree, name: "parser-work", job: "00000001"),
        agent(inMain, cwd: repo, name: "repo-main", job: "00000002"),
        agent(unnamed, cwd: sbd.work, job: "00000003"),
        agent(renamed, cwd: tree, name: "to-rename", job: "00000004"),
      ])

    #expect(try sbd.client.importSessions([inTree]).imported.map(\.name) == ["haacked/parser"])
    // A main checkout has a branch, but only a worktree session takes its name from the branch.
    #expect(try sbd.client.importSessions(["repo-main"]).imported.map(\.name) == ["repo-main"])
    #expect(try sbd.client.importSessions([String(unnamed.prefix(8))]).imported.map(\.name) == ["work"])
    let named = try JSONCoding.decode(
      ImportResult.self, from: sbd.sb("import", "--json", String(renamed.prefix(8)), "--name", "notes"))
    #expect(named.imported.map(\.name) == ["notes"])
  }

  @Test func marksAnImportedSessionStaleByItsTranscriptTimeAcrossARestart() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "old-work", job: "0badf00d")])
    let old = secondsNow() - 3 * day
    try sbd.writeTranscript(
      "A", id,
      [
        transcriptLine("user", "Fix it.", at: old - 60_000),
        transcriptLine("assistant", "Fixed. Want me to push?", at: old),
      ])

    let s = try #require(try sbd.client.importSessions([id]).imported.first)

    #expect(s.state == .stale)
    #expect(s.lastActivity == old)
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.get(s.id)
    #expect(after.state == .stale)
    #expect(after.lastActivity == old)
    #expect(after.lastReply == "Fixed. Want me to push?")
  }

  @Test func refusesASessionWhoseClaudeStillRunsAndImportsItAfterClaudeExits() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/held")
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
    holder.arguments = ["60"]
    try holder.run()
    defer { if holder.isRunning { holder.terminate() } }
    let pid = Int(holder.processIdentifier)
    let gone = "\(sbd.home.path)/gone"
    let ids = (live: newId(), job: newId(), twice: newId(), again: newId(), unnamed: newId())
    let job = agent(ids.job, cwd: tree, name: "job", pid: pid, status: "busy", job: "deadbeef")
    try sbd.writeAgents(
      "A",
      [
        agent(ids.live, cwd: tree, name: "live", pid: pid, status: "idle"),
        job,
        agent(ids.twice, cwd: tree, name: "twice"),
        agent(ids.again, cwd: sbd.work, name: "again", pid: pid, status: "idle"),
        agent(ids.unnamed, cwd: sbd.work, pid: pid, status: "idle"),
        agent(newId(), cwd: gone, name: "gone"),
        agent(newId(), cwd: sbd.work, name: "dup"),
        agent(newId(), cwd: sbd.work, name: "dup"),
      ])
    // Both accounts list "twice" and "again". The row whose claude runs is in B for one and in A for the other.
    try sbd.writeAgents(
      "B",
      [
        agent(ids.twice, cwd: tree, name: "twice", pid: pid, status: "idle"),
        agent(ids.again, cwd: sbd.work, name: "again"),
      ])
    func held(_ label: String, in cwd: String) -> String {
      "\(label) runs in another terminal, in \(cwd) (pid \(pid)). Exit claude there, then import it."
    }
    // These sessions are idle, and the busy background job "job" runs in the same claude.
    func shared(_ label: String) -> String {
      "\(label) shares its claude (pid \(pid)) with job, which import can't exit. Exit claude there, then import it."
    }

    let stop = "`CLAUDE_CONFIG_DIR='\(sbd.account("A"))' claude stop deadbeef`"
    let expected: [String: String] = [
      "live": shared("live"),
      "job": "job runs as background job deadbeef. Stop it with \(stop), then import it.",
      "twice": shared("twice"),
      "again": shared("again"),
      ids.unnamed: shared(String(ids.unnamed.prefix(8))),
      "gone": "gone's folder \(gone) no longer exists.",
      "dup": "dup matches 2 Claude sessions",
      "nothing": "no Claude session matches nothing",
    ]

    let result = try sbd.client.importSessions(["live", "job", "twice", "again", ids.unnamed, "gone", "dup", "nothing"])

    #expect(result.imported.isEmpty)
    #expect(reasons(result) == expected)
    let cli = try sbd.run("import", "live")
    #expect(cli.status == 1)
    #expect(cli.stderr.contains(shared("live")))
    #expect(try sbd.client.sessions().isEmpty)

    holder.terminate()
    holder.waitUntilExit()
    // A keeps the record of "job" with its claude's pid, which no longer runs.
    try sbd.writeAgents("A", [job])
    try sbd.writeAgents("B", [])
    sbd.stopSbd()
    try sbd.startSbd()
    let remembered = try sbd.client.importable().sessions
    #expect(remembered.map(\.id) == [ids.live, ids.job, ids.twice].sorted())
    #expect(remembered.allSatisfy { $0.pid == nil && $0.status == nil })

    let imported = try sbd.client.importSessions(["live", "job"])

    #expect(imported.refused.isEmpty)
    #expect(Set(imported.imported.map(\.claudeSessionId)) == [ids.live, ids.job])
  }

  /// A process whose command starts with `argv0`. The stub claude's name makes it look like the claude that
  /// `claude agents` lists.
  private func stubClaude(
    argv0: String = "claude-stub", ignoringTerm: Bool = false, backgroundTask: Bool = false
  ) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    // With job control on, a background command leads its own process group, as a background Bash job does.
    let task = backgroundTask ? "set -m; sleep 20 & " : ""
    p.arguments = ["-c", "\(task)\(ignoringTerm ? "trap '' TERM; " : "")exec -a '\(argv0)' sleep 60"]
    try p.run()
    let pid = p.processIdentifier
    for _ in 0..<100 {
      let r = try runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="])
      if r.stdout.hasPrefix(argv0) { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return p
  }

  @Test func stopExitsOnlyAnIdleInteractiveClaudeThatRunsTheSession() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/idle")
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["60"]
    try sleeper.run()
    let (idle, busy, waiting, job, ignores, other) =
      (
        try stubClaude(), try stubClaude(), try stubClaude(), try stubClaude(), try stubClaude(ignoringTerm: true),
        try stubClaude()
      )
    // `tail claude-stub` has the claude command as an argument, which is not claude. `node claude-stub` is.
    let (lookalike, viaNode) = (try stubClaude(argv0: "tail claude-stub"), try stubClaude(argv0: "node claude-stub"))
    let all = [idle, busy, waiting, job, ignores, other, sleeper, lookalike, viaNode]
    defer { for p in all where p.isRunning { p.terminate() } }
    func pid(_ p: Process) -> Int { Int(p.processIdentifier) }
    let ids = (
      idle: newId(), busy: newId(), waiting: newId(), job: newId(), ignores: newId(), other: newId(), reused: newId(),
      lookalike: newId(), viaNode: newId()
    )
    try sbd.writeAgents(
      "A",
      [
        agent(ids.idle, cwd: tree, name: "idle", pid: pid(idle), status: "idle"),
        agent(ids.busy, cwd: tree, name: "busy", pid: pid(busy), status: "busy"),
        agent(ids.waiting, cwd: tree, name: "waiting", pid: pid(waiting), status: "waiting"),
        agent(ids.job, cwd: tree, name: "job", pid: pid(job), status: "idle", job: "deadbeef"),
        agent(ids.ignores, cwd: tree, name: "ignores", pid: pid(ignores), status: "idle"),
        agent(ids.other, cwd: tree, name: "other", pid: pid(other), status: "idle"),
        // The pid belongs to a process that is not a claude, as after a reboot or a crash.
        agent(ids.reused, cwd: tree, name: "reused", pid: pid(sleeper), status: "idle"),
        agent(ids.lookalike, cwd: tree, name: "lookalike", pid: pid(lookalike), status: "idle"),
        agent(ids.viaNode, cwd: tree, name: "viaNode", pid: pid(viaNode), status: "idle"),
      ])
    let names = ["idle", "busy", "waiting", "job", "ignores", "other", "reused", "lookalike", "viaNode"]

    // "other" is listed, but its ref is not in the stop list, so its claude stays.
    let result = try sbd.client.importSessions(names, stop: names.filter { $0 != "other" })

    #expect(Set(result.imported.map(\.claudeSessionId)) == [ids.idle, ids.viaNode])
    #expect(Set(reasons(result).keys) == ["busy", "waiting", "job", "ignores", "other", "reused", "lookalike"])
    #expect(reasons(result)["ignores"]?.contains("didn't exit after SIGTERM") == true)
    #expect(reasons(result)["reused"]?.contains("is not a claude") == true)
    idle.waitUntilExit()
    #expect(idle.terminationReason == .uncaughtSignal && idle.terminationStatus == SIGTERM)
    viaNode.waitUntilExit()
    #expect(viaNode.terminationReason == .uncaughtSignal)
    for p in [busy, waiting, job, ignores, other, sleeper, lookalike] { #expect(p.isRunning) }
    let cli = try sbd.run("import", "busy", "--stop")
    #expect(cli.status == 1)
    #expect(busy.isRunning)
  }

  @Test func stopRefusesAnIdleClaudeThatRunsABackgroundTask() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/task")
    let (withTask, plain) = (try stubClaude(backgroundTask: true), try stubClaude())
    defer { for p in [withTask, plain] where p.isRunning { p.terminate() } }
    let (taskId, plainId) = (newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(taskId, cwd: tree, name: "task", pid: Int(withTask.processIdentifier), status: "idle"),
        agent(plainId, cwd: tree, name: "plain", pid: Int(plain.processIdentifier), status: "idle"),
      ])

    let result = try sbd.client.importSessions(["task", "plain"], stop: ["task", "plain"])

    #expect(result.imported.map(\.claudeSessionId) == [plainId])
    #expect(reasons(result)["task"]?.contains("runs a background task") == true)
    #expect(withTask.isRunning)
  }

  @Test func stopRefusesWhenTmuxCannotTellWhetherSwitchboardOwnsTheClaude() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/tmux")
    // A Switchboard session starts the tmux server.
    let socket = try sbd.client.terminals(try sbd.new().id).socket
    let external = try stubClaude()
    defer { if external.isRunning { external.terminate() } }
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: tree, name: "ext", pid: Int(external.processIdentifier), status: "idle")])
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: socket)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket) }

    let refused = try sbd.client.importSessions(["ext"], stop: ["ext"])

    #expect(refused.imported.isEmpty)
    #expect(reasons(refused)["ext"]?.contains("can't list its own terminals") == true)
    #expect(external.isRunning)

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket)
    let imported = try sbd.client.importSessions(["ext"], stop: ["ext"])

    #expect(imported.imported.map(\.claudeSessionId) == [id])
    external.waitUntilExit()
    #expect(external.terminationReason == .uncaughtSignal)
  }

  @Test func stopNeverSignalsSbdInitOrTheClaudeOfASwitchboardSession() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/own")
    // A Switchboard session runs a claude of its own, which an external row can list by mistake.
    let own = try sbd.new()
    let ownPid = try #require(try sbd.waitFor(own.id, "claude's pid") { $0.claudePid != nil }.claudePid)
    let ids = (sbd: newId(), init: newId(), own: newId())
    try sbd.writeAgents(
      "A",
      [
        agent(ids.sbd, cwd: tree, name: "sbd", pid: sbd.sbdPid, status: "idle"),
        agent(ids.`init`, cwd: tree, name: "init", pid: 1, status: "idle"),
        agent(ids.own, cwd: tree, name: "own", pid: ownPid, status: "idle"),
      ])
    let names = ["sbd", "init", "own"]

    let result = try sbd.client.importSessions(names, stop: names)

    #expect(result.imported.isEmpty)
    #expect(Set(reasons(result).keys) == Set(names))
    #expect(Processes.exists(ownPid) && Processes.exists(sbd.sbdPid))
    #expect(try sbd.get(own.id).live)
  }

  @Test func aPidOutsideTheRangeOfProcessesCountsAsNoClaudeAndDoesNotCrashSbd() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/range")
    let pids = [0, -1, 5_000_000_000]
    let ids = pids.map { _ in newId() }
    try sbd.writeAgents(
      "A", zip(ids, pids).map { agent($0, cwd: tree, name: "p\($1)", pid: $1, status: "idle") })

    let listed = try sbd.client.importable().sessions

    #expect(listed.count == 3 && listed.allSatisfy { !$0.running })
    let result = try sbd.client.importSessions(pids.map { "p\($0)" }, stop: pids.map { "p\($0)" })
    #expect(result.refused.isEmpty && result.imported.count == 3)
    #expect(try sbd.client.call("ping") != nil)
  }

  @Test func stopLeavesAClaudeRunningWhoseOtherSessionOnlyTheStopListNames() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/scope")
    let claude = try stubClaude()
    defer { if claude.isRunning { claude.terminate() } }
    let pid = Int(claude.processIdentifier)
    let (first, second) = (newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(first, cwd: tree, name: "first", pid: pid, status: "idle"),
        agent(second, cwd: tree, name: "second", pid: pid, status: "idle"),
      ])

    // "second" is in the stop list but not among the sessions to import.
    let named = try sbd.client.importSessions(["first"], stop: ["first", "second"])
    // An empty entry in the stop list names no session.
    let empty = try sbd.client.importSessions(["first"], stop: ["", "first"])

    #expect(named.imported.isEmpty && empty.imported.isEmpty)
    #expect(reasons(named)["first"]?.contains("Import both together") == true)
    #expect(reasons(empty)["first"]?.contains("Import both together") == true)
    #expect(claude.isRunning)
  }

  @Test func stopRefusesAClaudeThatAnUnnamedIdleSessionAlsoRunsInAndImportsBothWhenNamed() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/pair")
    let claude = try stubClaude()
    defer { if claude.isRunning { claude.terminate() } }
    let pid = Int(claude.processIdentifier)
    let (first, second) = (newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(first, cwd: tree, name: "first", pid: pid, status: "idle"),
        agent(second, cwd: tree, name: "second", pid: pid, status: "idle"),
      ])

    let refused = try sbd.client.importSessions(["first"], stop: ["first"])

    #expect(refused.imported.isEmpty)
    #expect(reasons(refused)["first"]?.contains("Import both together") == true)
    #expect(claude.isRunning)

    let both = try sbd.client.importSessions(["first", "second"], stop: ["first", "second"])

    #expect(Set(both.imported.map(\.claudeSessionId)) == [first, second])
    claude.waitUntilExit()
    #expect(claude.terminationReason == .uncaughtSignal)
  }

  @Test func stopKeepsTheBusyRowWhenTwoAccountsListOneSessionWithOnePid() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/twice")
    let (first, second) = (try stubClaude(), try stubClaude())
    defer { for p in [first, second] where p.isRunning { p.terminate() } }
    let (idleFirst, busyFirst) = (newId(), newId())
    // Each session is idle in one account and busy in the other, in both orders.
    try sbd.writeAgents(
      "A",
      [
        agent(idleFirst, cwd: tree, name: "idleFirst", pid: Int(first.processIdentifier), status: "idle"),
        agent(busyFirst, cwd: tree, name: "busyFirst", pid: Int(second.processIdentifier), status: "busy"),
      ])
    try sbd.writeAgents(
      "B",
      [
        agent(idleFirst, cwd: tree, name: "idleFirst", pid: Int(first.processIdentifier), status: "busy"),
        agent(busyFirst, cwd: tree, name: "busyFirst", pid: Int(second.processIdentifier), status: "idle"),
      ])

    let result = try sbd.client.importSessions(["idleFirst", "busyFirst"], stop: ["idleFirst", "busyFirst"])

    #expect(result.imported.isEmpty)
    #expect(Set(reasons(result).keys) == ["idleFirst", "busyFirst"])
    #expect(first.isRunning && second.isRunning)
  }

  @Test func stopKeepsEveryPidOfASessionThatTwoAccountsListWithDifferentPids() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/pids")
    let (busy1, busy2, idle1, idle2) = (try stubClaude(), try stubClaude(), try stubClaude(), try stubClaude())
    defer { for p in [busy1, busy2, idle1, idle2] where p.isRunning { p.terminate() } }
    func pid(_ p: Process) -> Int { Int(p.processIdentifier) }
    let (busy, stale, both) = (newId(), newId(), newId())
    // "busy" runs in two claudes. A stale idle row "stale" holds the pid of the second.
    try sbd.writeAgents(
      "A",
      [
        agent(busy, cwd: tree, name: "busy", pid: pid(busy1), status: "busy"),
        agent(stale, cwd: tree, name: "stale", pid: pid(busy2), status: "idle"),
        agent(both, cwd: tree, name: "both", pid: pid(idle1), status: "idle"),
      ])
    try sbd.writeAgents(
      "B",
      [
        agent(busy, cwd: tree, name: "busy", pid: pid(busy2), status: "busy"),
        agent(both, cwd: tree, name: "both", pid: pid(idle2), status: "idle"),
      ])

    let result = try sbd.client.importSessions(["busy", "stale", "both"], stop: ["busy", "stale", "both"])

    // "both" is idle in two claudes, so import exits both before it imports the session.
    #expect(result.imported.map(\.claudeSessionId) == [both])
    #expect(Set(reasons(result).keys) == ["busy", "stale"])
    idle1.waitUntilExit()
    idle2.waitUntilExit()
    #expect(idle1.terminationReason == .uncaughtSignal && idle2.terminationReason == .uncaughtSignal)
    #expect(busy1.isRunning && busy2.isRunning)
  }

  @Test func stopRefusesAnIdleSessionWhosePidAnotherListedSessionThatIsBusyShares() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    let tree = try sbd.addWorktree(try sbd.makeRepo(), "haacked/shared")
    let shared = try stubClaude()
    defer { if shared.isRunning { shared.terminate() } }
    let pid = Int(shared.processIdentifier)
    let (stale, live) = (newId(), newId())
    try sbd.writeAgents("A", [agent(stale, cwd: tree, name: "stale", pid: pid, status: "idle")])
    try sbd.writeAgents("B", [agent(live, cwd: tree, name: "live", pid: pid, status: "busy")])

    let result = try sbd.client.importSessions(["stale"], stop: ["stale"])

    #expect(result.imported.isEmpty)
    #expect(reasons(result)["stale"]?.contains("shares its claude") == true)
    #expect(reasons(result)["stale"]?.contains("--stop") == false)
    #expect(shared.isRunning)
  }

  @Test func failsWhenAnAccountsClaudeAgentsOutputIsNotJSON() throws {
    let sbd = try Instance(accounts: ["A", "B"])
    try sbd.writeAgents("A", [agent(newId(), cwd: sbd.work, name: "fine", job: "00000001")])
    try "not json".write(toFile: "\(sbd.account("B"))/agents.json", atomically: true, encoding: .utf8)

    let listing = try #require(throws: APIError.self) { try sbd.client.importable() }
    let importing = try #require(throws: APIError.self) { try sbd.client.importSessions(["fine"]) }
    let cli = try sbd.run("import")

    #expect(listing.description.contains(sbd.account("B")))
    #expect(importing.description.contains(sbd.account("B")))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(cli.status == 1)
    #expect(cli.stderr.contains(sbd.account("B")))
  }

  @Test func refusesARefForASessionAlreadyInSwitchboard() throws {
    let sbd = try Instance(accounts: ["A"])
    let own = try sbd.new(name: "own")
    let id = newId()
    let prefix = String(id.prefix(8))
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "notes", job: "0badf00d")])
    let first = try #require(try sbd.client.importSessions([id]).imported.first)
    let expected: [String: String] = [
      id: "\(id) is already in Switchboard as \(first.id)",
      prefix: "\(prefix) is already in Switchboard as \(first.id)",
      "notes": "notes is already in Switchboard as \(first.id)",
      own.claudeSessionId: "\(own.claudeSessionId) is already in Switchboard as \(own.id)",
    ]

    let again = try sbd.client.importSessions([id, prefix, "notes", own.claudeSessionId])

    #expect(again.imported.isEmpty)
    #expect(reasons(again) == expected)
  }

  @Test func refusesToListAnAccountFolderThatHoldsNoClaudeAccount() throws {
    let sbd = try Instance()
    let folder = "\(sbd.home.path)/no-account"
    try sbd.restart(setting: "claudeConfigDirs", to: [.string(folder)])

    let error = try #require(throws: APIError.self) { try sbd.client.importable() }

    #expect(error.description.hasPrefix("\(folder) holds no Claude account"))
    #expect(!sbd.stubCalls().contains { $0.args.hasPrefix("agents") })
  }

  @Test func importsSeveralSessionsInOneRequestEachFromItsOwnTranscript() throws {
    let sbd = try Instance(accounts: ["A"])
    let (one, two) = (newId(), newId())
    let (folderOne, folderTwo) = ("\(sbd.work)/one", "\(sbd.work)/two")
    for folder in [folderOne, folderTwo] {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    try sbd.writeAgents(
      "A",
      [
        agent(one, cwd: folderOne, name: "one", job: "00000001"),
        agent(two, cwd: folderTwo, name: "two", job: "00000002"),
      ])
    let now = secondsNow()
    try sbd.writeTranscript("A", one, [transcriptLine("assistant", "Want me to run the tests?", at: now - 30_000)])
    try sbd.writeTranscript("A", two, [transcriptLine("assistant", "Which database should I use?", at: now - 30_000)])

    let result = try sbd.client.importSessions([two, "nope", one])

    #expect(reasons(result) == ["nope": "no Claude session matches nope"])
    #expect(result.imported.map(\.claudeSessionId) == [two, one])
    #expect(result.imported.map(\.cwd) == [folderTwo, folderOne])
    #expect(
      result.imported.map(\.reason) == ["answer: Which database should I use?", "offered: Want me to run the tests?"])
  }

  @Test func refusesAConversationThatTwoSwitchboardSessionsHold() throws {
    let sbd = try Instance(accounts: ["A"])
    let first = try sbd.new(prompt: "hello")
    let second = try sbd.new(prompt: "hello")
    try sbd.waitFor(second.id, "the first reply") { $0.lastReply == "Done: hello" }
    // `/clear` or `/resume` in a pane can switch it to another session's conversation.
    let id = first.claudeSessionId
    try sbd.sb("send", second.id, "clear \(id)")
    try sbd.waitFor(second.id, "the shared conversation") { $0.claudeSessionId == id }
    let prefix = String(id.prefix(8))
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "shared", job: "0badf00d")])

    #expect(try sbd.client.importable(all: true).sessions.isEmpty)
    // A ref to a conversation that claude doesn't list finds its owner by the ref.
    try sbd.writeAgents("A", [])
    let result = try sbd.client.importSessions([id, prefix])
    #expect(result.imported.isEmpty)
    for (ref, reason) in reasons(result) {
      #expect(reason.hasPrefix("\(ref) is already in Switchboard as "))
    }
  }

  @Test func importsASessionOnceWhenTwoRefsInOneRequestNameIt() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "notes", job: "0badf00d")])

    let result = try sbd.client.importSessions([id, "notes"])

    #expect(result.refused.isEmpty)
    #expect(result.imported.map(\.claudeSessionId) == [id])
    #expect(try sbd.client.sessions().filter { $0.claudeSessionId == id }.count == 1)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "Times out on the CI runner. Run it locally."))
  func importsASessionOnceWhenTwoRequestsRaceForIt() async throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "notes", job: "0badf00d")])
    let client = sbd.client

    async let first = Task.detached { try client.importSessions([id]) }.value
    async let second = Task.detached { try client.importSessions([id]) }.value
    let results = try await [first, second]

    #expect(results.flatMap(\.imported).count == 1)
    #expect(results.flatMap(\.refused).count == 1)
    #expect(try sbd.client.sessions().filter { $0.claudeSessionId == id }.count == 1)
  }

  @Test func rejectsAnImportWithNoRefsOrWithANameForSeveralRefs() throws {
    let sbd = try Instance(accounts: ["A"])
    try sbd.writeAgents(
      "A",
      [
        agent(newId(), cwd: sbd.work, name: "one", job: "00000001"),
        agent(newId(), cwd: sbd.work, name: "two", job: "00000002"),
      ])

    #expect(throws: APIError.self) { try sbd.client.importSessions([]) }
    #expect(throws: APIError.self) { try sbd.client.call("import") }
    #expect(throws: APIError.self) { try sbd.client.importSessions(["one", "two"], name: "both") }
    #expect(try sbd.run("import", "one", "two", "--name", "both").status == 1)
    #expect(try sbd.client.sessions().isEmpty)
  }

  @Test func repoNarrowsTheListingToOneRepoAndCountsOnlyItsHiddenSessions() throws {
    let sbd = try Instance(accounts: ["A"])
    let board = try sbd.makeRepo("switchboard")
    let boardTree = try sbd.addWorktree(board, "haacked/one")
    let docket = try sbd.makeRepo("docket")
    let docketTree = try sbd.addWorktree(docket, "haacked/two")
    let (inTree, inMain, other, otherMain, plain) = (newId(), newId(), newId(), newId(), newId())
    try sbd.writeAgents(
      "A",
      [
        agent(inTree, cwd: boardTree, name: "board-one", job: "00000001"),
        agent(inMain, cwd: board, name: "board-main", job: "00000002"),
        agent(other, cwd: docketTree, name: "docket-two", job: "00000003"),
        agent(otherMain, cwd: docket, name: "docket-main", job: "00000004"),
        agent(plain, cwd: sbd.work, name: "scratch", job: "00000005"),
      ])

    let worktrees = try JSONCoding.decode(ImportList.self, from: sbd.sb("import", "--repo", "switchboard", "--json"))
    let every = try JSONCoding.decode(
      ImportList.self, from: sbd.sb("import", "--all", "--repo", "switchboard", "--json"))
    let text = try sbd.sb("import", "--repo", "switchboard")
    let viaClient = try sbd.client.importable(repo: "switchboard")

    #expect(worktrees.sessions.map(\.id) == [inTree])
    #expect(worktrees.hidden == 1)
    #expect(worktrees.repos == ["docket", "switchboard"])
    #expect(every.sessions.map(\.id) == [inTree, inMain])
    #expect(every.hidden == 0)
    #expect(viaClient.sessions.map(\.id) == [inTree])
    #expect(text.contains("haacked/one"))
    #expect(!text.contains("haacked/two"))
    #expect(text.contains("sb import --all --repo switchboard"))
  }

  @Test func repoMatchesTheNameExactlyAndNamesTheReposThatHaveSessionsWhenNoneMatch() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo("switchboard"), "haacked/one")
    try sbd.writeAgents("A", [agent(newId(), cwd: tree, name: "board-one", job: "00000001")])

    for repo in ["Switchboard", "switch", "nope"] {
      let r = try sbd.run("import", "--repo", repo)
      #expect(r.status == 1)
      #expect(r.stderr.contains("no Claude session to import in a repo named \(repo)"))
      #expect(r.stderr.contains("switchboard"))
      #expect(r.stdout.isEmpty)
      let json = try sbd.run("import", "--all", "--repo", repo, "--json")
      #expect(json.status == 1)
      #expect(json.stdout.isEmpty)
    }
  }

  @Test func repoWithNoSessionsAnywhereSaysSo() throws {
    let sbd = try Instance(accounts: ["A"])
    try sbd.writeAgents("A", [])

    let r = try sbd.run("import", "--repo", "switchboard")

    #expect(r.status == 1)
    #expect(r.stderr.contains("no Claude session to import in a repo named switchboard"))
    #expect(r.stderr.contains("No repo has one."))
  }

  @Test func repoNameWithASpaceIsQuotedInTheHintSoThatTheHintRuns() throws {
    let sbd = try Instance(accounts: ["A"])
    let main = try sbd.makeRepo("my repo")
    try sbd.writeAgents("A", [agent(newId(), cwd: main, name: "spaced-main", job: "00000001")])

    let hint = try sbd.sb("import", "--repo", "my repo")
    let all = try sbd.run("import", "--all", "--repo", "my repo", "--json")

    #expect(hint.contains("sb import --all --repo 'my repo'"))
    #expect(all.status == 0)
    #expect(try JSONCoding.decode(ImportList.self, from: all.stdout).sessions.count == 1)
  }

  @Test func repoWithSessionsOnlyOutsideAWorktreeListsNoneAndPointsToAll() throws {
    let sbd = try Instance(accounts: ["A"])
    let main = try sbd.makeRepo("switchboard")
    try sbd.writeAgents("A", [agent(newId(), cwd: main, name: "board-main", job: "00000001")])

    let r = try sbd.run("import", "--repo", "switchboard")

    #expect(r.status == 0)
    #expect(r.stdout.contains("sb import --all --repo switchboard"))
  }

  @Test func repoDoesNotAcceptRefsAndLeavesImportByRefAlone() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo("switchboard"), "haacked/one")
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: tree, name: "board-one", job: "00000001")])

    let r = try sbd.run("import", id, "--repo", "switchboard")

    #expect(r.status == 1)
    #expect(r.stderr.contains("--repo"))
    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.client.importSessions([id]).imported.count == 1)
  }

  @Test func repoSkipsTheSessionsThatSwitchboardAlreadyHas() throws {
    let sbd = try Instance(accounts: ["A"])
    let tree = try sbd.addWorktree(try sbd.makeRepo("switchboard"), "haacked/one")
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: tree, name: "board-one", job: "00000001")])
    try sbd.client.importSessions([id])

    let r = try sbd.run("import", "--repo", "switchboard")

    #expect(r.status == 1)
    #expect(r.stderr.contains("no Claude session to import in a repo named switchboard"))
  }
}
