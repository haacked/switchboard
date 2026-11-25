import Foundation
import SwitchboardCore
import Testing

/// A needs-you report from the Operator becomes an Inbox item on the session that it is about, or on a Manager
/// conversation, and the Operator stays out of Needs you. sbd records `report-routed` on the Operator and
/// `operator-ask` on the owner. A Reply on the owner's item goes to the Operator with `reports`, an Acknowledge
/// records `report-closed` on the Operator, and each closes only that owner's asks. An overdue wait that the Operator
/// holds shows on the session that it acts on, or on the conversation that handed it off. Each test reads state right
/// after its step, with no tick between, unless it says otherwise.
@Suite(.blocking(timeLimit: .seconds(120))) struct OperatorAskTests {
  let reportHelpers = OperatorReportTests()
  let operatorHelpers = OperatorTests()
  let conversationHelpers = ManagerConversationsTests()
  let handoff = OperatorHandoffTests()

  static let question = OperatorReportTests.question
  static let askReason = "Operator: \(question)"

  func inside(_ id: String) -> [String: String] { conversationHelpers.inside(id) }

  func idleOperator(_ sbd: Instance, _ text: String = "hello") throws -> SessionSummary {
    try operatorHelpers.idleOperator(sbd, text)
  }

  func conversation(_ sbd: Instance, _ name: String) throws -> SessionSummary {
    try conversationHelpers.idleConversation(sbd, name: name, "hello")
  }

  /// Records a needs-you report inside the Operator, as its Claude would, and returns the `report` event.
  @discardableResult
  func ask(_ sbd: Instance, _ op: SessionSummary, _ text: String = question, about: String? = nil) throws -> Event {
    let r = try reportHelpers.report(sbd, from: op, text, about: about)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    return try #require(try sbd.events(op.id, kind: "report").last { $0.data["text"]?.string == text })
  }

  /// The session's item. It also checks that the app's guard and `sb triage --json` agree with sbd's item.
  func item(_ sbd: Instance, _ id: String) throws -> TriageItem? {
    let s = try sbd.get(id)
    let listed = try sbd.triage().contains { $0.id == id }
    let source = s.triage?.source.rawValue ?? "none"
    #expect(Triage.inInbox(s) == (s.triage != nil), "inInbox disagrees with the item from \(source) on \(s.name)")
    #expect(listed == (s.triage != nil), "sb triage disagrees with the item from \(source) on \(s.name)")
    return s.triage
  }

  /// The session's item when it is an ask.
  func askItem(_ sbd: Instance, _ id: String) throws -> TriageItem? {
    try item(sbd, id).flatMap { $0.source == .report && $0.ref.hasPrefix("report:") ? $0 : nil }
  }

  func reports(_ sbd: Instance) throws -> [JSON] { try reportHelpers.reports(sbd) }

  /// Whether `sb operator reports --json` lists the report as open.
  func isOpen(_ sbd: Instance, _ report: Event) throws -> Bool? {
    try reports(sbd).first { $0["id"]?.int == Int(report.id) }?["open"]?.bool
  }

  /// The ids of every session whose item names the report.
  func holders(_ sbd: Instance, _ report: Event) throws -> [String] {
    try sbd.client.call("ls", as: [SessionSummary].self).filter { $0.triage?.ref == "report:\(report.id)" }.map(\.id)
  }

  /// The ids of the sessions that `sb triage` lists with an item that names the report.
  func triaged(_ sbd: Instance, _ report: Event) throws -> [String] {
    try sbd.triage().filter { $0.triage?.ref == "report:\(report.id)" }.map(\.id)
  }

  /// The Operator's events of `kind` after `mark`.
  func events(_ sbd: Instance, _ id: String, _ kind: String, after mark: Int64 = 0) throws -> [Event] {
    try sbd.events(id, after: mark).filter { $0.kind == kind }
  }

  /// The ids in a `reports` array of event data.
  func ids(_ data: JSON?) -> [Int64] { data?.array?.compactMap { $0.int.map(Int64.init) } ?? [] }

  /// Runs `sb choose <id> Reply --text <text>` from the user's terminal.
  func reply(_ sbd: Instance, _ id: String, _ text: String) throws {
    try sbd.sb("choose", id, "Reply", "--text", text)
  }

  // MARK: The Operator's own state (Decision 43)

  @Test func aNewOperatorIsNotNeedsYou() throws {
    let sbd = try Instance()

    let op = try operatorHelpers.openOperator(sbd)

    let live = try sbd.waitFor(op.id, "the operator's claude") { $0.live }
    #expect(live.state != .needsYou, "\(live.state): \(live.reason)")
  }

  @Test func anIdleOperatorIsWaitingWithIdleAsItsReason() throws {
    let sbd = try Instance()

    let op = try idleOperator(sbd)

    #expect(op.state == .waiting, "\(op.state): \(op.reason)")
    #expect(op.reason == "idle")
  }

  @Test func anOperatorWhoseReplyAsksAQuestionIsWaiting() throws {
    let sbd = try Instance()

    let op = try idleOperator(sbd, "Which database should I use?")

    #expect(op.state == .waiting, "\(op.state): \(op.reason)")
    #expect(try item(sbd, op.id) == nil)
  }

  @Test func anOperatorWithANonBlockingSendCardIsNotNeedsYou() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let card = JSON.object([
      "summary": "It finished.\nIt needs a call.", "options": [["label": "Go on", "action": "send"]],
    ]).text

    let r = try sbd.setSummary([], card, env: inside(op.id))

    try #require(r.status == 0, Comment(rawValue: r.stderr))
    let s = try sbd.get(op.id)
    #expect(s.state != .needsYou, "\(s.state): \(s.reason)")
  }

  @Test func anOperatorIsWorkingWhileItsTurnRuns() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    defer { FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil) }

    try sbd.sb("operator", "slow held")

    let busy = try sbd.waitFor(op.id, "the operator's turn") { $0.state == .working }
    #expect(busy.state == .working)
  }

  @Test func anOperatorWithABlockingPermissionCardIsNeedsYou() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    try sbd.sb("operator", "perm touch x")

    let asked = try sbd.waitFor(op.id, "the permission card") { !$0.cards.isEmpty }
    #expect(asked.state == .needsYou, "\(asked.state): \(asked.reason)")
  }

  // MARK: Routing a report (criterion 2)

  @Test func aReportAboutASessionRecordsTheReportAndItsRoutingOnTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let mark = try sbd.lastEventId(op.id)

    let report = try ask(sbd, op, about: kid.id)

    let kinds = try sbd.events(op.id, after: mark).map(\.kind).filter { $0.hasPrefix("report") }
    #expect(kinds == ["report", "report-routed"], "\(kinds)")
    let routed = try #require(try events(sbd, op.id, "report-routed", after: mark).first)
    #expect(routed.data["report"]?.int == Int(report.id), Comment(rawValue: routed.data.text))
    #expect(routed.data["owner"]?.string == kid.id, Comment(rawValue: routed.data.text))
  }

  @Test func aReportAboutASessionRecordsAnOperatorAskOnThatSession() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    let report = try ask(sbd, op, about: kid.id)

    let asks = try events(sbd, kid.id, "operator-ask")
    try #require(asks.count == 1, "\(asks.map(\.data.text))")
    #expect(asks[0].data["report"]?.int == Int(report.id), Comment(rawValue: asks[0].data.text))
    #expect(asks[0].data["text"]?.string == Self.question, Comment(rawValue: asks[0].data.text))
  }

  /// `routeReport` and the sync record nothing else, so a re-track inside `fold` does not recurse.
  @Test func aRoutedReportRecordsExactlyThreeEvents() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    try sbd.waitFor(kid.id, "the kid's claude") { $0.live }
    let opMark = try sbd.lastEventId(op.id)
    let kidMark = try sbd.lastEventId(kid.id)
    let watched: Set<String> = ["report", "report-routed", "report-closed", "operator-ask", "sent", "digest", "ack"]

    try ask(sbd, op, about: kid.id)

    let added = try (sbd.events(op.id, after: opMark) + sbd.events(kid.id, after: kidMark)).map(\.kind)
    #expect(added.filter(watched.contains).sorted() == ["operator-ask", "report", "report-routed"], "\(added)")
  }

  @Test func aReportAboutASessionPutsThatSessionInNeedsYouWithTheOperatorsText() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    try ask(sbd, op, about: kid.id)

    let s = try sbd.get(kid.id)
    #expect(s.state == .needsYou, "\(s.state): \(s.reason)")
    #expect(s.reason == Self.askReason)
  }

  @Test func aReportAboutASessionGivesItAReportItemWithAReplyOption() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    let report = try ask(sbd, op, about: kid.id)

    let item = try #require(try item(sbd, kid.id))
    #expect(item.source == .report)
    #expect(item.ref == "report:\(report.id)")
    #expect(item.options.contains { $0.action == .reply && $0.label == "Reply" }, "\(item.options)")
    #expect(item.summary.contains(Self.question), "\(item.summary)")
  }

  @Test func aRoutedReportLeavesTheOperatorWithNoItemAndOutOfNeedsYou() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    try ask(sbd, op, about: kid.id)

    try #require(try askItem(sbd, kid.id) != nil, "the ask is on no owner")
    let s = try sbd.get(op.id)
    #expect(s.triage == nil, "\(String(describing: s.triage))")
    #expect(s.state != .needsYou, "\(s.state): \(s.reason)")
  }

  /// Risk 7: one report, one item.
  @Test func sbTriageListsOneItemForTheReportOnItsOwner() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    _ = try conversation(sbd, "Queue work")

    let report = try ask(sbd, op, about: kid.id)

    #expect(try triaged(sbd, report) == [kid.id])
    #expect(try holders(sbd, report) == [kid.id])
  }

  @Test func sbEventsWithTheOperatorAskKindShowsTheLineOnTheOwner() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    try ask(sbd, op, about: kid.id)

    let lines = try sbd.sb("events", "--json", "--session", kid.id, "--kind", "operator-ask").split(separator: "\n")

    try #require(lines.count == 1, "\(lines)")
    let event = try #require(JSON.parse(String(lines[0])))
    #expect(event["kind"]?.string == "operator-ask")
    #expect(event["data"]?["text"]?.string == Self.question, "\(event.text)")
  }

  @Test func theMCPReportToolRoutesTheReportToItsSession() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    let result = try MCPClient(sbd, env: inside(op.id)).call(
      "report", ["text": .string(Self.question), "needsYou": true, "session": "kid"])

    #expect(!result.isError, "\(result.text)")
    #expect(try askItem(sbd, kid.id) != nil)
    #expect(try item(sbd, op.id) == nil)
  }

  @Test func aReportWithoutNeedsYouIsRoutedNowhere() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let mark = try sbd.lastEventId(op.id)

    try reportHelpers.reported(sbd, op, "Removed the kid's worktree.", needsYou: false, about: kid.id)

    #expect(try events(sbd, op.id, "report-routed", after: mark).isEmpty)
    #expect(try events(sbd, kid.id, "operator-ask").isEmpty)
    #expect(try askItem(sbd, kid.id) == nil)
  }

  // MARK: The session that `--session` names (Risk 7)

  @Test func aReportAboutAConversationLandsOnIt() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)

    try ask(sbd, op, about: c.id)

    #expect(try askItem(sbd, c.id) != nil)
    #expect(try sbd.get(c.id).reason == Self.askReason)
  }

  @Test func aReportAboutAGroupChatLandsOnItAndPassesInInbox() throws {
    let sbd = try Instance()
    let chats = ChatTests()
    let kid = try sbd.new(name: "kid")
    _ = try chats.addGroup(sbd, "Flags", kid.id)
    let chat = try chats.replied(sbd, "Flags", "hello")
    let op = try idleOperator(sbd)

    try ask(sbd, op, about: chat.id)

    let s = try sbd.get(chat.id)
    #expect(s.triage?.source == .report, "\(String(describing: s.triage))")
    #expect(Triage.inInbox(s))
  }

  @Test func aConversationsReportItemPassesInInbox() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)

    try ask(sbd, op)

    let s = try sbd.get(c.id)
    #expect(s.triage?.source == .report, "\(String(describing: s.triage))")
    #expect(Triage.inInbox(s))
  }

  /// Decision 35: the Operator is never the owner that `about` names, so the report goes to the conversation.
  @Test func aReportAboutTheOperatorItselfLandsOnTheConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)

    let report = try ask(sbd, op, about: op.id)

    #expect(try holders(sbd, report) == [c.id])
    #expect(try sbd.get(op.id).state != .needsYou)
  }

  /// A paused session and a session marked done get a verdict before an ask, so an ask on one would show nowhere.
  @Test(arguments: ["pause", "done"]) func aReportAboutASessionThatCantShowAnAskLandsOnTheConversation(
    _ command: String
  ) throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    try sbd.sb(command, kid.id)

    let report = try ask(sbd, op, about: kid.id)

    #expect(try holders(sbd, report) == [c.id])
    #expect(try events(sbd, kid.id, "operator-ask").isEmpty)
  }

  @Test func aReportAboutAnUnknownSessionIsRefusedAndRecordsNothing() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let mark = try sbd.lastEventId(op.id)

    let r = try reportHelpers.report(sbd, from: op, Self.question, about: "nobody-by-that-name")

    #expect(r.status != 0)
    let kinds = try sbd.events(op.id, after: mark).map(\.kind).filter { $0.hasPrefix("report") }
    #expect(kinds.isEmpty, "\(kinds)")
  }

  // MARK: Reply (criterion 3)

  @Test func sbChooseReplySendsTheAnswerToTheOperatorWithTheOwnersName() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    let mark = try sbd.lastEventId(op.id)

    try reply(sbd, kid.id, "Yes, merge it.")

    let sent = try #require(try events(sbd, op.id, "sent", after: mark).last)
    #expect(sent.data["text"]?.string == "About kid: Yes, merge it.", Comment(rawValue: sent.data.text))
    #expect(sent.data["by"]?.string == "you", Comment(rawValue: sent.data.text))
    #expect(ids(sent.data["reports"]) == [report.id], Comment(rawValue: sent.data.text))
  }

  @Test func sbChooseReplySendsNothingToTheOwner() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    try ask(sbd, op, about: kid.id)
    let sent = try sbd.count("sent", of: kid.id)

    try reply(sbd, kid.id, "Yes, merge it.")

    #expect(try sbd.count("sent", of: kid.id) == sent)
    try sbd.waitFor(op.id, "the operator's reply", timeout: 30) { $0.lastReply == "Done: About kid: Yes, merge it." }
    #expect(try sbd.count("sent", of: kid.id) == sent)
  }

  @Test func sbChooseReplyClosesTheReportAndClearsTheOwnersItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    try reply(sbd, kid.id, "Yes, merge it.")

    #expect(try isOpen(sbd, report) == false)
    #expect(try askItem(sbd, kid.id) == nil)
  }

  /// The app's Reply calls `choose` with the item's ref.
  @Test func theChooseRequestWithTheItemsRefSendsTheAnswerToTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    let shown = try #require(try askItem(sbd, kid.id))
    let index = try #require(shown.options.firstIndex { $0.action == .reply }, "\(shown.options)")
    let mark = try sbd.lastEventId(op.id)

    _ = try sbd.client.call(
      "choose",
      [
        "session": .string(kid.id), "option": .string("\(index + 1)"), "text": "Yes, merge it.",
        "ref": .string(shown.ref),
      ])

    let sent = try #require(try events(sbd, op.id, "sent", after: mark).last)
    #expect(sent.data["text"]?.string == "About kid: Yes, merge it.", Comment(rawValue: sent.data.text))
    #expect(ids(sent.data["reports"]) == [report.id], Comment(rawValue: sent.data.text))
    #expect(try askItem(sbd, kid.id) == nil)
  }

  @Test func sbChooseReplyInsideClaudeIsRefusedAndLeavesTheAskOpen() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    let sent = try sbd.count("sent", of: op.id)

    let r = try sbd.run(["choose", kid.id, "Reply", "--text", "yes"], env: inside(c.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains("inside Claude Code"), "\(r.stderr)")
    #expect(try sbd.count("sent", of: op.id) == sent)
    #expect(try isOpen(sbd, report) == true)
    #expect(try askItem(sbd, kid.id) != nil)
  }

  /// A Reply answers every ask on its owner up to the item's ref, in one message.
  @Test func aReplyToTwoAsksOnOneOwnerClosesBoth() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let first = try ask(sbd, op, "PR alpha is green. Merge it?", about: kid.id)
    let second = try ask(sbd, op, "PR bravo is green. Merge it?", about: kid.id)
    let shown = try #require(try askItem(sbd, kid.id))
    #expect(shown.ref == "report:\(second.id)")
    #expect(shown.summary == "PR alpha is green. Merge it?\nPR bravo is green. Merge it?")
    let mark = try sbd.lastEventId(op.id)

    try reply(sbd, kid.id, "Merge both.")

    let sent = try #require(try events(sbd, op.id, "sent", after: mark).last)
    #expect(ids(sent.data["reports"]).sorted() == [first.id, second.id], Comment(rawValue: sent.data.text))
    #expect(try reports(sbd).map { $0["open"]?.bool } == [false, false])
  }

  /// A malformed `reports` would otherwise be dropped, and a `sent` without `reports` closes every open report.
  @Test func aSendWithMalformedReportsIsRefusedAndClosesNothing() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let first = try ask(sbd, op, "PR alpha is green. Merge it?", about: try sbd.new(name: "kid").id)
    let second = try ask(sbd, op, "PR bravo is green. Merge it?", about: try sbd.new(name: "kid2").id)
    let sent = try sbd.count("sent", of: op.id)

    for reports: JSON in ["10", [.string("10")], [1.5], .object([:])] {
      let answer = try sbd.sendLine(
        Instance.requestLine("send", ["session": .string(op.id), "text": "yes", "reports": reports]),
        to: sbd.home.socket)

      #expect(answer?["ok"]?.bool == false, "\(answer?.text ?? "no answer")")
      #expect(answer?.text.contains("reports") == true)
    }

    #expect(try sbd.count("sent", of: op.id) == sent)
    #expect(try isOpen(sbd, first) == true)
    #expect(try isOpen(sbd, second) == true)
  }

  // MARK: Acknowledge (criterion 4)

  @Test func sbAckOnTheOwnerRecordsReportClosedOnTheOperatorAndNoAckOnTheOwner() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    let mark = try sbd.lastEventId(op.id)

    try sbd.sb("ack", kid.id)

    let closed = try events(sbd, op.id, "report-closed", after: mark)
    try #require(closed.count == 1, "\(closed.map(\.data.text))")
    #expect(ids(closed[0].data["reports"]) == [report.id], Comment(rawValue: closed[0].data.text))
    #expect(try sbd.count("ack", of: kid.id) == 0)
  }

  @Test func sbAckOnTheOwnerClosesTheReportAndClearsTheItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    try sbd.sb("ack", kid.id)

    #expect(try isOpen(sbd, report) == false)
    #expect(try askItem(sbd, kid.id) == nil)
  }

  @Test func sbAckOnTheOwnerInsideClaudeIsRefusedAndLeavesTheAskOpen() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    let r = try sbd.run(["ack", kid.id], env: inside(c.id))

    #expect(r.status != 0)
    #expect(r.stderr.contains("inside Claude Code"), "\(r.stderr)")
    #expect(try isOpen(sbd, report) == true)
    #expect(try askItem(sbd, kid.id) != nil)
  }

  /// Q6: acknowledging an ask has no undo, just as a Reply has none.
  @Test func undoingTheAckOfAnAskIsRefusedAndTheReportStaysClosed() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    try sbd.sb("ack", kid.id)

    let error = failure(sbd, "ack", ["session": .string(kid.id), "undo": true])

    #expect(error.contains("isn't acknowledged"), Comment(rawValue: error))
    #expect(try isOpen(sbd, report) == false)
  }

  /// Decision 55: an ask outranks a card that doesn't block. An ack closes the ask, records no ack on the owner, and
  /// the card shows again.
  @Test func anAskOutranksANonBlockingSendCardAndTheCardReturnsAfterTheAck() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.idleSession(name: "kid")
    let card = JSON.object([
      "summary": "It finished.\nIt needs a call.", "options": [["label": "Go on", "action": "send"]],
    ]).text
    let set = try sbd.setSummary([], card, env: inside(kid.id))
    try #require(set.status == 0, Comment(rawValue: set.stderr))
    try #require(try item(sbd, kid.id)?.source != .report)
    let report = try ask(sbd, op, about: kid.id)
    try #require(try askItem(sbd, kid.id) != nil, "the ask does not outrank the card")

    try sbd.sb("ack", kid.id)

    #expect(try isOpen(sbd, report) == false)
    #expect(try sbd.count("ack", of: kid.id) == 0)
    let after = try item(sbd, kid.id)
    #expect(after != nil && after?.source != .report, "\(String(describing: after))")
  }

  /// A prompt that blocks the owner shows above the ask, so an ack answers the prompt's item and leaves the ask.
  @Test func sbAckWithABlockingPromptAboveTheAskLeavesTheReportOpen() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.idleSession(name: "kid")
    try sbd.sb("send", kid.id, "perm touch x")
    try sbd.waitFor(kid.id, "the permission card") { !$0.cards.isEmpty }
    let report = try ask(sbd, op, about: kid.id)
    try #require(try item(sbd, kid.id)?.source == .card)

    _ = try sbd.run("ack", kid.id)

    #expect(try isOpen(sbd, report) == true)
    #expect(try events(sbd, op.id, "report-closed").isEmpty)
  }

  // MARK: Two owners (criterion 5)

  enum Close: String, CaseIterable { case reply, ack }

  func close(_ sbd: Instance, _ how: Close, _ id: String) throws {
    switch how {
    case .reply: try reply(sbd, id, "Yes.")
    case .ack: try sbd.sb("ack", id)
    }
  }

  @Test(arguments: Close.allCases) func closingOneOwnersAskLeavesTheOtherOwnersAskOpen(_ how: Close) throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let alpha = try sbd.new(name: "alpha")
    let bravo = try sbd.new(name: "bravo")
    let first = try ask(sbd, op, "PR alpha is green. Merge it?", about: alpha.id)
    let second = try ask(sbd, op, "PR bravo is green. Merge it?", about: bravo.id)

    try close(sbd, how, alpha.id)

    #expect(try isOpen(sbd, first) == false)
    #expect(try isOpen(sbd, second) == true)
    #expect(try askItem(sbd, alpha.id) == nil)
    #expect(try askItem(sbd, bravo.id)?.ref == "report:\(second.id)")
  }

  /// The test runner sets no `CLAUDECODE`, so the message is the user's and closes every open report, as before.
  @Test func sbOperatorFromAShellClosesTheAsksOfEveryOwner() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let alpha = try sbd.new(name: "alpha")
    let bravo = try sbd.new(name: "bravo")
    try ask(sbd, op, "PR alpha is green. Merge it?", about: alpha.id)
    try ask(sbd, op, "PR bravo is green. Merge it?", about: bravo.id)

    try sbd.sb("operator", "Merge both.")

    #expect(try reports(sbd).map { $0["open"]?.bool } == [false, false])
    #expect(try askItem(sbd, alpha.id) == nil)
    #expect(try askItem(sbd, bravo.id) == nil)
  }

  // MARK: Closing paths agree (Risk 7 parity)

  enum Path: String, CaseIterable { case reply, ack, sbOperator }

  @Test(arguments: Path.allCases) func everyWayToAnswerClosesTheReportAndClearsEveryItem(_ path: Path) throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    switch path {
    case .reply: try reply(sbd, kid.id, "Yes.")
    case .ack: try sbd.sb("ack", kid.id)
    case .sbOperator: try sbd.sb("operator", "Yes.")
    }

    #expect(try reports(sbd).map { $0["open"]?.bool } == [false])
    #expect(try holders(sbd, report).isEmpty)
    #expect(try askItem(sbd, kid.id) == nil)
    #expect(try item(sbd, op.id) == nil)
  }

  // MARK: The owner when the report names no session (criterion 6)

  /// Gives the conversation the newest activity. The idle stop ends both conversations in one tick after a clock
  /// advance, and their SessionEnd events can land in either order.
  func touch(_ sbd: Instance, _ c: SessionSummary) throws {
    try sbd.sb("send", c.id, "later")
    try sbd.waitFor(c.id, "the conversation's reply", timeout: 30) { $0.lastReply == "Done: later" }
  }

  /// Decision 36: the newest message that a handed-off wait sent sets the conversation. A second conversation with
  /// newer activity shows that the owner is not the most recent conversation.
  @Test func aReportAfterAHandedOffWaitMessageLandsOnTheHandingConversation() throws {
    let sbd = try Instance()
    let handing = try conversation(sbd, "Plan the cache fix")
    _ = try handoff.waitInside(sbd, handing, ["--kind", "date", "--until", "1h", "--note", "check the dashboard"])
    let newer = try conversation(sbd, "Queue work")
    let op = try handoff.theOperator(sbd)
    try sbd.advanceClock(2 * WaitTests.hourMs)
    let message = try sbd.waitFor(
      "the handed-off wait message", fetch: { try sbd.sbdMessages(op.id).last }, until: { _ in true })
    try sbd.waitFor(op.id, "the operator's turn", timeout: 30) { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    try touch(sbd, newer)
    try #require(try conversationHelpers.conversations(sbd).first?.id == newer.id)

    let report = try ask(sbd, op)

    #expect(message.data["handedFrom"]?.string == handing.id, Comment(rawValue: message.data.text))
    #expect(try holders(sbd, report) == [handing.id])
  }

  /// A schedule prompt carries no `handedFrom`, so it clears the conversation that an earlier wait message set.
  @Test func aReportAfterAScheduledPromptLandsOnTheMostRecentConversation() throws {
    let sbd = try Instance()
    let handing = try conversation(sbd, "Plan the cache fix")
    _ = try handoff.waitInside(sbd, handing, ["--kind", "date", "--until", "1h"])
    let newer = try conversation(sbd, "Queue work")
    let op = try handoff.theOperator(sbd)
    try sbd.advanceClock(2 * WaitTests.hourMs)
    try sbd.waitFor(op.id, "the operator's turn", timeout: 30) { $0.lastReply?.hasPrefix("Done: Switchboard:") == true }
    try sbd.sb("schedule", "Operator", "--every", "1m", "check the queue")
    try sbd.advanceClock(ScheduleFireTests.pastDue)
    try sbd.waitFor(op.id, "the scheduled turn", timeout: 30) { $0.lastReply == "Done: check the queue" }
    try touch(sbd, newer)
    try #require(try conversationHelpers.conversations(sbd).first?.id == newer.id)

    let report = try ask(sbd, op)

    #expect(try holders(sbd, report) == [newer.id])
  }

  @Test func aReportWithNoSessionAndNoConversationStaysOnTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let mark = try sbd.lastEventId(op.id)

    let report = try ask(sbd, op)

    #expect(try events(sbd, op.id, "report-routed", after: mark).isEmpty)
    let s = try sbd.get(op.id)
    #expect(s.state == .needsYou, "\(s.state): \(s.reason)")
    #expect(try askItem(sbd, op.id)?.ref == "report:\(report.id)")
  }

  /// The Operator answers an ask that it kept with no "About" prefix.
  @Test func aReplyOnTheOperatorsOwnAskSendsTheTextWithoutAPrefix() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let report = try ask(sbd, op)
    let mark = try sbd.lastEventId(op.id)

    try reply(sbd, op.id, "Yes, merge it.")

    let sent = try #require(try events(sbd, op.id, "sent", after: mark).last)
    #expect(sent.data["text"]?.string == "Yes, merge it.", Comment(rawValue: sent.data.text))
    #expect(ids(sent.data["reports"]) == [report.id], Comment(rawValue: sent.data.text))
    #expect(try item(sbd, op.id) == nil)
  }

  /// Risk C: the conversation becomes the owner of the ask that no session could hold. Creating a conversation runs
  /// the sync, so the ask moves with no tick (Decision 53).
  @Test func anUnownedAskMovesToAConversationCreatedAfterIt() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let report = try ask(sbd, op)

    let c = try conversationHelpers.newConversation(sbd, name: "Queue work")

    #expect(try holders(sbd, report) == [c.id])
    #expect(try sbd.get(op.id).state != .needsYou)
  }

  // MARK: Removing the owner (criterion 7)

  @Test func removingTheOwnerMovesItsAskToTheMostRecentConversationAtOnce() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    try sbd.sb("rm", kid.id)

    #expect(try holders(sbd, report) == [c.id])
    #expect(try isOpen(sbd, report) == true)
  }

  /// A paused session and a session marked done can't show an ask, so `update` moves an ask they own at once.
  @Test(arguments: ["pause", "done"]) func anOwnerThatCantShowAnAskMovesItToTheMostRecentConversationAtOnce(
    _ command: String
  ) throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    try #require(try holders(sbd, report) == [kid.id])

    try sbd.sb(command, kid.id)

    #expect(try holders(sbd, report) == [c.id])
    #expect(try isOpen(sbd, report) == true)
  }

  @Test func removingTheOwnerWithNoConversationMovesItsAskToTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)

    try sbd.sb("rm", kid.id)

    #expect(try holders(sbd, report) == [op.id])
    #expect(try sbd.get(op.id).state == .needsYou)
  }

  // MARK: Overdue waits that the Operator holds (criterion 8)

  @Test func anOverdueActionWaitGivesItsSubjectAHeldItem() throws {
    let sbd = try Instance()
    _ = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    try sbd.sb("wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm")
    let wait = try #require(try handoff.theOperator(sbd).waits.last)

    try sbd.advanceClock(25 * WaitTests.hourMs)

    let due = try sbd.waitFor(kid.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }
    let item = try #require(due.triage)
    #expect(due.state == .needsYou)
    #expect(due.reason.hasPrefix("sbd still waits to remove the session: "), "\(due.reason)")
    #expect(item.source == .report)
    #expect(item.ref == "held:\(wait.id)")
    #expect(item.options.isEmpty, "\(item.options)")
    #expect(item.details.overdueWaits == [wait.id])
  }

  @Test func anOverdueActionWaitLeavesTheOperatorOutOfNeedsYou() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    try sbd.sb("wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm")

    try sbd.advanceClock(25 * WaitTests.hourMs)

    try sbd.waitFor(kid.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }
    let s = try sbd.get(op.id)
    #expect(s.state != .needsYou, "\(s.state): \(s.reason)")
    #expect(s.triage == nil, "\(String(describing: s.triage))")
  }

  @Test func theHeldItemsDetailsNameTheOverdueWaitsInSbGetJSON() throws {
    let sbd = try Instance()
    _ = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    try sbd.sb("wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm")
    let wait = try #require(try handoff.theOperator(sbd).waits.last)
    try sbd.advanceClock(25 * WaitTests.hourMs)
    try sbd.waitFor(kid.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }

    let details = try sbd.getJSON(kid.id)["triage"]?["message"]?["details"]

    #expect(details?["overdueWaits"] == .array([.string(wait.id)]), "\(String(describing: details))")
  }

  /// A wait with no action goes to the conversation that handed it off (Decision 38).
  @Test func anOverdueWaitWithNoActionGoesToItsHandingConversation() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Plan the cache fix")
    let kid = try sbd.new(name: "kid")
    _ = try handoff.waitInside(sbd, c, ["--kind", "session", "--target", kid.id, "--state", "done"])
    let op = try handoff.theOperator(sbd)
    let wait = try #require(op.waits.last)
    try #require(wait.handedFrom?.id == c.id)
    _ = try conversation(sbd, "Queue work")

    try sbd.advanceClock(25 * WaitTests.hourMs)

    let due = try sbd.waitFor(c.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }
    #expect(due.reason.hasPrefix("Background follow-through still waits: "), "\(due.reason)")
    #expect(due.triage?.details.overdueWaits == [wait.id])
    #expect(try sbd.get(op.id).state != .needsYou)
    #expect(try sbd.get(kid.id).triage?.ref.hasPrefix("held:") != true)
  }

  /// Risk C: clearing the Operator's wait runs the sync through `update`, so the held item goes with no tick.
  @Test func clearingTheOperatorsWaitRemovesTheHeldItemAtOnce() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    try sbd.sb("wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm")
    let wait = try #require(try handoff.theOperator(sbd).waits.last)
    try sbd.advanceClock(25 * WaitTests.hourMs)
    try sbd.waitFor(kid.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }

    try sbd.sb("wait", op.id, "--clear", "--id", wait.id)

    let s = try sbd.get(kid.id)
    #expect(s.triage?.ref.hasPrefix("held:") != true, "\(String(describing: s.triage))")
  }

  /// A held item's Acknowledge is the generic `ack` on its owner. It closes no report and leaves the Operator's wait.
  @Test func acknowledgingAHeldItemRecordsAnAckOnTheOwnerAndKeepsTheWait() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    try sbd.sb("wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm")
    let wait = try #require(try handoff.theOperator(sbd).waits.last)
    try sbd.advanceClock(25 * WaitTests.hourMs)
    try sbd.waitFor(kid.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }

    try sbd.sb("ack", kid.id)

    #expect(try events(sbd, kid.id, "ack").count == 1)
    #expect(try events(sbd, op.id, "report-closed").isEmpty)
    #expect(try handoff.theOperator(sbd).waits.contains { $0.id == wait.id })
    #expect(try sbd.get(kid.id).acknowledged == true)
  }

  /// Decision 43: a `notify` outcome on the Operator, such as a manual wait's recheck, keeps a rule item there.
  @Test func aManualWaitsRecheckOnTheOperatorGivesItARuleItem() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    try sbd.sb("wait", op.id, "--kind", "manual", "--note", "ask Alex", "--until", "1d")

    try sbd.advanceClock(25 * WaitTests.hourMs)

    let due = try sbd.waitFor(op.id, "the recheck") { $0.state == .needsYou }
    #expect(due.reason == "ask Alex: time to recheck")
    #expect(try item(sbd, op.id)?.source == .rule)
  }

  // MARK: sb ls (criterion 10)

  @Test func sbLsTextLeavesOutTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    let text = try sbd.sb("ls")

    #expect(!text.contains(op.id), "\(text)")
    #expect(text.contains(kid.id), "\(text)")
  }

  @Test func sbLsBriefLeavesOutTheOperator() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")

    let text = try sbd.sb("ls", "--brief")

    #expect(!text.contains(op.id), "\(text)")
    #expect(text.contains(kid.id), "\(text)")
  }

  @Test(arguments: [["ls", "--json"], ["ls", "--json", "--brief"]])
  func sbLsJSONKeepsTheOperatorsRow(_ args: [String]) throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)

    let rows = try #require(JSON.parse(try sbd.sb(args))?.array)

    #expect(rows.contains { $0["id"]?.string == op.id }, "\(rows)")
  }

  // MARK: A report recorded before routing (Decision 51)

  @Test func anOpenReportWithNoRoutingShowsAsOneItemOnItsSession() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    _ = try conversation(sbd, "Queue work")
    let t = try sbd.now()
    sbd.stopSbd()
    try Store(path: sbd.home.database).append(
      Event(
        session: op.id, t: t, kind: OperatorReport.event,
        data: ["text": .string(Self.question), "needsYou": true, "about": .string(kid.id)]))

    try sbd.startSbd()

    let report = try #require(try sbd.events(op.id, kind: "report").last)
    #expect(try holders(sbd, report) == [kid.id])
    #expect(try triaged(sbd, report) == [kid.id])
    #expect(try sbd.get(kid.id).reason == Self.askReason)
  }

  /// Decision 51: the old report shows on its session and leaves the Operator out of the Inbox, but `sb ack Operator`
  /// still closes it.
  @Test func sbAckOperatorClosesAnOpenReportWithNoRouting() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let t = try sbd.now()
    sbd.stopSbd()
    try Store(path: sbd.home.database).append(
      Event(
        session: op.id, t: t, kind: OperatorReport.event,
        data: ["text": .string(Self.question), "needsYou": true, "about": .string(kid.id)]))
    try sbd.startSbd()
    let report = try #require(try sbd.events(op.id, kind: "report").last)
    try #require(try holders(sbd, report) == [kid.id])

    try sbd.sb("ack", "Operator")

    #expect(try isOpen(sbd, report) == false)
    #expect(try holders(sbd, report).isEmpty)

    try sbd.sb("ack", "--undo", "Operator")

    #expect(try isOpen(sbd, report) == true)
    #expect(try holders(sbd, report) == [kid.id])
  }

  // MARK: The Operator is not woken by its own question (Decision 53)

  /// The kid is the Operator's child, and the ask moves it from Working to Needs you, so a digest or child notice
  /// about that change could reach the Operator.
  @Test func aRoutedReportSendsTheOperatorNoMessageAndNoDigest() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid: SessionSummary = try JSONCoding.decode(
      SessionSummary.self,
      from: sbd.sb("new", "--json", "--name", "kid", "--prompt", "slow held", sbd.work, env: inside(op.id)))
    defer { FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil) }
    try #require(kid.parent == op.id, "the kid's parent is \(kid.parent ?? "none")")
    try sbd.waitFor(kid.id, "the kid's turn") { $0.state == .working }
    let mark = try sbd.lastEventId(op.id)

    try ask(sbd, op, about: kid.id)
    try #require(try sbd.get(kid.id).reason == Self.askReason, "the ask did not change the kid's state")
    try sbd.advanceClock(1000)
    try sbd.advanceClock(1000)

    let woke = try sbd.events(op.id, after: mark).filter { $0.kind == "sent" || $0.kind == "digest" }
    #expect(woke.isEmpty, "\(woke.map { "\($0.kind) \($0.data.text)" })")
  }

  // MARK: A restart (Risk 7, Risk C)

  @Test func restartingSbdKeepsEachAskOnItsOwner() throws {
    let sbd = try Instance()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let onKid = try ask(sbd, op, "PR alpha is green. Merge it?", about: kid.id)
    let onC = try ask(sbd, op, "PR bravo is green. Merge it?")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try holders(sbd, onKid) == [kid.id])
    #expect(try holders(sbd, onC) == [c.id])
    #expect(try sbd.get(op.id).state != .needsYou)
  }

  /// A restart reads the ask into the child's item before it seeds the parent's mark, so the parent's digest reports
  /// the ask once.
  @Test func restartingSbdDoesNotTellAParentAgainAboutAnAskItHeard() throws {
    let sbd = try Instance()
    let digests = DigestTests()
    let parent = try digests.parent(sbd, .work)
    // The child's turn lasts until the report file exists, so the restart seeds the mark while the turn runs. Without
    // the ask, the seed would read the child as working.
    let kid = try digests.child(sbd, of: parent, name: "kid", prompt: "slow held")
    defer { FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil) }
    try sbd.waitFor(kid.id, "the child's turn") { $0.state == .working }
    let op = try idleOperator(sbd)
    try ask(sbd, op, about: kid.id)
    try sbd.waitFor(kid.id, "the ask on the child") { $0.state == .needsYou }
    try digests.prompt(sbd, parent, "first")
    let heard = digests.contexts(sbd, parent)
    try #require(heard.last?.contains("- kid (\(kid.id)): needs you") == true, "\(heard)")

    sbd.stopSbd()
    try sbd.startSbd()
    try #require(try sbd.get(kid.id).reason == Self.askReason)
    try digests.prompt(sbd, parent, "second")

    #expect(digests.contexts(sbd, parent).count == heard.count)
    #expect(try sbd.sbdMessages(parent.id).isEmpty)
  }

  @Test func anAcknowledgedAskStaysClosedAfterARestart() throws {
    let sbd = try Instance()
    let op = try idleOperator(sbd)
    let kid = try sbd.new(name: "kid")
    let report = try ask(sbd, op, about: kid.id)
    try sbd.sb("ack", kid.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try isOpen(sbd, report) == false)
    #expect(try askItem(sbd, kid.id) == nil)
  }

  // MARK: Parents (#417)

  @Test func aParentsCardListsAChildWhoseItemIsAnAsk() throws {
    let sbd = try Instance()
    let managers = ManagerTests()
    let parent = try managers.idle(sbd, name: "p")
    let kid = try managers.child(sbd, of: parent.id, name: "kid")
    try sbd.waitFor(kid.id, "the child's reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("ack", kid.id)
    let op = try idleOperator(sbd)
    try ask(sbd, op, about: kid.id)
    let asking = JSON.object([
      "summary": "It finished.\nIt needs a call.", "options": [["label": "Merge"], ["label": "Wait"]],
    ]).text

    let json = try #require(JSON.parse(try sbd.setSummary(["--json", parent.id], asking).stdout))

    #expect(json["childItems"]?.array?.map { $0["session"]?.string } == [kid.id], "\(json)")
  }

  // MARK: A --then report --needs-you action

  /// `runReport` passes the wait's subject as `about`, so the ask lands on the subject, not the arming conversation.
  @Test func aNeedsYouReportActionLandsOnTheWaitsSubject() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let c = try conversation(sbd, "Plan the cache fix")
    let note = "check the kid's answer"
    _ = try follow.arm(
      sbd,
      [
        "--kind", "session", "--target", kid.id, "--state", "working", "--then", "report", "--note", note,
        "--needs-you",
      ], from: c)

    try sbd.sb("send", kid.id, "slow 2")

    let report = try sbd.waitFor(
      "the report", timeout: 30, fetch: { try follow.reportEvents(sbd).last }, until: { _ in true })
    #expect(report.data["text"]?.string == note, Comment(rawValue: report.data.text))
    #expect(try holders(sbd, report) == [kid.id])
  }
}

/// Risk B: a routed held wait or ask never stops a wait on the owner's state from resolving. These tests reuse the
/// merge stubs and FakeGitHub of FollowThroughTests.
extension OperatorAskTests {
  var arming: WaitActionTests { WaitActionTests() }
  var follow: FollowThroughTests { FollowThroughTests() }

  /// Makes #18303 need a review, and returns an edit that restores the review that made it Ready to merge.
  func requireReview(_ github: FakeGitHub) -> () -> Void {
    var decision: JSON?
    var reviews: JSON?
    github.change(MergeTests.number) {
      decision = $0["reviewDecision"]
      reviews = $0["latestOpinionatedReviews"]
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    let (savedDecision, savedReviews) = (decision, reviews)
    return {
      github.change(MergeTests.number) {
        $0["reviewDecision"] = savedDecision
        $0["latestOpinionatedReviews"] = savedReviews
      }
    }
  }

  @Test func anOverdueMergeWaitStillMergesWhenItsSubjectBecomesReadyToMerge() throws {
    let github = try FakeGitHub()
    let sbd = try follow.instance(github)
    try sbd.serve(LiveGitHub(github))
    let approve = requireReview(github)
    let s = try sbd.session(in: MergeTests.charts, branch: MergeTests.branch, name: WaitActionTests.target)
    try sbd.poll()
    try sbd.waitFor(s.id, "the poller's read of #18303") { $0.pr?.number == MergeTests.number }
    let wait = try follow.arm(sbd, arming.mergeArgs(s))
    try sbd.advanceClock(25 * WaitTests.hourMs)
    try sbd.waitFor(s.id, "the held item") { $0.triage?.ref.hasPrefix("held:") == true }

    approve()
    try sbd.poll(all: true)

    try sbd.waitFor(s.id, "Ready to merge") { $0.state == .readyToMerge }
    try follow.judgment(sbd, about: wait)
    let r = try follow.approve(sbd, wait)
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    #expect(sbd.ghMerges().count == 1, "\(sbd.ghMerges())")
  }

  @Test func anOverdueRmWorktreeWaitStillResolvesWhenItsSubjectsPRMerges() throws {
    let github = try FakeGitHub()
    let sbd = try follow.instance(github)
    let s = try follow.chartsWorktreeSession(sbd)
    let wait = try follow.arm(sbd, ["--kind", "session", "--target", s.id, "--state", "done", "--then", "rm-worktree"])
    try sbd.advanceClock(25 * WaitTests.hourMs)
    // The subject's PR is Ready to merge, which a routed held wait never hides (Decision 39), so no held item shows.
    let held = try #require(try follow.operatorsWait(sbd, wait))
    try #require(held.isOverdue(now: try sbd.now()), "the wait is not overdue")
    try #require(try sbd.get(s.id).state == .readyToMerge)

    follow.mergeOnGitHub(github, head: try sbd.git(s.cwd, "rev-parse", "HEAD"))
    try sbd.poll(all: true)

    try sbd.waitFor("the wait to go", timeout: 30) { try follow.operatorsWait(sbd, wait) == nil }
    try sbd.waitFor("the removal", timeout: 30) { try !follow.sessionIds(sbd).contains(s.id) }
  }

  @Test func anOverdueActionWaitLeavesItsSubjectWorkingWhileItsTurnRuns() throws {
    let sbd = try Instance()
    let kid = try sbd.new(prompt: "slow held", name: "kid")
    // The kid reads Working before its turn starts. A clock jump between SessionStart and UserPromptSubmit would
    // let the idle stop end claude.
    try ScheduleFireTests().waitForPrompt(sbd, kid.id, "slow held")
    _ = try follow.arm(sbd, ["--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm"])

    try sbd.advanceClock(25 * WaitTests.hourMs)
    try sbd.advanceClock(1000)

    let s = try sbd.get(kid.id)
    #expect(s.state == .working, "\(s.state): \(s.reason)")
    // Once the turn ends, the held item shows, which proves that the wait was overdue and routed to the kid.
    FileManager.default.createFile(atPath: "\(sbd.home.path)/report", contents: nil)
    try sbd.waitFor(kid.id, "the held item after the turn") { $0.triage?.ref.hasPrefix("held:") == true }
  }

  /// Decision 39: the ask holds its owner in Needs you, so the conversation's wait for Ready to merge resolves only
  /// after the ask closes.
  @Test func aConversationsWaitForReadyToMergeResolvesAfterTheAskOnItsTargetCloses() throws {
    let github = try FakeGitHub()
    let sbd = try follow.instance(github)
    let s = try arming.readyTarget(sbd)
    let c = try arming.conversation(sbd)
    let op = try idleOperator(sbd)
    try ask(sbd, op, about: s.id)
    try #require(try sbd.get(s.id).state == .needsYou)
    try sbd.sb("wait", c.id, "--kind", "session", "--target", s.id, "--state", "ready_to_merge")
    try follow.tick(sbd, 2)
    try #require(try sbd.get(c.id).waits.count == 1, "the wait resolved while the ask was open")

    try reply(sbd, s.id, "Leave it.")

    try sbd.waitFor(s.id, "Ready to merge") { $0.state == .readyToMerge }
    try sbd.waitFor("the conversation's wait to resolve", timeout: 30) { try sbd.get(c.id).waits.isEmpty }
  }

  /// Decision 52: an armed merge awaiting judgment survives an ask on its subject, and merges once after the reply
  /// and the approval.
  @Test func aMergeAwaitingJudgmentSurvivesAnAskAndMergesOnceAfterTheReplyAndApproval() throws {
    let github = try FakeGitHub()
    let sbd = try follow.instance(github)
    let (s, wait) = try follow.askedMerge(github, sbd)
    let op = try follow.theOperator(sbd)
    try ask(sbd, op, "Is the runbook change safe?", about: s.id)
    try follow.tick(sbd, 2)
    try #require(try follow.operatorsWait(sbd, wait)?.actionStatus?.kind == .awaitingJudgment)

    try reply(sbd, s.id, "Yes.")
    try sbd.waitFor(s.id, "Ready to merge") { $0.state == .readyToMerge }
    let r = try follow.approve(sbd, wait)

    try #require(r.status == 0, Comment(rawValue: r.stderr))
    try sbd.waitFor("the merge", timeout: 30) { !sbd.ghMerges().isEmpty }
    try follow.tick(sbd, 2)
    #expect(sbd.ghMerges() == [follow.ghMerge(follow.head(github))], "\(sbd.ghMerges())")
  }
}

/// A host session is never an owner, and a host can't close reports.
extension OperatorAskTests {
  @Test func aReportAboutAHostSessionLandsOnTheConversation() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let mini = try sbd.startOnHost()
    let c = try conversation(sbd, "Queue work")
    let op = try idleOperator(sbd)

    let report = try ask(sbd, op, about: mini.id)

    #expect(try holders(sbd, report) == [c.id])
    #expect(try sbd.events(mini.id, kind: "operator-ask").isEmpty)
  }

  @Test func aSendFromAHostCarryingReportsClosesNothing() throws {
    let sbd = try Instance.remote(config: Instance.shortHostWait)
    let mini = try sbd.startOnHost()
    let op = try idleOperator(sbd)
    let report = try ask(sbd, op)
    let reports: JSON = [.number(Double(report.id))]

    for session in [mini.id, op.id] {
      _ = try? sbd.sendLine(
        Instance.requestLine("send", ["session": .string(session), "text": "yes", "reports": reports]),
        to: sbd.hostSocket("mini"))
    }

    #expect(try isOpen(sbd, report) == true)
    #expect(try sbd.events(op.id, kind: "sent").allSatisfy { $0.data["reports"] == nil })
  }
}
