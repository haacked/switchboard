import Foundation
import SwitchboardCore
import Testing

/// Risk 1: no path that runs claude or reads Claude files under an account
/// gets a Codex account. Each test passes a Codex account through one input
/// shape that resolves an account. A shape that starts or moves a session
/// refuses it. Headless and triage fall back to a Claude account. Every test also checks
/// the property itself: claude never ran with CLAUDE_CONFIG_DIR set to a
/// Codex folder, and no Codex folder gained Claude files.
///
/// sbd runs no session on a Codex account. A stored session, follow-up, or
/// group therefore gets a Codex account through `makeCodex`, which turns
/// Claude account B into a Codex account, as a renamed or reconfigured
/// folder would.
@Suite(.blocking(timeLimit: .seconds(120))) struct CodexAccountGuardTests {
  /// A sbd with the Claude accounts A and B, A active, and the Codex account `.codex-work`.
  func instance(_ extra: [String: JSON] = [:]) throws -> Instance {
    let sbd = try Instance(accounts: ["A", "B"], codexAccounts: [".codex-work"], inheriting: .unset, config: extra)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  func codexFolder(_ sbd: Instance) -> String { sbd.account(".codex-work") }

  /// Each way a request can name the Codex account.
  func refs(_ sbd: Instance) -> [String] {
    let folder = codexFolder(sbd)
    return ["codex-work", folder, folder + "/", GroupAccountTests().tildeForm(folder)]
  }

  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  /// A session under `account` that answered one prompt and then stopped.
  func stoppedSession(_ sbd: Instance, on account: String, prompt: String = "hello", name: String = "first") throws
    -> SessionSummary
  {
    let s = try decode(
      sbd.sb("new", "--json", "--account", account, "--name", name, "--prompt", prompt, sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply?.isEmpty == false }
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  /// Waits 2 s and checks that claude never ran under `folder`. `since`
  /// counts the runs in stub-calls.log to skip, and `headlessSince` those in
  /// headless-accounts.log.
  func expectNoLaunch(_ sbd: Instance, under folder: String, since: Int, headlessSince: Int = 0) throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      let runs = sbd.stubCalls().dropFirst(since).filter { $0.account == folder }
      try #require(runs.isEmpty, "claude ran under \(folder): \(runs.map(\.args))")
      let headless = sbd.headlessAccounts().dropFirst(headlessSince).filter { $0 == folder }
      try #require(headless.isEmpty, "claude -p ran under \(folder)")
      usleep(200_000)
    }
  }

  // MARK: Named accounts

  @Test func newRefusesACodexAccountByNameOrFolder() throws {
    let sbd = try instance()
    let folder = codexFolder(sbd)
    let before = [folder: sbd.tree(folder)]

    for ref in refs(sbd) {
      let r = try sbd.run(["new", "--json", "--account", ref, "--prompt", "hello", sbd.work])
      #expect(r.status != 0, "sb new --account \(ref) succeeded: \(r.stdout)")
      #expect(r.stderr.contains("Codex"), "\(ref): \(r.stderr)")
      #expect(failure(sbd, "new", ["path": .string(sbd.work), "account": .string(ref)]) != "no error", "\(ref)")
    }

    #expect(try sbd.client.sessions().isEmpty)
    sbd.expectClaudeNeverRan(in: [folder], before: before)
  }

  @Test func spawnRefusesACodexAccount() throws {
    let repos = try Repos()
    let checkout = try repos.make("acme/widgets")
    let sbd = try instance(["repoRoots": [.string(repos.root)]])
    let folder = codexFolder(sbd)

    for ref in refs(sbd) {
      let r = try sbd.run([
        "spawn", "--json", "--repo", "acme/widgets", "--branch", "kid", "--prompt", "Go.", "--account", ref,
      ])
      #expect(r.status != 0, "sb spawn --account \(ref) succeeded: \(r.stdout)")
      #expect(r.stderr.contains("Codex"), "\(ref): \(r.stderr)")
      let request: [String: JSON] = [
        "repository": "acme/widgets", "branch": "kid", "prompt": "Go.", "account": .string(ref),
      ]
      #expect(failure(sbd, "spawn", request) != "no error", "\(ref)")
    }

    #expect(try sbd.client.sessions().isEmpty)
    #expect(try !SpawnTests().branchExists(checkout, "kid"))
    sbd.expectClaudeNeverRan(in: [folder])
  }

  @Test func followupSpawnRefusesACodexAccount() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(["repoRoots": [.string(repos.root)]])

    let r = try sbd.run([
      "spawn", "--json", "--repo", "acme/widgets", "--branch", "kid", "--prompt", "Go.", "--followup", "--account",
      "codex-work",
    ])

    #expect(r.status != 0, "sb spawn --followup --account codex-work succeeded: \(r.stdout)")
    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
  }

  @Test func theMCPSpawnToolRefusesACodexAccount() throws {
    let sbd = try instance()
    let repo = try sbd.makeRepo("widgets")
    let mcp = try MCPClient(sbd)

    for ref in refs(sbd) {
      let result = try mcp.call(
        "spawn",
        ["repository": .string(repo), "branch": "kid", "name": "kid", "prompt": "hello", "account": .string(ref)])
      #expect(result.isError, "\(ref): \(result.text)")
      #expect(result.text.contains("Codex"), "\(ref): \(result.text)")
    }

    #expect(try sbd.client.sessions().isEmpty)
    sbd.expectClaudeNeverRan(in: [codexFolder(sbd)])
  }

  @Test func followupAddRefusesACodexAccount() throws {
    let sbd = try instance()

    for ref in refs(sbd) {
      let r = try sbd.run(["followup", "add", "--json", "--repo", "acme/widgets", "--account", ref, "Fix it."])
      #expect(r.status != 0, "sb followup add --account \(ref) succeeded: \(r.stdout)")
      #expect(r.stderr.contains("Codex"), "\(ref): \(r.stderr)")
      let request: [String: JSON] = ["prompt": "Fix it.", "repository": "acme/widgets", "account": .string(ref)]
      #expect(failure(sbd, "followup-add", request) != "no error", "\(ref)")
    }

    #expect(try sbd.client.call("followup-ls", as: [SessionSummary].self).isEmpty)
  }

  /// `sb account use` writes ~/.sb/account, which only a Claude account may hold.
  @Test func accountUseRefusesACodexAccount() throws {
    let sbd = try instance()
    let chosen = try String(contentsOfFile: sbd.home.activeAccount, encoding: .utf8)

    for ref in refs(sbd) {
      let r = try sbd.run(["account", "use", ref])
      #expect(r.status != 0, "sb account use \(ref) succeeded: \(r.stdout)")
      #expect(r.stderr.contains("Codex"), "\(ref): \(r.stderr)")
      #expect(failure(sbd, "account-use", ["account": .string(ref)]) != "no error", "\(ref)")
    }

    #expect(try String(contentsOfFile: sbd.home.activeAccount, encoding: .utf8) == chosen)
    #expect(
      try sbd.accountRows().filter { $0["active"]?.bool == true }.map { $0["folder"]?.string } == [sbd.account("A")])
  }

  // MARK: Stored accounts

  /// A follow-up added on B stores B. Once B is a Codex account, the start refuses.
  @Test func aFollowupWhoseStoredAccountBecameCodexDoesNotStart() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try instance(["repoRoots": [.string(repos.root)]])
    let f = try add(sbd, ["prompt": "Fix it.", "repository": "acme/widgets", "account": "B"])
    #expect(f.account == sbd.account("B"))
    let since = sbd.stubCalls().count
    let headlessSince = sbd.headlessAccounts().count
    try sbd.makeCodex("B")

    let refusal = failure(sbd, "followup-start", ["session": .string(f.id)])

    #expect(refusal.contains("Codex"), "\(refusal)")
    #expect(try sbd.get(f.id).state == .notStarted)
    try expectNoLaunch(sbd, under: sbd.account("B"), since: since, headlessSince: headlessSince)
  }

  /// A stopped session stores B. Once B is a Codex account, a message to the
  /// session must not launch claude under B (Risk 3: a renamed folder).
  @Test func aStoppedSessionWhoseAccountBecameCodexDoesNotLaunchClaudeOnIt() throws {
    let sbd = try instance()
    let s = try stoppedSession(sbd, on: "B")
    let since = sbd.stubCalls().count
    let headlessSince = sbd.headlessAccounts().count
    try sbd.makeCodex("B")

    let r = try sbd.run("send", s.id, "again")

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("Codex"), "\(r.stderr)")
    try expectNoLaunch(sbd, under: sbd.account("B"), since: since, headlessSince: headlessSince)
    #expect(try sbd.get(s.id).claudePid == nil)
  }

  /// A parent on B. Once B is a Codex account, a session started inside the
  /// parent does not inherit it.
  @Test func aChildOfAParentWhoseAccountBecameCodexDoesNotRunOnIt() throws {
    let sbd = try instance()
    let parent = try stoppedSession(sbd, on: "B", name: "parent")
    let since = sbd.stubCalls().count
    let headlessSince = sbd.headlessAccounts().count
    try sbd.makeCodex("B")

    let r = try sbd.run(["new", "--json", "--prompt", "hello", sbd.work], env: inside(parent.id))

    #expect(r.status != 0, "\(r.stdout)")
    #expect(r.stderr.contains("Codex"), "\(r.stderr)")
    try expectNoLaunch(sbd, under: sbd.account("B"), since: since, headlessSince: headlessSince)
  }

  /// A group on B. Once B is a Codex account, a new session in the group runs on the active account A.
  @Test func aNewSessionInAGroupWhoseAccountBecameCodexDoesNotRunOnIt() throws {
    let sbd = try instance()
    try sbd.sb("group", "add", "--json", "Flags")
    try sbd.sb("group", "account", "--json", "Flags", "B")
    let since = sbd.stubCalls().count
    let headlessSince = sbd.headlessAccounts().count
    try sbd.makeCodex("B")

    let r = try sbd.client.call("new", ["path": .string(sbd.work), "group": "Flags", "prompt": "hello"])

    #expect(r["account"]?.string == sbd.account("A"))
    try expectNoLaunch(sbd, under: sbd.account("B"), since: since, headlessSince: headlessSince)
  }

  // MARK: Account settings

  /// ~/.sb/account written by hand, or by an sbd that allowed it.
  @Test func aChosenAccountFileThatNamesACodexFolderIsIgnored() throws {
    let sbd = try instance()
    let folder = codexFolder(sbd)
    try folder.write(toFile: sbd.home.activeAccount, atomically: true, encoding: .utf8)
    sbd.stopSbd()
    try sbd.startSbd()

    let active = try sbd.accountRows().filter { $0["active"]?.bool == true }
    let s = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }

    #expect(active.map { $0["agent"]?.string } == ["claude"])
    #expect(active.map { $0["folder"]?.string } != [folder])
    #expect(s.account != folder)
    sbd.expectClaudeNeverRan(in: [folder])
  }

  @Test func aConfigEnvClaudeConfigDirThatNamesACodexFolderNeverRunsClaudeThere() throws {
    let sbd = try Instance(
      accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset, startingSbd: false)
    let folder = codexFolder(sbd)
    try sbd.set("env", to: ["CLAUDE_CONFIG_DIR": .string(folder)])
    try sbd.startSbd()

    let active = try sbd.accountRows().filter { $0["active"]?.bool == true }
    _ = try sbd.run("new", "--json", "--prompt", "hello", sbd.work)

    #expect(active.map { $0["agent"]?.string } == ["claude"])
    try expectNoLaunch(sbd, under: folder, since: 0)
    sbd.expectClaudeNeverRan(in: [folder])
  }

  @Test func sbdsOwnClaudeConfigDirThatNamesACodexFolderNeverRunsClaudeThere() throws {
    let sbd = try Instance(
      accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset, startingSbd: false)
    let folder = codexFolder(sbd)
    sbd.sbdEnvironment["CLAUDE_CONFIG_DIR"] = folder
    try sbd.startSbd()

    let active = try sbd.accountRows().filter { $0["active"]?.bool == true }
    _ = try sbd.run("new", "--json", "--prompt", "hello", sbd.work)

    #expect(active.map { $0["agent"]?.string } == ["claude"])
    try expectNoLaunch(sbd, under: folder, since: 0)
    sbd.expectClaudeNeverRan(in: [folder])
  }

  /// Risk 3: a `claudeConfigDirs` entry named like a Codex folder.
  @Test func aCodexFolderInClaudeConfigDirsNeverRunsClaude() throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset, startingSbd: false)
    let folder = try makeFolder(sbd.account(".codex-x"), holding: [".claude.json"])
    try sbd.set("claudeConfigDirs", to: [.string(sbd.account("A")), .string(folder)])
    try sbd.startSbd()
    try sbd.sb("account", "use", "A")

    let new = try sbd.run(["new", "--json", "--account", folder, "--prompt", "hello", sbd.work])
    let use = try sbd.run(["account", "use", folder])

    #expect(new.status != 0, "\(new.stdout)")
    #expect(use.status != 0, "\(use.stdout)")
    try expectNoLaunch(sbd, under: folder, since: 0)
  }

  // MARK: Headless and triage fall back to a Claude account

  /// The summary call that `triage.account` would pay for runs under the
  /// session's own Claude account when `triage.account` names a Codex
  /// account. The session runs on the active account A here.
  @Test func aTriageAccountThatNamesACodexAccountFallsBackToAClaudeAccount() throws {
    let sbd = try Instance(
      accounts: ["A"], codexAccounts: [".codex-work"], inheriting: .unset, startingSbd: false)
    let folder = codexFolder(sbd)
    try sbd.set("triage", to: ["systemPrompt": "", "account": .string(folder)])
    try sbd.startSbd()
    try sbd.sb("account", "use", "A")

    let s = try sbd.new(prompt: "ask")
    try sbd.waitFor(s.id, "the model's summary") { $0.triage?.source == .summary }

    #expect(sbd.headlessAccounts().last == sbd.account("A"))
    sbd.expectClaudeNeverRan(in: [folder])
  }

  /// A turn of a session on B ends while triage is off. B then becomes a
  /// Codex account and triage turns on, so sbd summarizes the turn when it
  /// starts. The summary runs under the active Claude account, not under B.
  @Test func theSummaryOfASessionWhoseAccountBecameCodexRunsUnderTheActiveClaudeAccount() throws {
    let sbd = try instance(["triage": ["systemPrompt": "", "enabled": false]])
    let s = try stoppedSession(sbd, on: "B", prompt: "ask")
    #expect(sbd.summaryCalls().isEmpty)
    let since = sbd.stubCalls().count
    let headlessSince = sbd.headlessAccounts().count
    let before = [sbd.account("B"): sbd.tree(sbd.account("B"))]

    try sbd.makeCodex("B", settings: ["triage": ["systemPrompt": ""]])

    try sbd.waitFor(s.id, "the model's summary") { $0.triage?.source == .summary }
    #expect(sbd.headlessAccounts().dropFirst(headlessSince).last == sbd.account("A"))
    sbd.expectClaudeNeverRan(in: [sbd.account("B")], since: since, headlessSince: headlessSince, before: before)
  }
}

/// Risk 2: a move copies a conversation's files into the target account. A
/// Codex target, or a session whose account is Codex, refuses every move
/// shape, because a Codex thread also lives in SQLite rows that a copy
/// leaves behind. The copy is destructive, so each move shape has a test.
@Suite(.blocking(timeLimit: .seconds(120))) struct CodexAccountMoveGuardTests {
  let guards = CodexAccountGuardTests()
  let accountTests = AccountTests()

  @Test(arguments: [
    [], ["--dry-run"], ["--session", "first"], ["--dry-run", "--session", "first"], ["--stop", "--session", "first"],
  ])
  func accountMoveToACodexAccountIsRefused(_ extra: [String]) throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "A")
    let folder = guards.codexFolder(sbd)

    for ref in ["codex-work", folder] {
      let r = try sbd.run(["account", "move", "--json", ref] + extra)
      #expect(r.status != 0, "sb account move \(ref) \(extra) succeeded: \(r.stdout)")
      #expect(r.stderr.contains("Codex"), "\(ref) \(extra): \(r.stderr)")
    }

    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "account-moved" })
    sbd.expectClaudeNeverRan(in: [folder])
    #expect(sbd.tree(folder).isEmpty)
  }

  @Test func accountUseWithMoveToACodexAccountIsRefused() throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "A")
    let folder = guards.codexFolder(sbd)

    let r = try sbd.run(["account", "use", "codex-work", "--move", "--json"])

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(
      try sbd.accountRows().filter { $0["active"]?.bool == true }.map { $0["folder"]?.string } == [sbd.account("A")])
    #expect(sbd.tree(folder).isEmpty)
  }

  /// The app's "Move N Stopped Sessions…" sends `account-move` with the sessions it lists.
  @Test func theAppsMoveRequestToACodexAccountIsRefused() throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "A")
    let folder = guards.codexFolder(sbd)

    for dryRun in [true, false] {
      let request: [String: JSON] = [
        "account": .string(folder), "sessions": [.string(s.id)], "dryRun": .bool(dryRun),
      ]
      #expect(failure(sbd, "account-move", request) != "no error", "dryRun \(dryRun)")
    }

    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(sbd.tree(folder).isEmpty)
  }

  /// `group-account` sets the account that a member moves to at its next launch.
  @Test func groupAccountRefusesACodexAccount() throws {
    let sbd = try guards.instance()
    let member = try guards.stoppedSession(sbd, on: "A")
    try sbd.sb("group", "add", "--json", "Flags", member.id)
    let folder = guards.codexFolder(sbd)

    for ref in guards.refs(sbd) {
      let r = try sbd.run(["group", "account", "--json", "Flags", ref])
      #expect(r.status != 0, "sb group account Flags \(ref) succeeded: \(r.stdout)")
      #expect(failure(sbd, "group-account", ["group": "Flags", "account": .string(ref)]) != "no error", "\(ref)")
    }
    try sbd.sb("group", "account", "--json", "Flags", "B")
    #expect(failure(sbd, "group-account", ["group": "Flags", "account": "codex-work"]) != "no error")

    let shown = try JSONCoding.decode(GroupSummary.self, from: try sbd.sb("group", "account", "--json", "Flags"))
    #expect(shown.account == sbd.account("B"))
    #expect(sbd.tree(folder).isEmpty)
  }

  /// The group's account was B when the test set it. B is a Codex account by
  /// the member's next launch, so sbd skips the lazy move. The member
  /// launches under its own account.
  @Test func aLazyMoveToAGroupAccountThatBecameCodexIsSkipped() throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "A")
    try sbd.sb("group", "add", "--json", "Flags")
    try sbd.sb("group", "account", "--json", "Flags", "B")
    try sbd.sb("group", "move", s.id, "--to", "Flags")
    let before = [sbd.account("B"): sbd.tree(sbd.account("B"))]
    let headlessSince = sbd.headlessAccounts().count
    try sbd.makeCodex("B")

    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" }

    #expect(try sbd.get(s.id).account == sbd.account("A"))
    #expect(sbd.stubCalls().last { $0.args.contains(s.claudeSessionId) }?.account == sbd.account("A"))
    #expect(try sbd.events(s.id).allSatisfy { $0.kind != "account-moved" })
    let skipped = try #require(try sbd.events(s.id).last { $0.kind == "account-move-skipped" })
    #expect(skipped.data["to"]?.string == sbd.account("B"))
    #expect(skipped.data["reason"]?.string?.contains("Codex") == true, "\(skipped.data)")
    #expect(accountTests.transcript(sbd, "B", s) == nil)
    sbd.expectClaudeNeverRan(in: [sbd.account("B")], headlessSince: headlessSince, before: before)
  }

  /// A session whose account became Codex can't move to a Claude account
  /// either, because its conversation would need Codex's SQLite rows.
  @Test(arguments: [["--session", "first"], ["--dry-run", "--session", "first"]])
  func aSessionWhoseAccountBecameCodexIsNotMovedToAClaudeAccount(_ extra: [String]) throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "B")
    try sbd.makeCodex("B")

    let r = try sbd.run(["account", "move", "--json", "A"] + extra)

    #expect(r.status != 0, "\(r.stdout)")
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(accountTests.transcript(sbd, "A", s) == nil)
  }

  @Test func aBulkMoveLeavesASessionWhoseAccountBecameCodex() throws {
    let sbd = try guards.instance()
    let s = try guards.stoppedSession(sbd, on: "B")
    try sbd.makeCodex("B")

    let r = try sbd.run(["account", "move", "--json", "A"])

    #expect(r.status == 0, "\(r.stderr)")
    let move = try JSONCoding.decode(AccountMove.self, from: r.stdout)
    #expect(!move.moved.contains(s.id))
    #expect(move.blocked.first { $0.session == s.id }?.reason.contains("Codex") == true, "\(move.blocked)")
    #expect(try sbd.get(s.id).account == sbd.account("B"))
    #expect(accountTests.transcript(sbd, "A", s) == nil)
  }
}
