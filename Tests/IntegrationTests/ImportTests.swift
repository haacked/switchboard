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
    var config = try #require(JSON.parse(try String(contentsOfFile: sbd.home.config, encoding: .utf8))?.object)
    config["claudeConfigDirs"] = JSON.array(["~/.claude", .string(sbd.account("A"))])
    try JSON.object(config).text.write(toFile: sbd.home.config, atomically: true, encoding: .utf8)
    sbd.stopSbd()
    try sbd.startSbd()

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
    var config = try #require(JSON.parse(try String(contentsOfFile: sbd.home.config, encoding: .utf8))?.object)
    config["claudeConfigDirs"] = JSON.array([.string(sbd.account("A"))])
    try JSON.object(config).text.write(toFile: sbd.home.config, atomically: true, encoding: .utf8)
    sbd.stopSbd()
    try sbd.startSbd()

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

  @Test func importsASessionThatNoClaudeRunsAndResumesItUnderItsAccount() throws {
    let sbd = try Instance(accounts: ["A"])
    var config = try #require(JSON.parse(try String(contentsOfFile: sbd.home.config, encoding: .utf8))?.object)
    config["env"] = ["CLAUDE_CONFIG_DIR": .string("\(sbd.home.path)/env-account")]
    try JSON.object(config).text.write(toFile: sbd.home.config, atomically: true, encoding: .utf8)
    sbd.stopSbd()
    try sbd.startSbd()
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

    let stop = "`CLAUDE_CONFIG_DIR='\(sbd.account("A"))' claude stop deadbeef`"
    let expected: [String: String] = [
      "live": held("live", in: tree),
      "job": "job runs as background job deadbeef. Stop it with \(stop), then import it.",
      "twice": held("twice", in: tree),
      "again": held("again", in: sbd.work),
      ids.unnamed: held(String(ids.unnamed.prefix(8)), in: sbd.work),
      "gone": "gone's folder \(gone) no longer exists.",
      "dup": "dup matches 2 Claude sessions",
      "nothing": "no Claude session matches nothing",
    ]

    let result = try sbd.client.importSessions(["live", "job", "twice", "again", ids.unnamed, "gone", "dup", "nothing"])

    #expect(result.imported.isEmpty)
    #expect(reasons(result) == expected)
    let cli = try sbd.run("import", "live")
    #expect(cli.status == 1)
    #expect(cli.stderr.contains(held("live", in: tree)))
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

  @Test func importsASessionOnceWhenTwoRefsInOneRequestNameIt() throws {
    let sbd = try Instance(accounts: ["A"])
    let id = newId()
    try sbd.writeAgents("A", [agent(id, cwd: sbd.work, name: "notes", job: "0badf00d")])

    let result = try sbd.client.importSessions([id, "notes"])

    #expect(result.refused.isEmpty)
    #expect(result.imported.map(\.claudeSessionId) == [id])
    #expect(try sbd.client.sessions().filter { $0.claudeSessionId == id }.count == 1)
  }

  @Test func importsASessionOnceWhenTwoRequestsRaceForIt() async throws {
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
}
