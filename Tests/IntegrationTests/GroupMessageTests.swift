import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct GroupMessageTests {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func add(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  /// The text of each message that reached the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }

  /// Flags holds alpha and bravo. The sender is in no group.
  struct Setup {
    let sbd: Instance
    let sender: SessionSummary
    let a: SessionSummary
    let b: SessionSummary
    let group: GroupSummary
  }

  func setup(idleStopSeconds: Int = 600, sender prompt: String? = nil) throws -> Setup {
    let sbd = try Instance(idleStopSeconds: idleStopSeconds)
    let sender = try sbd.new(prompt: prompt, name: "sender")
    if let prompt { try sbd.waitFor(sender.id, "the first reply") { $0.lastReply == "Done: \(prompt)" } }
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    return Setup(sbd: sbd, sender: sender, a: a, b: b, group: try add(sbd, "Flags", a.id, b.id))
  }

  /// Runs `sb send --group Flags` inside the sender's Claude and returns what it printed as JSON.
  func ask(_ s: Setup, _ text: String = "Rebase on main.", yes: Bool = false) throws -> GroupSend {
    let flags = ["send", "--json", "--group", "Flags"] + (yes ? ["--yes"] : [])
    return try decode(GroupSend.self, s.sbd.sb(flags + [text], env: inside(s.sender.id)))
  }

  /// The id of the card that a send inside the sender's Claude opens.
  func open(_ s: Setup, _ text: String = "Rebase on main.") throws -> Int64 { try #require(try ask(s, text).pending) }

  /// What `sb send --pending` reports without waiting. A message that still
  /// waits may exit with an error, so this reads stdout whatever the status.
  func pending(_ sbd: Instance, _ card: Int64) throws -> GroupSend {
    let r = try sbd.run(["send", "--pending", String(card), "--timeout", "0", "--json"])
    guard let result = try? decode(GroupSend.self, r.stdout) else {
      throw TestError(description: "sb send --pending \(card) printed no GroupSend: \(r.stdout)\(r.stderr)")
    }
    return result
  }

  /// Who decides: `sb allow` or `sb deny` in a terminal, or the app's `answer` request.
  enum Decider: CaseIterable { case cli, app }

  func decide(_ sbd: Instance, _ how: Decider, _ session: String, _ card: Int64, allow: Bool) throws {
    switch how {
    case .cli:
      try sbd.sb(allow ? "allow" : "deny", session, "--card", String(card))
    case .app:
      _ = try sbd.client.call(
        "answer",
        ["session": .string(session), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny")])
    }
  }

  func now(_ sbd: Instance) throws -> Int64 { Int64(try #require(try sbd.client.call("clock")["now"]?.int)) }

  static let expiryMs = GroupMessage.expirySeconds * 1000

  // MARK: Opening the card

  @Test(arguments: [false, true]) func sendInsideClaudeOpensACardAndSendsNothing(withYes yes: Bool) throws {
    let s = try setup()

    let result = try ask(s, yes: yes)

    #expect(!result.sent)
    #expect(result.pending != nil)
    #expect(result.decision == .pending)
    #expect(result.deliveries == nil)
    #expect(result.group == s.group.id)
    #expect(Set(result.targets.map(\.id)) == [s.a.id, s.b.id])
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try sent(s.sbd, s.b.id).isEmpty)
  }

  @Test func theCardShowsOnTheSenderWithTheMessage() throws {
    let s = try setup()

    let id = try open(s)

    let card = try #require(try s.sbd.get(s.sender.id).cards.first)
    #expect(card.id == id)
    #expect(card.kind == .send)
    #expect(card.session == s.sender.id)
    let message = try #require(card.send)
    #expect(message.group == s.group.id)
    #expect(message.groupName == "Flags")
    #expect(message.text == "Rebase on main.")
    #expect(Set(message.targets.map(\.id)) == [s.a.id, s.b.id])
    #expect(Set(message.targets.map(\.name)) == ["alpha", "bravo"])
  }

  @Test func cardsListsTheSendCard() throws {
    let s = try setup()

    let id = try open(s)

    let cards = try s.sbd.cards()
    #expect(cards.map(\.id) == [id])
    #expect(cards.map(\.kind) == [.send])
    #expect(cards.map(\.session) == [s.sender.id])
  }

  @Test func theCardOpensWithASendPendingEventOnTheSender() throws {
    let s = try setup()

    let id = try open(s)

    let opened = try #require(try s.sbd.events(s.sender.id).first { $0.kind == "send_pending" })
    #expect(opened.id == id)
    #expect(opened.data["group"]?.string == s.group.id)
    #expect(opened.data["groupName"]?.string == "Flags")
    #expect(opened.data["text"]?.string == "Rebase on main.")
    #expect(Set(opened.data["targets"]?.array?.compactMap { $0["id"]?.string } ?? []) == [s.a.id, s.b.id])
  }

  @Test func theMessageExpiresAnHourAfterItOpens() throws {
    let s = try setup()

    let before = try now(s.sbd)
    let result = try ask(s)
    let after = try now(s.sbd)

    let expires = try #require(result.expires)
    #expect(expires >= before + GroupMessageTests.expiryMs)
    #expect(expires <= after + GroupMessageTests.expiryMs)
    #expect(try s.sbd.get(s.sender.id).cards.first?.send?.expires == expires)
  }

  @Test func sendInsideClaudePrintsTheTargetsTheCardAndHowToReadTheDecision() throws {
    let s = try setup()

    let text = try s.sbd.sb(["send", "--group", "Flags", "Rebase on main."], env: inside(s.sender.id))

    let id = try #require(try s.sbd.cards().first?.id)
    #expect(text.contains("alpha"))
    #expect(text.contains("bravo"))
    #expect(text.contains(String(id)))
    #expect(text.contains("sb send --pending \(id)"))
  }

  /// An SB_SESSION_ID that names no session for the card.
  enum NoSession: CaseIterable { case unset, empty, unknown }

  @Test(arguments: NoSession.allCases, [false, true])
  func sendInsideClaudeWithoutASessionRefuses(_ session: NoSession, withYes yes: Bool) throws {
    let s = try setup()
    var env = ["CLAUDECODE": "1"]
    switch session {
    case .unset: break
    case .empty: env["SB_SESSION_ID"] = ""
    case .unknown: env["SB_SESSION_ID"] = "snope1"
    }

    let r = try s.sbd.run(
      ["send", "--json", "--group", "Flags"] + (yes ? ["--yes"] : []) + ["Rebase on main."], env: env)

    #expect(r.status != 0)
    #expect(try s.sbd.cards().isEmpty)
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try sent(s.sbd, s.b.id).isEmpty)
  }

  @Test func sendFromATerminalWithYesSendsAtOnceAndOpensNoCard() throws {
    let s = try setup()

    let result = try decode(
      GroupSend.self, s.sbd.sb("send", "--json", "--group", "Flags", "--yes", "Rebase on main."))

    #expect(result.sent)
    #expect(result.pending == nil)
    #expect(try s.sbd.cards().isEmpty)
    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
    #expect(try sent(s.sbd, s.b.id) == ["Rebase on main."])
  }

  /// A command typed in a session's shell pane has SB_SESSION_ID but not CLAUDECODE.
  @Test func sendFromTheShellPaneWithYesSendsAtOnceAndOpensNoCard() throws {
    let s = try setup()

    let result = try decode(
      GroupSend.self,
      s.sbd.sb(
        ["send", "--json", "--group", "Flags", "--yes", "Rebase on main."], env: ["SB_SESSION_ID": s.sender.id]))

    #expect(result.sent)
    #expect(try s.sbd.cards().isEmpty)
    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
  }

  /// The targets that the confirmed request names, as sbd's preview lists them or not.
  enum ConfirmedTargets: CaseIterable { case listed, none }

  @Test(arguments: ConfirmedTargets.allCases)
  func aConfirmedRequestFromInsideClaudeSendsNothing(_ targets: ConfirmedTargets) throws {
    let s = try setup()
    var args: [String: JSON] = [
      "group": .string(s.group.id), "text": "Rebase on main.", "confirmed": true, "from": .string(s.sender.id),
    ]
    if targets == .listed { args["targets"] = [.string(s.a.id), .string(s.b.id)] }

    let result = try? s.sbd.client.call("send-group", args, as: GroupSend.self)

    #expect(result?.sent != true)
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try sent(s.sbd, s.b.id).isEmpty)
  }

  @Test func aConfirmedRequestFromInsideClaudeOpensACardOnTheSender() throws {
    let s = try setup()

    let result = try s.sbd.client.call(
      "send-group",
      [
        "group": .string(s.group.id), "text": "Rebase on main.", "confirmed": true, "from": .string(s.sender.id),
        "targets": [.string(s.a.id), .string(s.b.id)],
      ], as: GroupSend.self)

    #expect(!result.sent)
    #expect(result.decision == .pending)
    let id = try #require(result.pending)
    #expect(try s.sbd.get(s.sender.id).cards.map(\.id) == [id])
  }

  @Test func aPreviewFromInsideClaudeOpensNoCard() throws {
    let s = try setup()

    let result = try s.sbd.client.call(
      "send-group", ["group": .string(s.group.id), "text": "Rebase on main.", "from": .string(s.sender.id)],
      as: GroupSend.self)

    #expect(!result.sent)
    #expect(result.pending == nil)
    #expect(Set(result.targets.map(\.id)) == [s.a.id, s.b.id])
    #expect(try s.sbd.cards().isEmpty)
  }

  @Test func cardsPrintsTheGroupTheTargetsAndTheTextWithControlCharactersEscaped() throws {
    let s = try setup()
    _ = try open(s, "Rebase\u{1B}[2K on main.")

    let text = try s.sbd.sb("cards")

    #expect(text.contains("Flags"))
    #expect(text.contains("alpha"))
    #expect(text.contains("bravo"))
    #expect(text.contains("Rebase\\u{1b}[2K on main."))
    #expect(!text.contains("\u{1B}"))
  }

  // MARK: Deciding

  @Test func pendingReportsPendingBeforeADecision() throws {
    let s = try setup()
    let id = try open(s)

    let result = try pending(s.sbd, id)

    #expect(result.decision == .pending)
    #expect(result.pending == id)
    #expect(!result.sent)
    #expect(result.deliveries == nil)
  }

  @Test(arguments: Decider.allCases) func allowSendsToTheListedTargets(_ how: Decider) throws {
    let s = try setup()
    let id = try open(s)

    try decide(s.sbd, how, s.sender.id, id, allow: true)

    let result = try pending(s.sbd, id)
    #expect(result.decision == .sent)
    #expect(result.sent)
    let deliveries = result.deliveries ?? []
    #expect(Set(deliveries.map(\.session)) == [s.a.id, s.b.id])
    #expect(deliveries.allSatisfy { $0.delivery != nil && $0.error == nil })
    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
    #expect(try sent(s.sbd, s.b.id) == ["Rebase on main."])
  }

  @Test(arguments: Decider.allCases) func allowClosesTheCardAndTellsTheSenderNothing(_ how: Decider) throws {
    let s = try setup()
    let id = try open(s)

    try decide(s.sbd, how, s.sender.id, id, allow: true)

    #expect(try s.sbd.get(s.sender.id).cards.isEmpty)
    #expect(try sent(s.sbd, s.sender.id).isEmpty)
    let decided = try s.sbd.events(s.sender.id).first { $0.kind == "send_decided" }
    #expect(decided?.data["card"]?.int == Int(id))
    #expect(decided?.data["decision"]?.string == "sent")
  }

  @Test(arguments: Decider.allCases) func denyCancelsAndSendsNothing(_ how: Decider) throws {
    let s = try setup()
    let id = try open(s)

    try decide(s.sbd, how, s.sender.id, id, allow: false)

    let result = try pending(s.sbd, id)
    #expect(result.decision == .cancelled)
    #expect(!result.sent)
    #expect(try s.sbd.get(s.sender.id).cards.isEmpty)
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try sent(s.sbd, s.b.id).isEmpty)
  }

  @Test func chooseSendSendsToTheListedTargets() throws {
    let s = try setup()
    _ = try open(s)

    try s.sbd.sb("choose", s.sender.id, "Send")

    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
    #expect(try sent(s.sbd, s.b.id) == ["Rebase on main."])
    #expect(try s.sbd.get(s.sender.id).cards.isEmpty)
  }

  /// Claude reads this text, not the JSON, after `sb send --group` tells it to run `sb send --pending`.
  @Test(arguments: [true, false]) func pendingTellsClaudeTheDecisionInText(allow: Bool) throws {
    let s = try setup()
    let id = try open(s)
    try decide(s.sbd, .cli, s.sender.id, id, allow: allow)

    let text = try s.sbd.run(["send", "--pending", String(id), "--timeout", "0"]).stdout

    #expect(text.contains("The user sent the message.") == allow)
    #expect(text.contains("The user cancelled the message.") == !allow)
  }

  @Test(arguments: [true, false]) func theAppsAnswerIsTheDecidedSend(allow: Bool) throws {
    let s = try setup()
    let id = try open(s)

    let answer = try s.sbd.client.call(
      "answer",
      ["session": .string(s.sender.id), "card": .number(Double(id)), "behavior": .string(allow ? "allow" : "deny")],
      as: GroupSend.self)

    #expect(answer.pending == id)
    #expect(answer.decision == (allow ? .sent : .cancelled))
    #expect(answer.sent == allow)
    #expect(Set((answer.deliveries ?? []).map(\.session)) == (allow ? [s.a.id, s.b.id] : []))
  }

  @Test func pendingWaitsForTheDecision() throws {
    let s = try setup()
    let id = try open(s)
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var waited: Result<CommandResult, Error>?
    DispatchQueue(label: "pendingWaitsForTheDecision").async {
      waited = Result { try s.sbd.run(["send", "--pending", String(id), "--timeout", "30", "--json"]) }
      done.signal()
    }
    // Reading the decision once takes long enough for the waiter to poll at least once.
    #expect(try pending(s.sbd, id).decision == .pending)
    #expect(done.wait(timeout: .now()) == .timedOut)

    try decide(s.sbd, .cli, s.sender.id, id, allow: true)

    #expect(done.wait(timeout: .now() + 30 * Instance.timeoutScale) == .success)
    let result = try decode(GroupSend.self, try #require(waited).get().stdout)
    #expect(result.decision == .sent)
    #expect(Set((result.deliveries ?? []).map(\.session)) == [s.a.id, s.b.id])
  }

  /// An id that names no group message.
  enum NotAGroupMessage: CaseIterable { case unknown, permissionCard }

  @Test(arguments: NotAGroupMessage.allCases) func pendingRefusesAnIdThatNamesNoGroupMessage(_ kind: NotAGroupMessage)
    throws
  {
    let sbd = try Instance()
    let id: Int64
    switch kind {
    case .unknown:
      id = 999_999
    case .permissionCard:
      let s = try sbd.new(prompt: "perm touch x")
      id = try #require(try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }.cards.first?.id)
    }

    let r = try sbd.run(["send", "--pending", String(id), "--timeout", "0", "--json"])

    #expect(r.status != 0)
    #expect(throws: (any Error).self) { try sbd.client.call("send-pending", ["card": .number(Double(id))]) }
  }

  @Test(arguments: [true, false]) func aDecisionInsideClaudeRefusesAndLeavesTheCardOpen(allow: Bool) throws {
    let s = try setup()
    let id = try open(s)

    let r = try s.sbd.run([allow ? "allow" : "deny", s.sender.id, "--card", String(id)], env: inside(s.sender.id))

    #expect(r.status != 0)
    #expect(try pending(s.sbd, id).decision == .pending)
    #expect(try s.sbd.get(s.sender.id).cards.map(\.id) == [id])
    #expect(try sent(s.sbd, s.a.id).isEmpty)
  }

  // MARK: A decision is final

  @Test(arguments: [true, false], [true, false])
  func aSecondDecisionRefuses(first: Bool, second: Bool) throws {
    let s = try setup()
    let id = try open(s)
    try decide(s.sbd, .cli, s.sender.id, id, allow: first)

    for how in Decider.allCases {
      #expect(throws: (any Error).self) { try decide(s.sbd, how, s.sender.id, id, allow: second) }
    }

    #expect(try pending(s.sbd, id).decision == (first ? .sent : .cancelled))
    #expect(try sent(s.sbd, s.a.id) == (first ? ["Rebase on main."] : []))
    #expect(try sent(s.sbd, s.b.id) == (first ? ["Rebase on main."] : []))
  }

  // MARK: Expiry

  @Test func aMessageExpiresAfterAnHour() throws {
    let s = try setup(idleStopSeconds: 86_400)
    let id = try open(s)

    try s.sbd.advanceClock(GroupMessageTests.expiryMs)

    let result = try pending(s.sbd, id)
    #expect(result.decision == .expired)
    #expect(!result.sent)
    #expect(try s.sbd.get(s.sender.id).cards.isEmpty)
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    let decided = try s.sbd.events(s.sender.id).first { $0.kind == "send_decided" }
    #expect(decided?.data["card"]?.int == Int(id))
    #expect(decided?.data["decision"]?.string == "expired")
  }

  @Test func aMessageAMinuteBeforeItsExpiryStillWaits() throws {
    let s = try setup(idleStopSeconds: 86_400)
    let id = try open(s)

    try s.sbd.advanceClock(GroupMessageTests.expiryMs - 60_000)

    #expect(try pending(s.sbd, id).decision == .pending)
    #expect(try s.sbd.get(s.sender.id).cards.map(\.id) == [id])
  }

  @Test(arguments: Decider.allCases, [true, false])
  func aDecisionAfterExpiryRefusesAndSendsNothing(_ how: Decider, allow: Bool) throws {
    let s = try setup(idleStopSeconds: 86_400)
    let id = try open(s)
    try s.sbd.advanceClock(GroupMessageTests.expiryMs)

    #expect(throws: (any Error).self) { try decide(s.sbd, how, s.sender.id, id, allow: allow) }

    #expect(try pending(s.sbd, id).decision == .expired)
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try sent(s.sbd, s.b.id).isEmpty)
  }

  // MARK: The listed targets

  @Test func allowAfterATargetWasRemovedSendsToTheRest() throws {
    let s = try setup()
    let id = try open(s)
    try s.sbd.sb("rm", s.b.id)

    try decide(s.sbd, .cli, s.sender.id, id, allow: true)

    let result = try pending(s.sbd, id)
    #expect(result.decision == .sent)
    let bySession = Dictionary(uniqueKeysWithValues: (result.deliveries ?? []).map { ($0.session, $0) })
    #expect(bySession[s.a.id]?.delivery != nil)
    #expect(bySession[s.b.id]?.delivery == nil)
    #expect(bySession[s.b.id]?.error != nil)
    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
  }

  @Test func allowLeavesOutASessionThatJoinedAfterTheCardOpened() throws {
    let s = try setup()
    let id = try open(s)
    let late = try s.sbd.new(name: "charlie")
    try s.sbd.sb("group", "move", late.id, "--to", "Flags")

    try decide(s.sbd, .cli, s.sender.id, id, allow: true)

    #expect(Set((try pending(s.sbd, id).deliveries ?? []).map(\.session)) == [s.a.id, s.b.id])
    #expect(try sent(s.sbd, late.id).isEmpty)
  }

  @Test func allowSendsToAListedSessionThatLeftTheGroup() throws {
    let s = try setup()
    let id = try open(s)
    try s.sbd.sb("group", "move", s.b.id, "--ungrouped")

    try decide(s.sbd, .cli, s.sender.id, id, allow: true)

    #expect(try sent(s.sbd, s.b.id) == ["Rebase on main."])
  }

  // MARK: The sender's attention

  @Test func theSenderNeedsYouWhileTheCardIsOpen() throws {
    let s = try setup(sender: "hello")

    _ = try open(s)

    let asking = try s.sbd.get(s.sender.id)
    #expect(asking.state == .needsYou)
    #expect(asking.reason.hasPrefix("confirm"))
  }

  @Test func theSendersReasonLeavesConfirmOnceTheCardCloses() throws {
    let s = try setup(sender: "hello")
    let id = try open(s)

    try decide(s.sbd, .cli, s.sender.id, id, allow: false)

    #expect(try !s.sbd.get(s.sender.id).reason.hasPrefix("confirm"))
  }

  @Test func theCardSurvivesTheSendersNextTurn() throws {
    let s = try setup(sender: "hello")
    let id = try open(s)

    try s.sbd.sb("send", s.sender.id, "Carry on.")
    try s.sbd.waitFor(s.sender.id, "the next reply") { $0.lastReply == "Done: Carry on." }

    let after = try s.sbd.get(s.sender.id)
    #expect(after.cards.map(\.id) == [id])
    #expect(after.cards.map(\.kind) == [.send])
    #expect(after.state == .needsYou)
    #expect(after.reason.hasPrefix("confirm"))
  }

  @Test func theCardSurvivesARestartOfSbdAndAllowStillSends() throws {
    let s = try setup()
    let id = try open(s)

    s.sbd.stopSbd()
    try s.sbd.startSbd()

    #expect(try s.sbd.get(s.sender.id).cards.map(\.id) == [id])
    #expect(try pending(s.sbd, id).decision == .pending)
    try decide(s.sbd, .cli, s.sender.id, id, allow: true)
    #expect(try sent(s.sbd, s.a.id) == ["Rebase on main."])
  }
}
