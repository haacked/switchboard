import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct AccountTests {
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
    #expect(sbd.stubCalls().filter { !$0.args.hasPrefix("agents") }.prefix(3).allSatisfy { $0.account == sbd.account("A") })
  }

  @Test func aFollowupAddedInsideASessionKeepsItsAccount() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    let parent = try decode(sbd.sb("new", "--json", "--prompt", "hello", sbd.work))
    try sbd.sb("account", "use", "B")

    let inherited = try decode(
      sbd.sb(["followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."], env: ["SB_SESSION_ID": parent.id]))
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
}
