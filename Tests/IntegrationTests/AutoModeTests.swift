import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct AutoModeTests {
  /// A session outside auto mode, whose permission card is open.
  func asked(_ prompt: String = "perm touch x") throws -> (Instance, SessionSummary, Card) {
    let sbd = try Instance()
    let s = try sbd.new(prompt: prompt)
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    return (sbd, asked, try #require(asked.cards.first))
  }

  /// Stops the session's claude and resumes it with a message.
  func resume(_ sbd: Instance, _ id: String, _ message: String) throws {
    try sbd.sb("stop", id)
    try sbd.waitFor(id, "claude to exit") { !$0.live }
    try sbd.sb("send", id, message)
    try sbd.waitFor(id, "the resumed turn") { $0.lastReply == "Done: \(message)" }
  }

  @Test func aCardOutsideAutoModeOffersIt() throws {
    let (sbd, s, card) = try asked()
    #expect(s.permissionMode == "default")
    #expect(card.permissionMode == "default")
    #expect(card.offersAutoMode)
    #expect(try sbd.sb("cards", s.id).contains("approve Bash, --auto offered"))
  }

  @Test func allowWithAutoApprovesAndSwitchesTheSession() throws {
    let (sbd, s, _) = try asked()
    let answer = try JSON.parse(sbd.sb("allow", "--auto", "--json", s.id))
    #expect(answer?["delivery"]?.string == "hook")
    let after = try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(after.permissionMode == "auto")
    #expect(try sbd.sb("get", s.id).contains("mode:    auto"))
    #expect(
      try sbd.events(s.id).contains {
        $0.kind == "answered" && $0.data["behavior"] == "allow" && $0.data["permission_mode"] == "auto"
      })

    // The next prompt comes from auto mode, so its card doesn't offer it again.
    try sbd.sb("send", s.id, "perm touch y")
    let next = try sbd.waitFor(s.id, "the next card") { !$0.cards.isEmpty }
    #expect(next.cards.first?.permissionMode == "auto")
    #expect(next.cards.first?.offersAutoMode == false)
    #expect(throws: TestError.self) { try sbd.sb("allow", "--auto", s.id) }
    try sbd.sb("allow", s.id)
    try sbd.waitFor(s.id, "the second reply") { $0.lastReply == "Ran touch y" }

    // A resume keeps the mode.
    try resume(sbd, s.id, "hello")
    #expect(sbd.stubArgs().last?.contains("--permission-mode auto") == true)
    #expect(try sbd.get(s.id).permissionMode == "auto")
  }

  @Test func aPlainAllowLeavesTheModeAlone() throws {
    let (sbd, s, _) = try asked()
    try sbd.sb("allow", s.id)
    let after = try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(after.permissionMode == "default")
    try resume(sbd, s.id, "hello")
    #expect(sbd.stubArgs().allSatisfy { !$0.contains("--permission-mode") })
  }

  @Test func autoIsRefusedInsideClaude() throws {
    let (sbd, s, _) = try asked()
    #expect(throws: TestError.self) { try sbd.sb("allow", "--auto", s.id, env: ["CLAUDECODE": "1"]) }
    let after = try sbd.get(s.id)
    #expect(after.cards.count == 1)
    #expect(after.permissionMode == "default")
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
  }

  @Test func autoIsRefusedWithADeny() throws {
    let (sbd, s, _) = try asked()
    #expect(throws: APIError.self) {
      try sbd.client.call("answer", ["session": .string(s.id), "behavior": "deny", "autoMode": true])
    }
    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
    try sbd.sb("deny", s.id)
    try sbd.waitFor(s.id, "the card to close") { $0.cards.isEmpty }
    try resume(sbd, s.id, "hello")
    #expect(sbd.stubArgs().allSatisfy { !$0.contains("--permission-mode") })
  }

  @Test func autoIsRefusedAfterTheHookCloses() throws {
    let (sbd, s) = try timedOut("perm touch x")
    #expect(try sbd.get(s.id).cards.first?.offersAutoMode == false)
    #expect(throws: TestError.self) { try sbd.sb("allow", "--auto", s.id) }
    #expect(try sbd.get(s.id).cards.count == 1)
  }

  @Test func newSessionsStartInAutoModeByDefault() throws {
    let sbd = try Instance(config: ["autoMode": true])
    let s = try sbd.new(prompt: "perm touch x")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    #expect(sbd.stubArgs().first?.hasSuffix("--permission-mode auto -- perm touch x") == true)
    #expect(asked.permissionMode == "auto")
    #expect(asked.cards.first?.offersAutoMode == false)
  }

  @Test func noAutoStartsASessionWithoutAMode() throws {
    let sbd = try Instance(config: ["autoMode": true])
    let s = try JSONCoding.decode(
      SessionSummary.self, from: try sbd.sb("new", "--json", "--no-auto", "--prompt", "hello", sbd.work))
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }
    #expect(
      sbd.stubArgs() == ["--session-id \(s.claudeSessionId) --settings \(sbd.home.claudeSettings(s.id)) -- hello"])
    #expect(try sbd.get(s.id).permissionMode == "default")
  }

  @Test func spawnWithNoAutoStartsWithoutAMode() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)], "autoMode": true])
    func spawn(_ branch: String, _ extra: String...) throws -> SessionSummary {
      try JSONCoding.decode(
        SessionSummary.self,
        from: try sbd.sb(
          ["spawn", "--json", "--repo", "acme/widgets", "--branch", branch, "--prompt", "hello", "--no-auto"] + extra))
    }
    let s = try spawn("b1")
    let f = try spawn("b2", "--followup")
    try sbd.sb("followup", "start", f.id)
    for id in [s.id, f.id] { try sbd.waitFor(id, "the reply") { $0.lastReply == "Done: hello" } }
    #expect(sbd.stubArgs().count == 2)
    #expect(sbd.stubArgs().allSatisfy { !$0.contains("--permission-mode") })
  }

  @Test func aStartedFollowupStartsInAutoMode() throws {
    let repos = try Repos()
    try repos.make("acme/widgets")
    let sbd = try Instance(config: ["repoRoots": [.string(repos.root)], "autoMode": true])
    let f = try JSONCoding.decode(
      SessionSummary.self, from: try sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."))
    try sbd.sb("followup", "start", f.id)
    try sbd.waitFor("claude to start") { !sbd.stubArgs().isEmpty }
    #expect(sbd.stubArgs().first?.contains("--permission-mode auto") == true)
  }
}

extension AutoModeTests {
  @Test func chooseOffersAutoModeAsAnOption() throws {
    let (sbd, s, _) = try asked()
    let item = try #require(try sbd.get(s.id).triage)
    #expect(item.options.map(\.label) == ["Allow", "Deny", "Approve and enable auto mode"])
    #expect(item.options.map(\.action) == [.allow, .deny, .allowAutoMode])
    #expect(throws: TestError.self) { try sbd.sb("choose", s.id, "3", env: ["CLAUDECODE": "1"]) }
    #expect(try sbd.get(s.id).cards.count == 1)
    try sbd.sb("choose", s.id, "3")
    let after = try sbd.waitFor(s.id, "the command's reply") { $0.lastReply == "Ran touch x" }
    #expect(after.permissionMode == "auto")
  }
}

extension GroupMessageTests {
  @Test func autoModeIsRefusedForAGroupMessage() throws {
    let s = try setup()
    let card = try open(s)
    #expect(throws: APIError.self) {
      try s.sbd.client.call(
        "answer",
        ["session": .string(s.sender.id), "card": .number(Double(card)), "behavior": "allow", "autoMode": true])
    }
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try s.sbd.get(s.sender.id).cards.count == 1)
  }
}
