import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct AccountTests {
  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  func accounts(_ sbd: Instance) throws -> [AccountInfo] {
    try JSONCoding.decode([AccountInfo].self, from: try sbd.sb("account", "--json"))
  }

  /// Starts a session from inside `parent`, as a command that Claude runs there would.
  func child(_ sbd: Instance, of parent: String, _ extra: String...) throws -> SessionSummary {
    let args = ["new", "--json", "--prompt", "hello"] + extra + [sbd.work]
    return try decode(sbd.sb(args, env: ["SB_SESSION_ID": parent, "CLAUDECODE": "1"]))
  }

  @Test func listsTheAccountsAndNewSessionsUseTheActiveOne() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let (a, b) = (sbd.account("A"), sbd.account("B"))

    #expect(try accounts(sbd).map(\.folder).filter { $0 == a || $0 == b } == [a, b])
    try sbd.sb("account", "use", "B")
    #expect(try accounts(sbd).filter(\.active).map(\.folder) == [b])

    let s = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))

    #expect(s.account == b)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    #expect(sbd.stubCalls().last { !$0.args.hasPrefix("agents") }?.account == b)
    #expect(try accounts(sbd).first { $0.folder == b }?.sessions == 1)
  }

  @Test func theChosenAccountSurvivesARestart() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", sbd.account("B"))
    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try accounts(sbd).filter(\.active).map(\.folder) == [sbd.account("B")])
  }

  @Test func aSessionNamesItsAccountWithTheFlag() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")

    let s = try decode(sbd.sb("new", "--json", "--account", "B", "--prompt", "hello", sbd.work))

    #expect(s.account == sbd.account("B"))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    #expect(sbd.stubCalls().last { !$0.args.hasPrefix("agents") }?.account == sbd.account("B"))
  }

  @Test func aSpawnedSessionInheritsItsParentsAccountWhateverIsActive() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let parent = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.sb("account", "use", "B")

    let kid = try child(sbd, of: parent.id)
    let grandchild = try child(sbd, of: kid.id)
    let named = try child(sbd, of: parent.id, "--account", "B")

    #expect(parent.account == sbd.account("A"))
    #expect(kid.account == sbd.account("A"))
    #expect(grandchild.account == sbd.account("A"))
    #expect(named.account == sbd.account("B"))
    try sbd.waitFor(grandchild.id, "the first reply") { $0.lastReply == "Done: hello" }
    #expect(
      sbd.stubCalls().filter { !$0.args.hasPrefix("agents") }.prefix(3).allSatisfy { $0.account == sbd.account("A") })
  }

  @Test func aFollowupAddedInsideASessionKeepsItsAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let parent = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.sb("account", "use", "B")

    let inherited = try decode(
      sbd.sb(
        ["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."], env: ["SB_SESSION_ID": parent.id]))
    let alone = try decode(sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix the queue."))
    let named = try decode(sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "--account", "B", "Fix it."))

    #expect(inherited.account == sbd.account("A"))
    #expect(alone.account == nil)
    #expect(named.account == sbd.account("B"))
  }

  @Test func refusesAnAccountThatHoldsNoClaudeLogin() throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset)
    let empty = sbd.account("empty")
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)

    #expect(throws: TestError.self) { try sbd.sb("account", "use", "nobody") }
    #expect(throws: TestError.self) { try sbd.sb("account", "use", empty) }
    #expect(throws: TestError.self) { try sbd.sb("new", "--account", "nobody", sbd.work) }
    #expect(try accounts(sbd).filter(\.active).map(\.folder) == [ClaudeAccount.defaultFolder])
    #expect(try sbd.client.sessions().isEmpty)
  }

  // MARK: Moving sessions

  @discardableResult func move(_ sbd: Instance, _ extra: String...) throws -> AccountMove {
    try JSONCoding.decode(AccountMove.self, from: try sbd.sb(["account", "move", "--json", "B"] + extra))
  }

  /// A session under A that has answered one prompt and then stopped.
  func stoppedSession(_ sbd: Instance, prompt: String = "hello") throws -> SessionSummary {
    try sbd.sb("account", "use", "A")
    let s = try decode(sbd.sb("new", "--json", "--prompt", prompt, sbd.work))
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: \(prompt)" }
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
  }

  func transcript(_ sbd: Instance, _ account: String, _ s: SessionSummary) -> String? {
    let projects = "\(sbd.account(account))/projects"
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
    return folders.map { "\(projects)/\($0)/\(s.claudeSessionId).jsonl" }.first {
      FileManager.default.fileExists(atPath: $0)
    }
  }

  @Test func movesAStoppedSessionAndResumesItsConversationUnderTheNewAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    #expect(transcript(sbd, "B", s) == nil)

    let planned = try move(sbd, "--dry-run")
    #expect(planned.moved == [s.id])
    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("A"))

    let result = try move(sbd)
    #expect(result.moved == [s.id])
    #expect(result.blocked.isEmpty)
    let copy = try #require(transcript(sbd, "B", s))
    #expect((copy as NSString).lastPathComponent == (old as NSString).lastPathComponent)
    #expect(
      ((copy as NSString).deletingLastPathComponent as NSString).lastPathComponent
        == ((old as NSString).deletingLastPathComponent as NSString).lastPathComponent)
    #expect(FileManager.default.contentsEqual(atPath: old, andPath: copy))
    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("B"))
    #expect(try accounts(sbd).first { $0.folder == sbd.account("B") }?.sessions == 1)
    #expect(try sbd.events(s.id).contains { $0.kind == "account-moved" })

    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" }
    let call = try #require(sbd.stubCalls().last { !$0.args.hasPrefix("agents") })
    #expect(call.account == sbd.account("B"))
    #expect(call.args.contains("--resume \(s.claudeSessionId)"))
  }

  @Test func theMoveSurvivesARestart() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    try move(sbd)
    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("B"))
    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" }
    #expect(sbd.stubCalls().last { !$0.args.hasPrefix("agents") }?.account == sbd.account("B"))
  }

  @Test func leavesASessionWhoseClaudeRunsOnItsAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let live = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.waitFor(live.id, "the first reply") { $0.lastReply == "Done: hello" }
    let stopped = try stoppedSession(sbd, prompt: "second")

    let result = try move(sbd)
    #expect(result.moved == [stopped.id])
    #expect(result.blocked.map(\.session) == [live.id])
    #expect(try decode(sbd.sb("get", "--json", live.id)).account == sbd.account("A"))
    #expect(transcript(sbd, "B", live) == nil)
  }

  @Test func refusesToMoveWhenTheAccountHoldsAnotherTranscriptOfTheConversation() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let folder = ((old as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let dir = "\(sbd.account("B"))/projects/\(folder)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "{}\n".write(toFile: "\(dir)/\(s.claudeSessionId).jsonl", atomically: true, encoding: .utf8)

    let result = try move(sbd)
    #expect(result.moved.isEmpty)
    #expect(result.blocked.map(\.session) == [s.id])
    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("A"))
    #expect(try String(contentsOfFile: "\(dir)/\(s.claudeSessionId).jsonl", encoding: .utf8) == "{}\n")
  }

  @Test func movesWithoutACopyWhenTheAccountsShareTheirProjectsFolder() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let (a, b) = (sbd.account("A"), sbd.account("B"))
    try FileManager.default.createDirectory(atPath: "\(a)/projects", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: "\(b)/projects", withDestinationPath: "\(a)/projects")
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let before = try Data(contentsOf: URL(fileURLWithPath: old))

    #expect(try move(sbd).moved == [s.id])
    #expect(try Data(contentsOf: URL(fileURLWithPath: old)) == before)
    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: again" }
    #expect(sbd.stubCalls().last { !$0.args.hasPrefix("agents") }?.account == b)
  }

  @Test func copiesTheFileHistoryOfTheConversation() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let history = "\(sbd.account("A"))/file-history/\(s.claudeSessionId)"
    try FileManager.default.createDirectory(atPath: history, withIntermediateDirectories: true)
    try "v1".write(toFile: "\(history)/abc@v1", atomically: true, encoding: .utf8)

    try move(sbd)
    #expect(
      try String(contentsOfFile: "\(sbd.account("B"))/file-history/\(s.claudeSessionId)/abc@v1", encoding: .utf8)
        == "v1")
  }

  @Test func theUseCommandMovesOnlyWhenAsked() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    try sbd.sb("account", "use", "B", "--new-only")
    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("A"))
    try sbd.sb("account", "use", "A")

    let out = try sbd.sb("account", "use", "B", "--move", "--json")
    let both = try JSONCoding.decode(JSON.self, from: out)
    #expect(try JSONCoding.convert(both["move"]!, to: AccountMove.self).moved == [s.id])
    #expect(
      try JSONCoding.convert(both["accounts"]!, to: [AccountInfo].self).filter(\.active).map(\.folder) == [
        sbd.account("B")
      ])
    #expect(try decode(sbd.sb("get", "--json", s.id)).account == sbd.account("B"))
  }

  @Test func copiesTheConversationsFolderWithItsSubagentsAndToolResults() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let extra = (old as NSString).deletingPathExtension
    try FileManager.default.createDirectory(atPath: "\(extra)/subagents", withIntermediateDirectories: true)
    try "sub".write(toFile: "\(extra)/subagents/agent-1.jsonl", atomically: true, encoding: .utf8)

    try move(sbd)
    let copy = try #require(transcript(sbd, "B", s))
    #expect(
      try String(contentsOfFile: "\((copy as NSString).deletingPathExtension)/subagents/agent-1.jsonl", encoding: .utf8)
        == "sub")
  }

  @Test func movesBackToAnAccountThatHoldsAnOlderCopy() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    try move(sbd)
    try sbd.sb("send", s.id, "second")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: second" }
    try sbd.sb("stop", s.id)
    try sbd.waitFor(s.id, "the stop") { $0.claudePid == nil }
    let grown = try #require(transcript(sbd, "B", s))

    let back = try JSONCoding.decode(AccountMove.self, from: try sbd.sb("account", "move", "--json", "A"))
    #expect(back.moved == [s.id])
    let old = try #require(transcript(sbd, "A", s))
    #expect(FileManager.default.contentsEqual(atPath: old, andPath: grown))
    try sbd.sb("send", s.id, "third")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: third" }
  }

  @Test func movingBackReplacesAStaleSubagentTranscript() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let subagent = "\((old as NSString).deletingPathExtension)/subagents/agent-1.jsonl"
    try FileManager.default.createDirectory(
      atPath: (subagent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "one\n".write(toFile: subagent, atomically: true, encoding: .utf8)
    try move(sbd)
    let copy = try #require(transcript(sbd, "B", s))
    let grownSubagent = "\((copy as NSString).deletingPathExtension)/subagents/agent-1.jsonl"
    try "one\ntwo\n".write(toFile: grownSubagent, atomically: true, encoding: .utf8)

    let back = try JSONCoding.decode(AccountMove.self, from: try sbd.sb("account", "move", "--json", "A"))
    #expect(back.moved == [s.id])
    #expect(try String(contentsOfFile: subagent, encoding: .utf8) == "one\ntwo\n")
    let mode = try FileManager.default.attributesOfItem(atPath: subagent)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func movingBackKeepsASubagentTranscriptThatIsNotAPrefixOfTheSource() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let subagent = "\((old as NSString).deletingPathExtension)/subagents/agent-1.jsonl"
    try FileManager.default.createDirectory(
      atPath: (subagent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try "one\n".write(toFile: subagent, atomically: true, encoding: .utf8)
    try move(sbd)
    let copy = try #require(transcript(sbd, "B", s))
    let grownSubagent = "\((copy as NSString).deletingPathExtension)/subagents/agent-1.jsonl"
    try "one\ntwo\n".write(toFile: grownSubagent, atomically: true, encoding: .utf8)
    try "other\n".write(toFile: subagent, atomically: true, encoding: .utf8)

    let back = try JSONCoding.decode(AccountMove.self, from: try sbd.sb("account", "move", "--json", "A"))
    #expect(back.moved == [s.id])
    #expect(try String(contentsOfFile: subagent, encoding: .utf8) == "other\n")
  }

  @Test func theDryRunListsASessionWhoseMoveWouldConflictAsBlocked() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    let s = try stoppedSession(sbd)
    let old = try #require(transcript(sbd, "A", s))
    let folder = ((old as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let dir = "\(sbd.account("B"))/projects/\(folder)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "{}\n".write(toFile: "\(dir)/\(s.claudeSessionId).jsonl", atomically: true, encoding: .utf8)

    let plan = try move(sbd, "--dry-run")
    #expect(plan.moved.isEmpty)
    #expect(plan.blocked.map(\.session) == [s.id])
  }

  @Test func theUseCommandRefusesBothAnswers() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    #expect(throws: TestError.self) { try sbd.sb("account", "use", "B", "--move", "--new-only") }
  }
}
