import Foundation
import Testing

@testable import SwitchboardCore

/// The operator's reports and its Inbox policy (Risk 2): the operator has an
/// item if and only if a blocking prompt, a trust exit, a `notify` outcome, or
/// an open report or overdue wait that sbd could not route to another session
/// exists (Decision 43). The suites nest under one name, so
/// `--filter TriageOperatorTests` runs them all.
@Suite struct TriageOperatorTests {}

// MARK: Events and sessions

/// The time at which every builder below evaluates a session.
private let opNow: Int64 = 1000

/// A `report` event that the `operator-report` request records.
func opReport(_ id: Int64, _ text: String, needsYou: Bool = true, about: String? = nil, t: Int64? = nil) -> Event {
  var data: [String: JSON] = ["text": .string(text), "needsYou": .bool(needsYou)]
  if let about { data["about"] = .string(about) }
  return Event(id: id, session: "s1", t: t ?? id, kind: "report", data: .object(data))
}

/// A `sent` event for a message that the user wrote, from a terminal or the app.
func opUserSent(_ id: Int64, _ text: String, t: Int64? = nil) -> Event {
  Event(
    id: id, session: "s1", t: t ?? id, kind: "sent", data: ["text": .string(text), "delivery": "pasted", "by": "you"])
}

/// A `sent` event for a message that a Claude Code wrote. A Claude Code outside a session, or in a session that sbd
/// no longer knows, sends no `from`.
func opClaudeSent(_ id: Int64, _ text: String, from: String? = nil) -> Event {
  var data: [String: JSON] = ["text": .string(text), "delivery": "pasted", "by": "claude"]
  if let from { data["from"] = .string(from) }
  return Event(id: id, session: "s1", t: id, kind: "sent", data: .object(data))
}

/// A `sent` event with neither `by` nor `from`, as a log written before sbd recorded every author holds.
func opUnattributedSent(_ id: Int64, _ text: String) -> Event {
  Event(id: id, session: "s1", t: id, kind: "sent", data: ["text": .string(text), "delivery": "pasted"])
}

/// A `sent` event for a message that sbd sent on its own, such as a wait's outcome.
func opSbdSent(_ id: Int64, _ text: String) -> Event {
  Event(id: id, session: "s1", t: id, kind: "sent", data: ["text": .string(text), "delivery": "pasted", "by": "sbd"])
}

/// The `ack` event that the Inbox's Acknowledge records.
func opAck(_ id: Int64, reason: String = "anything", t: Int64? = nil) -> Event {
  Event(id: id, session: "s1", t: t ?? id, kind: "ack", data: ["state": "needs_you", "reason": .string(reason)])
}

func opPrompt(_ id: Int64, _ text: String) -> Event {
  Event(id: id, session: "s1", t: id, kind: "UserPromptSubmit", data: ["prompt": .string(text)])
}

/// A turn that the message started and that ended with the stub's reply.
func opTurn(_ id: Int64, _ text: String) -> [Event] { [opPrompt(id, text), stop(id + 1, id + 1, "Done: \(text)")] }

/// The operator's first turn, which ended with an informational reply.
let opIdle: [Event] = opTurn(1, "hello")

/// A `wait-resolved` event of a wait that notifies.
func opNotified(_ id: Int64) throws -> Event {
  let wait = try JSON(encoding: Wait(id: "w9", kind: .date, until: 0, created: 0, then: .notify))
  return Event(id: id, session: "s1", t: id, kind: "wait-resolved", data: ["wait": wait, "outcome": "the time came"])
}

/// A session wait that passed its recheck time before `opNow`.
let overdueWait = Wait(
  id: "w1", kind: .session, session: Wait.SessionTarget(id: "k1", name: "kid"), state: .done, created: 0,
  recheck: opNow / 2)

/// A session wait whose recheck time is after `opNow`.
let openWait = Wait(
  id: "w2", kind: .session, session: Wait.SessionTarget(id: "k1", name: "kid"), state: .done, created: 0,
  recheck: opNow * 10)

func kindSession(_ kind: SessionKind, waits: [Wait] = [], done: Bool = false) -> Session {
  let name = kind == .operator ? Manager.operatorName : "s1"
  var s = Session(id: "s1", name: name, cwd: "/tmp", claudeSessionId: "uuid", created: 0)
  switch kind {
  case .work: break
  case .manager: s.manager = true
  case .chat: s.chat = "g1"
  case .operator:
    s.manager = true
    s.isOperator = true
  }
  s.done = done
  if !waits.isEmpty { s.waits = waits }
  return s
}

func operatorSession(waits: [Wait] = []) -> Session { kindSession(.operator, waits: waits) }

func opVerdict(_ s: Session, _ f: SessionFacts) -> Verdict { Attention.evaluate(s, f, now: opNow) }

/// The session as sbd lists it: its waits, cards, open prompt, verdict, and the item that sbd builds.
func opSummary(_ s: Session, _ f: SessionFacts) -> SessionSummary {
  let verdict = opVerdict(s, f)
  var out = SessionSummary(
    id: s.id, name: s.name, cwd: s.cwd, repo: nil, branch: nil, claudeSessionId: s.claudeSessionId,
    state: verdict.state, reason: verdict.reason, since: 0, lastActivity: f.lastActivity, live: true, claudePid: nil,
    attached: false, lastReply: f.lastReply, waits: s.waits ?? [], notes: [], cards: f.cards,
    openPrompt: f.openPermission != nil || f.openQuestion != nil, markedDone: s.done)
  out.kind = s.kind
  out.manager = s.manager
  out.chat = s.chat
  out.triage = Triage.itemAndDecisions(f, verdict, kind: s.kind).item
  return out
}

/// The operator's facts with the items that sbd routes back to it: `OperatorItems.assign` over its open reports and
/// waits. Only the operator and `conversation` are live, so without a conversation every item stays on the operator.
func opRouted(_ s: Session, _ f: SessionFacts, conversation: String? = nil) -> SessionFacts {
  var f = f
  let live: Set<String> = conversation.map { [s.id, $0] } ?? [s.id]
  let items = OperatorItems.assign(
    openReports: f.openReports, reportOwners: f.reportOwners, waits: s.waits ?? [], operatorID: s.id,
    isLive: { live.contains($0) }, newestConversation: conversation)
  f.operatorItems = items[s.id] ?? .init()
  return f
}

// MARK: The policy

extension TriageOperatorTests {
  @Suite struct Policy {
    @Test func theOperatorsInboxItemsAreTheOperatorPolicy() {
      #expect(SessionKind.operator.inboxItems == .operatorItems)
    }

    @Test(arguments: [SessionKind.manager, .chat]) func aConversationKeepsOnlyItsBlockingPrompts(_ kind: SessionKind) {
      #expect(kind.inboxItems == .blockingPrompts)
    }

    @Test func theOperatorIsNeverSummarized() {
      #expect(!Triage.summarizes(.operator))
    }

    @Test func theReportSourceEncodesAsReport() throws {
      #expect(TriageSource.report.rawValue == "report")
      #expect(try JSONCoding.decode([TriageSource].self, from: #"["report"]"#) == [.report])
    }
  }
}

// MARK: The fold (SessionFacts.openReports)

extension TriageOperatorTests {
  @Suite struct ReportFold {
    @Test func aNeedsYouReportIsOpen() {
      let f = facts(opIdle + [opReport(10, "PR #12 is green. Merge it?", about: "k1")])

      #expect(f.openReports.map(\.text) == ["PR #12 is green. Merge it?"])
      #expect(f.openReports.map(\.about) == ["k1"])
      #expect(f.openReports.map(\.needsYou) == [true])
    }

    @Test func anOpenReportKeepsItsEventsIdAndTime() {
      let f = facts(opIdle + [opReport(10, "Merge it?", t: 77)])

      #expect(f.openReports.map(\.id) == [10])
      #expect(f.openReports.map(\.t) == [77])
    }

    @Test func aReportWithoutAboutHasNoAbout() {
      let f = facts(opIdle + [opReport(10, "Merge it?")])

      #expect(f.openReports.map(\.about) == [nil])
    }

    @Test func aReportWithoutNeedsYouIsNotOpen() {
      let f = facts(opIdle + [opReport(10, "Removed the kid's worktree.", needsYou: false)])

      #expect(f.openReports.isEmpty)
    }

    @Test func reportsStayOpenInTheOrderTheyWereRecorded() {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), opReport(12, "c")])

      #expect(f.openReports.map(\.text) == ["a", "b", "c"])
    }

    @Test func aMessageThatSbdSentClosesNothing() {
      let text = "Switchboard: kid to reach Done: it did."
      let f = facts(opIdle + [opReport(10, "Merge it?"), opSbdSent(11, text)] + opTurn(12, text))

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    @Test(arguments: [nil, "c1"] as [String?]) func aMessageThatAClaudeCodeWroteClosesNothing(_ from: String?) {
      let text = "Keep 10 sessions on the queue."
      let f = facts(opIdle + [opReport(10, "Merge it?"), opClaudeSent(11, text, from: from)] + opTurn(12, text))

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    /// Only `by: you` names the user, so a `sent` event that names no author closes nothing.
    @Test func aMessageWithNeitherByNorFromClosesNothing() {
      let f = facts(opIdle + [opReport(10, "Merge it?"), opUnattributedSent(11, "yes")] + opTurn(12, "yes"))

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    /// Any `by` that is not exactly `you` leaves the reports open, whatever its JSON type.
    @Test(arguments: [
      JSON.string("claude"), .string("sbd"), .string(""), .string("null"), .string("You"), .string(" you"), .null,
      .bool(true),
    ])
    func aMessageWhoseByIsNotYouClosesNothing(_ by: JSON) {
      let sent = Event(
        id: 11, session: "s1", t: 11, kind: "sent", data: ["text": "yes", "delivery": "pasted", "by": by])
      let f = facts(opIdle + [opReport(10, "Merge it?"), sent])

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    /// The user's message closes the reports even when it waits in the queue behind a turn.
    @Test func aQueuedMessageThatTheUserWroteClosesTheReports() {
      let sent = Event(
        id: 11, session: "s1", t: 11, kind: "sent", data: ["text": "yes", "delivery": "queued", "by": "you"])
      let f = facts(opIdle + [opReport(10, "Merge it?"), sent])

      #expect(f.openReports.isEmpty)
    }

    @Test func aMessageThatTheUserWroteClosesTheEarlierReports() {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), opUserSent(12, "yes")])

      #expect(f.openReports.isEmpty)
    }

    @Test func aReportAfterTheUsersMessageStaysOpen() {
      let f = facts(opIdle + [opReport(10, "a"), opUserSent(11, "yes"), opReport(12, "b")])

      #expect(f.openReports.map(\.text) == ["b"])
    }

    /// The fold reads the `sent` event, so a prompt that no `sent` event names closes nothing.
    @Test func aPromptWithoutASentEventClosesNothing() {
      let f = facts(opIdle + [opReport(10, "Merge it?")] + opTurn(11, "yes"))

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    @Test func anAckClosesOnlyTheReportsRecordedBeforeIt() {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), opAck(12), opReport(13, "c")])

      #expect(f.openReports.map(\.text) == ["c"])
    }

    /// The Inbox shows a blocking prompt instead of the reports, so its acknowledgment closes none.
    @Test func anAckWhileAPromptBlocksClosesNothing() {
      let f = facts([opReport(0, "Merge it?", t: 0)] + permissionTurn() + [opAck(50)])

      #expect(f.openReports.map(\.text) == ["Merge it?"])
    }

    /// A report whose text repeats an acknowledged reason is a new item.
    @Test func aReportAfterAnAckIsNotHeldByThatAck() throws {
      let s = operatorSession()
      let f = opRouted(
        s, facts(opIdle + [opReport(10, "Merge it?"), opAck(11, reason: "Merge it?"), opReport(12, "Merge it?")]))
      let verdict = Attention.shown(opVerdict(s, f), f, now: opNow, acknowledgedMs: 3_600_000)

      #expect(verdict.state == .needsYou)
      #expect(try #require(item(f, session: s)).source == .report)
    }

    /// "Before" is the log's order, so events recorded in the same millisecond still close in order.
    @Test func anAckInTheSameMillisecondClosesOnlyTheReportBeforeIt() {
      let f = facts(opIdle + [opReport(10, "a", t: 50), opAck(11, t: 50), opReport(12, "b", t: 50)])

      #expect(f.openReports.map(\.text) == ["b"])
    }

    @Test func aUsersMessageInTheSameMillisecondClosesOnlyTheReportBeforeIt() {
      let f = facts(opIdle + [opReport(10, "a", t: 50), opUserSent(11, "yes", t: 50), opReport(12, "b", t: 50)])

      #expect(f.openReports.map(\.text) == ["b"])
    }

    @Test func aReplayOfTheSameEventsGivesTheSameOpenReports() {
      let events = opIdle + [opReport(10, "a"), opAck(11), opReport(12, "b"), opSbdSent(13, "x"), opReport(14, "c")]

      #expect(facts(events).openReports == facts(events).openReports)
      #expect(facts(events).openReports.map(\.text) == ["b", "c"])
    }
  }
}

// MARK: Undoing the ack (SessionFacts.acknowledgedReports)

/// The `unack` event that the Inbox's Undo records.
func opUnack(_ id: Int64) -> Event { Event(id: id, session: "s1", t: id, kind: "unack", data: [:]) }

/// A turn whose Bash call opens a permission prompt, with event ids from `id`.
func opPermissionTurn(_ id: Int64) -> [Event] {
  [
    opPrompt(id, "go"), Event(id: id + 1, session: "s1", t: id + 1, kind: "PreToolUse", data: .object(touchCall)),
    Event(id: id + 2, session: "s1", t: id + 2, kind: "PermissionRequest", data: .object(touch)),
  ]
}

extension TriageOperatorTests {
  @Suite struct AckUndoFold {
    @Test func anAckMovesTheOpenReportsToAcknowledgedReports() {
      let reports = [opReport(10, "a", about: "k1", t: 70), opReport(11, "b", t: 71)]
      let open = facts(opIdle + reports).openReports

      let f = facts(opIdle + reports + [opAck(12)])

      #expect(f.acknowledgedReports == open)
      #expect(f.openReports.isEmpty)
    }

    @Test func anUnackReopensTheReportsThatTheAckClosedInTheirOrder() {
      let reports = [opReport(10, "a"), opReport(11, "b"), opReport(12, "c")]
      let open = facts(opIdle + reports).openReports

      let f = facts(opIdle + reports + [opAck(13), opUnack(14)])

      #expect(f.openReports == open)
      #expect(f.acknowledgedReports.isEmpty)
    }

    @Test func aSecondUnackReopensNothingMore() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opUnack(12), opUnack(13)])

      #expect(f.openReports.map(\.id) == [10])
    }

    @Test func anAckAfterAnUnackClosesTheReportsAgain() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opUnack(12), opAck(13)])

      #expect(f.openReports.isEmpty)
      #expect(f.acknowledgedReports.map(\.id) == [10])
    }

    /// The ack closed nothing, so its unack must leave the report that stayed open.
    @Test func anUnackAfterAnAckWhileAPromptBlocksKeepsTheOpenReport() {
      let f = facts([opReport(0, "Merge it?", t: 0)] + permissionTurn() + [opAck(50), opUnack(51)])

      #expect(f.openReports.map(\.text) == ["Merge it?"])
      #expect(f.acknowledgedReports.isEmpty)
    }

    /// Every ack replaces the list. The second ack closed no reports, so the unack reopens none.
    @Test func anUnackAfterTheAckOfALaterPromptReopensNoReports() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11)] + opPermissionTurn(20) + [opAck(30), opUnack(31)])

      #expect(f.openReports.isEmpty)
    }

    @Test func anUnackAfterANewReportReopensNoneOfTheAcknowledgedReports() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opReport(12, "b"), opUnack(13)])

      #expect(f.openReports.map(\.id) == [12])
    }

    /// Only a `needsYou` report opens an item, so a report without it keeps the list.
    @Test func aReportWithoutNeedsYouKeepsAcknowledgedReports() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opReport(12, "Removed it.", needsYou: false), opUnack(13)])

      #expect(f.openReports.map(\.id) == [10])
    }

    @Test func anUnackAfterTheUsersMessageReopensNothing() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opUserSent(12, "yes")] + opTurn(13, "yes") + [opUnack(15)])

      #expect(f.openReports.isEmpty)
      #expect(f.acknowledgedReports.isEmpty)
    }

    /// A message that the user did not write closes no reports, so it keeps the list too.
    @Test func anUnackAfterAMessageFromClaudeReopensTheReports() {
      let text = "Keep 10 sessions on the queue."
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opClaudeSent(12, text)] + opTurn(13, text) + [opUnack(15)])

      #expect(f.openReports.map(\.id) == [10])
    }

    @Test func anUnackAfterNewTurnsReopensTheReportsInTheirOrder() {
      let reports = [opReport(10, "a"), opReport(11, "b")]
      let open = facts(opIdle + reports).openReports

      let f = facts(opIdle + reports + [opAck(12)] + opTurn(13, "go") + opTurn(15, "again") + [opUnack(17)])

      #expect(f.openReports == open)
    }
  }
}

// MARK: The shown verdict of acknowledged reports (Attention.shown with a kind)

/// The verdict that sbd shows for a session of `kind`, with sbd's default acknowledgment period.
func opShown(_ verdict: Verdict, _ f: SessionFacts, kind: SessionKind = .operator) -> Verdict {
  Attention.shown(verdict, f, now: opNow, acknowledgedMs: RecheckSettings().acknowledgedMs, kind: kind)
}

extension TriageOperatorTests {
  @Suite struct AckUndoShown {
    static let statesOutsideTheInbox = AttentionState.allCases.filter { !AttentionState.inbox.contains($0) }

    @Test(arguments: statesOutsideTheInbox)
    func aVerdictOutsideTheInboxWithAcknowledgedReportsIsAcknowledged(_ state: AttentionState) {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11)])

      let shown = opShown(Verdict(state: state, reason: "x"), f)

      #expect(shown.acknowledged)
      #expect(shown.state == state)
      #expect(shown.reason == "x")
    }

    @Test func aVerdictAfterAnUnackIsNotAcknowledged() {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11), opUnack(12), opPrompt(13, "go")])

      #expect(!opShown(Verdict(state: .working, reason: "x"), f).acknowledged)
    }

    /// A prompt that opens after the ack is a new item. The acknowledged reports must not hide it.
    @Test func aBlockingPromptAfterTheAckStaysInTheInbox() throws {
      let f = facts(opIdle + [opReport(10, "a"), opAck(11)] + opPermissionTurn(20))
      let shown = opShown(opVerdict(operatorSession(), f), f)

      #expect(shown.state == .needsYou, "\(shown.reason)")
      #expect(!shown.acknowledged)
      #expect(try #require(item(f, session: operatorSession())).source == .card)
    }

    /// An overdue wait that sbd could not route is the operator's item. The acknowledged reports must not hide it.
    @Test func anOverdueWaitAfterTheAckStaysInTheInbox() throws {
      let s = operatorSession(waits: [overdueWait])
      let f = opRouted(s, facts(opIdle + [opReport(10, "a"), opAck(11)]))
      let verdict = opVerdict(s, f)
      try #require(verdict.fromOperator, "\(verdict.state) \(verdict.reason)")

      let shown = opShown(verdict, f)

      #expect(shown.state == .needsYou, "\(shown.reason)")
      #expect(!shown.acknowledged)
    }

    /// An idle operator's verdict after the ack is Waiting, which gives the operator no item. The service's undo
    /// accepts only an acknowledged verdict, so this one must read as acknowledged.
    @Test func theIdleOperatorAfterAnAckThatClosedItsReportsIsAcknowledged() throws {
      let s = operatorSession()
      let before = opRouted(s, facts(opIdle + [opReport(10, "Merge it?")]))
      let ack = Event(
        id: 11, session: "s1", t: 11, kind: "ack",
        data: try JSON(encoding: Acknowledgment(opVerdict(s, before), before)))
      let f = opRouted(s, facts(opIdle + [opReport(10, "Merge it?"), ack]))
      let verdict = opVerdict(s, f)
      try #require(item(f, session: s) == nil)

      #expect(opShown(verdict, f).acknowledged, "\(verdict.state) \(verdict.reason)")
    }
  }
}

// MARK: The item

extension TriageOperatorTests {
  @Suite struct ReportItem {
    /// The facts with the open reports that sbd could not route to another session, so they stay on the operator.
    func routed(_ events: [Event]) -> SessionFacts { opRouted(operatorSession(), facts(events)) }

    @Test func anOpenReportGivesAReportItem() throws {
      let f = routed(opIdle + [opReport(10, "PR #12 is green. Merge it?")])

      let report = try #require(item(f, session: operatorSession()))

      #expect(report.source == .report)
    }

    @Test func theReportItemHasAReplyOption() throws {
      let f = routed(opIdle + [opReport(10, "PR #12 is green. Merge it?")])

      let report = try #require(item(f, session: operatorSession()))

      #expect(report.options.contains { $0.action == .reply }, "\(report.options)")
    }

    @Test func theReportItemListsEveryOpenReportUpToTheSummaryLines() throws {
      let texts = ["PR alpha is green.", "PR bravo is green.", "PR charlie is green."]
      try #require(texts.count == TriageCard.summaryLines)
      let f = routed(opIdle + texts.enumerated().map { opReport(Int64(10 + $0.offset), $0.element) })

      let report = try #require(item(f, session: operatorSession()))

      for text in texts { #expect(report.summary.contains(text), "\(report.summary)") }
    }

    @Test func theReportItemCountsTheReportsPastTheSummaryLines() throws {
      let texts = [
        "PR alpha is green.", "PR bravo is green.", "PR charlie is green.", "PR delta is green.", "PR echo.",
      ]
      let f = routed(opIdle + texts.enumerated().map { opReport(Int64(10 + $0.offset), $0.element) })

      let report = try #require(item(f, session: operatorSession()))

      let listed = texts.filter { report.summary.contains($0) }
      #expect(listed.count == TriageCard.summaryLines, "\(report.summary)")
      #expect(report.summary.contains("\(texts.count - TriageCard.summaryLines) more"), "\(report.summary)")
    }

    @Test func theReportItemLeavesOutAClosedReport() throws {
      let f = routed(opIdle + [opReport(10, "PR alpha is green."), opAck(11), opReport(12, "PR bravo is green.")])

      let report = try #require(item(f, session: operatorSession()))

      #expect(report.summary.contains("PR bravo is green."), "\(report.summary)")
      #expect(!report.summary.contains("PR alpha is green."), "\(report.summary)")
    }

    /// `choose` refuses a ref that is no longer the session's, so a new report must change the ref.
    @Test func aNewReportChangesTheItemsRef() throws {
      let one = routed(opIdle + [opReport(10, "a")])
      let two = routed(opIdle + [opReport(10, "a"), opReport(11, "b")])

      let first = try #require(item(one, session: operatorSession()))
      let second = try #require(item(two, session: operatorSession()))

      #expect(!first.ref.isEmpty)
      #expect(first.ref != second.ref)
    }

    @Test func theOperatorsItemHasNoDecisionList() {
      let f = routed(opIdle + [opReport(10, "a")])

      let built = Triage.itemAndDecisions(f, opVerdict(operatorSession(), f), kind: .operator)

      #expect(built.decisions == nil)
      #expect(!built.decisionsSent)
    }
  }
}

// MARK: The shapes of Risk 2, against both itemAndDecisions and inInbox

/// What the operator holds, and the source of the item that it must get, or nil for none. sbd routes the operator's
/// open reports and waits to a Manager conversation while one exists, and back to the operator while none does.
struct OperatorShape: CustomTestStringConvertible, Sendable {
  var name: String
  var events: @Sendable () throws -> [Event]
  var waits: [Wait] = []
  /// The item's source while no conversation exists, so every report and wait stays on the operator.
  var item: TriageSource?
  /// The item's source while a conversation exists, so the reports and waits go to it.
  var routed: TriageSource?
  var testDescription: String { name }

  func source(conversation: Bool) -> TriageSource? { conversation ? routed : item }
}

let operatorShapes: [OperatorShape] = [
  OperatorShape(
    name: "a reply that reads as a question, with no report",
    events: { [opPrompt(1, "go"), stop(2, 2, proseQuestion)] }, item: nil, routed: nil),
  OperatorShape(
    name: "a reply that offers a next step, with no report",
    events: { [opPrompt(1, "go"), stop(2, 2, "I removed the worktree. Want me to top up the queue?")] }, item: nil,
    routed: nil),
  OperatorShape(name: "an informational reply, with no report", events: { opIdle }, item: nil, routed: nil),
  OperatorShape(
    name: "an sb summary set card, with no report", events: { opIdle + [try summaryEvent(9, 9, sessionCard)] },
    item: nil, routed: nil),
  OperatorShape(name: "a new operator that never had a prompt", events: { [] }, item: nil, routed: nil),
  OperatorShape(
    name: "an exit at the trust dialog", events: { trustLaunch() + [trustClosed(5)] }, item: .rule, routed: .rule),
  OperatorShape(
    name: "an open wait that is not overdue", events: { opIdle }, waits: [openWait], item: nil, routed: nil),
  OperatorShape(
    name: "a report without needsYou", events: { opIdle + [opReport(10, "Removed it.", needsYou: false)] },
    item: nil, routed: nil),
  OperatorShape(name: "one open report", events: { opIdle + [opReport(10, "Merge it?")] }, item: .report, routed: nil),
  OperatorShape(
    name: "three open reports", events: { opIdle + [opReport(10, "a"), opReport(11, "b"), opReport(12, "c")] },
    item: .report, routed: nil),
  OperatorShape(
    name: "four open reports",
    events: { opIdle + [opReport(10, "a"), opReport(11, "b"), opReport(12, "c"), opReport(13, "d")] },
    item: .report, routed: nil),
  OperatorShape(
    name: "a report, then a blocking permission card",
    events: { [opReport(0, "Merge it?", t: 0)] + permissionTurn() }, item: .card, routed: .card),
  OperatorShape(
    name: "a blocking permission card, then a report",
    events: { permissionTurn() + [opReport(10, "Merge it?")] }, item: .card, routed: .card),
  OperatorShape(
    name: "a blocking question card and a report", events: { questionTurn() + [opReport(10, "Merge it?")] },
    item: .card, routed: .card),
  OperatorShape(
    name: "a report and a send card that does not block",
    events: { opIdle + [sendPending(), opReport(10, "Merge it?")] }, item: .report, routed: nil),
  OperatorShape(
    name: "a report closed by the user's message",
    events: { opIdle + [opReport(10, "Merge it?"), opUserSent(11, "yes")] + opTurn(12, "yes") }, item: nil,
    routed: nil),
  OperatorShape(
    name: "a report closed by ack",
    events: { opIdle + [opReport(10, "Merge it?"), opAck(11)] }, item: nil, routed: nil),
  OperatorShape(
    name: "a report closed by ack, then a later report",
    events: { opIdle + [opReport(10, "Merge it?"), opAck(11), opReport(12, "Remove kid?")] }, item: .report,
    routed: nil),
  OperatorShape(
    name: "a report, then a wait message that sbd sent",
    events: {
      let text = "Switchboard: kid to reach Done: it did."
      return opIdle + [opReport(10, "Merge it?"), opSbdSent(11, text)] + opTurn(12, text)
    }, item: .report, routed: nil),
  OperatorShape(
    name: "a report, then a message from a conversation",
    events: {
      let text = "Keep 10 sessions on the queue."
      return opIdle + [opReport(10, "Merge it?"), opClaudeSent(11, text, from: "c1")] + opTurn(12, text)
    }, item: .report, routed: nil),
  OperatorShape(
    name: "a report, then a message that a Claude Code outside a session wrote",
    events: {
      let text = "Keep 10 sessions on the queue."
      return opIdle + [opReport(10, "Merge it?"), opClaudeSent(11, text)] + opTurn(12, text)
    }, item: .report, routed: nil),
  OperatorShape(
    name: "a report, then a message with neither by nor from",
    events: { opIdle + [opReport(10, "Merge it?"), opUnattributedSent(11, "yes")] + opTurn(12, "yes") },
    item: .report, routed: nil),
  OperatorShape(name: "an overdue wait", events: { opIdle }, waits: [overdueWait], item: .report, routed: nil),
  OperatorShape(name: "a notify outcome", events: { opIdle + [try opNotified(5)] }, item: .rule, routed: .rule),
  OperatorShape(
    name: "a report and an overdue wait", events: { opIdle + [opReport(10, "Merge it?")] }, waits: [overdueWait],
    item: .report, routed: nil),
  OperatorShape(
    name: "a notify outcome, then a report", events: { opIdle + [try opNotified(5), opReport(10, "Merge it?")] },
    item: .report, routed: .rule),
  OperatorShape(
    name: "a report and an open wait that is not overdue", events: { opIdle + [opReport(10, "Merge it?")] },
    waits: [openWait], item: .report, routed: nil),
]

extension TriageOperatorTests {
  @Suite struct Shapes {
    @Test(arguments: operatorShapes, [false, true])
    func theOperatorsItemComesFromTheShape(_ shape: OperatorShape, _ conversation: Bool) throws {
      let s = operatorSession(waits: shape.waits)
      let f = opRouted(s, facts(try shape.events()), conversation: conversation ? "c1" : nil)

      let built = item(f, session: s)

      #expect(
        built?.source == shape.source(conversation: conversation),
        "\(built.map { "\($0.source): \($0.title)" } ?? "no item")")
    }

    /// sbd's `summary(_:)` builds the item, and the app's `inInbox` must give the same answer.
    @Test(arguments: operatorShapes, [false, true])
    func inInboxAgreesWithTheItemThatSbdBuilds(_ shape: OperatorShape, _ conversation: Bool) throws {
      let session = operatorSession(waits: shape.waits)
      let s = opSummary(session, opRouted(session, facts(try shape.events()), conversation: conversation ? "c1" : nil))
      let expected = shape.source(conversation: conversation) != nil

      #expect(Triage.inInbox(s) == expected)
      #expect(Triage.needsYou(s) == expected)
      #expect(Triage.order([s]).map(\.id) == (expected ? ["s1"] : []))
    }

    @Test func aQuestionLikeReplyLeavesTheOperatorWaitingWithNoItem() {
      let f = facts([opPrompt(1, "go"), stop(2, 2, proseQuestion)])
      let s = opSummary(operatorSession(), f)

      #expect(s.state == .waiting)
      #expect(s.triage == nil)
      #expect(!Triage.inInbox(s))
    }

    @Test func anSbSummarySetCardGivesTheOperatorNoItem() throws {
      let f = facts(opIdle + [try summaryEvent(9, 9, sessionCard)])
      try #require(f.sessionSummary != nil)
      let s = opSummary(operatorSession(), f)

      #expect(s.triage == nil)
      #expect(!Triage.inInbox(s))
    }

    /// Without a report, the operator matches a conversation on every shape that it shares with one, except an exit
    /// at the trust dialog. That exit gives the operator a `.rule` item (Decision 43) and a conversation none.
    @Test(arguments: inboxShapes) func withoutAReportTheOperatorMatchesAConversation(_ shape: InboxShape) throws {
      let f = facts(try shape.events())
      let trustExit = f.exitedAtTrust && !shape.done

      let s = opSummary(kindSession(.operator, done: shape.done), f)

      #expect((s.triage != nil) == (shape.conversation || trustExit))
      #expect(Triage.inInbox(s) == (shape.conversation || trustExit))
    }
  }
}

// MARK: The guard on a summary that an sbd sent

/// An operator's summary as sbd sends it, with an item that the app does not trust on its own.
struct ForgedShape: Sendable, CustomTestStringConvertible {
  var cards: [Card.Kind]
  var openPrompt: Bool
  var item: TriageSource?
  var included: Bool

  var testDescription: String {
    "cards \(cards.map(\.rawValue)), openPrompt \(openPrompt), item \(item?.rawValue ?? "none")"
  }
}

let forgedOperatorShapes = [
  ForgedShape(cards: [], openPrompt: false, item: nil, included: false),
  ForgedShape(cards: [], openPrompt: false, item: .summary, included: false),
  ForgedShape(cards: [], openPrompt: false, item: .session, included: false),
  ForgedShape(cards: [], openPrompt: false, item: .fallback, included: false),
  ForgedShape(cards: [], openPrompt: false, item: .card, included: false),
  ForgedShape(cards: [.send], openPrompt: false, item: .card, included: false),
  ForgedShape(cards: [.send], openPrompt: false, item: .summary, included: false),
  ForgedShape(cards: [.permission], openPrompt: true, item: nil, included: false),
  ForgedShape(cards: [], openPrompt: false, item: .report, included: true),
  ForgedShape(cards: [.send], openPrompt: false, item: .report, included: true),
  ForgedShape(cards: [.permission], openPrompt: true, item: .card, included: true),
  ForgedShape(cards: [.question], openPrompt: true, item: .card, included: true),
  ForgedShape(cards: [.trust], openPrompt: false, item: .card, included: true),
  ForgedShape(cards: [.send, .permission], openPrompt: true, item: .card, included: true),
  ForgedShape(cards: [], openPrompt: true, item: .rule, included: true),
]

extension TriageOperatorTests {
  @Suite struct Guard {
    func summary(_ kind: SessionKind, _ shape: ForgedShape) -> SessionSummary {
      var s = SessionSummary(
        id: "s1", name: "s1", cwd: "/", repo: nil, branch: nil, claudeSessionId: "s1", state: .needsYou, reason: "",
        since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
        cards: shape.cards.map(TriageConversations.card), openPrompt: shape.openPrompt)
      s.triage = shape.item.map { TriageItem(title: "t", kind: .question, summary: "", source: $0) }
      s.kind = kind
      s.manager = kind == .manager || kind == .operator ? true : nil
      s.chat = kind == .chat ? "g1" : nil
      return s
    }

    @Test(arguments: forgedOperatorShapes) func inInboxAdmitsOnlyTheOperatorsSources(_ shape: ForgedShape) {
      let s = summary(.operator, shape)

      #expect(Triage.inInbox(s) == shape.included)
      #expect(Triage.needsYou(s) == shape.included)
    }

    /// A report item comes from background follow-through, which routes it to a conversation too (#410).
    @Test(arguments: [SessionKind.manager, .chat], [[], [Card.Kind.send]] as [[Card.Kind]])
    func aConversationWithAReportItemIsInTheInbox(_ kind: SessionKind, _ cards: [Card.Kind]) {
      let s = summary(kind, ForgedShape(cards: cards, openPrompt: false, item: .report, included: true))

      #expect(Triage.inInbox(s))
    }
  }
}

// MARK: Conversation and chat parity

/// A shape that a conversation, a chat, or a work session can hold without reports.
struct ReportParityShape: CustomTestStringConvertible, Sendable {
  var name: String
  var events: @Sendable () throws -> [Event]
  var waits: [Wait] = []
  var testDescription: String { name }
}

let reportParityShapes: [ReportParityShape] = [
  ReportParityShape(name: "an informational reply", events: { opIdle }),
  ReportParityShape(name: "a question reply", events: { [opPrompt(1, "go"), stop(2, 2, proseQuestion)] }),
  ReportParityShape(name: "a permission card", events: { permissionTurn() }),
  ReportParityShape(name: "a question card", events: { questionTurn() }),
  ReportParityShape(name: "a send card", events: { opIdle + [sendPending()] }),
  ReportParityShape(name: "an sb summary set card", events: { opIdle + [try summaryEvent(9, 9, sessionCard)] }),
  ReportParityShape(name: "an overdue wait", events: { opIdle }, waits: [overdueWait]),
  ReportParityShape(name: "a notify outcome", events: { opIdle + [try opNotified(5)] }),
]

/// The report events that only the operator records, appended after the shape's own events.
let strayReports: [Event] = [
  opReport(100, "Merge it?"), opReport(101, "Removed it.", needsYou: false), opReport(102, "Remove kid?"),
]

extension TriageOperatorTests {
  @Suite struct Parity {
    @Test(arguments: [SessionKind.manager, .chat, .work], reportParityShapes)
    func reportEventsChangeNoOtherKindsVerdict(_ kind: SessionKind, _ shape: ReportParityShape) throws {
      let s = kindSession(kind, waits: shape.waits)
      let without = facts(try shape.events())
      let with = facts(try shape.events() + strayReports)

      #expect(opVerdict(s, with) == opVerdict(s, without))
    }

    @Test(arguments: [SessionKind.manager, .chat, .work], reportParityShapes)
    func reportEventsChangeNoOtherKindsItem(_ kind: SessionKind, _ shape: ReportParityShape) throws {
      let s = kindSession(kind, waits: shape.waits)
      let without = facts(try shape.events())
      let with = facts(try shape.events() + strayReports)

      #expect(item(with, session: s) == item(without, session: s))
    }

    /// Only the operator's ack closes reports, so stray reports and an ack must not mark another kind's verdict
    /// acknowledged. The prompt after the ack starts a turn, so most shapes give a verdict outside the Inbox.
    @Test(arguments: [SessionKind.manager, .chat, .work], reportParityShapes)
    func reportEventsAndAnAckChangeNoOtherKindsShownVerdict(_ kind: SessionKind, _ shape: ReportParityShape) throws {
      let s = kindSession(kind, waits: shape.waits)
      let after = [opAck(110), opPrompt(111, "go")]
      let without = facts(try shape.events() + after)
      let with = facts(try shape.events() + strayReports + after)

      let shownWithout = opShown(opVerdict(s, without), without, kind: kind)
      let shownWith = opShown(opVerdict(s, with), with, kind: kind)

      #expect(shownWith == shownWithout)
      // `Verdict ==` compares only the state and the reason.
      #expect(shownWith.acknowledged == shownWithout.acknowledged, "\(shownWith.state) \(shownWith.reason)")
    }

    /// Report events route nothing on their own, so a conversation's and a chat's item is still only its blocking
    /// prompt's item.
    @Test(arguments: [SessionKind.manager, .chat], reportParityShapes)
    func aConversationsItemIsStillOnlyItsPromptItem(_ kind: SessionKind, _ shape: ReportParityShape) throws {
      let s = kindSession(kind, waits: shape.waits)
      let f = facts(try shape.events() + strayReports)
      let verdict = opVerdict(s, f)

      #expect(Triage.itemAndDecisions(f, verdict, kind: kind).item == Triage.promptItem(f, verdict))
    }

    @Test(arguments: reportParityShapes)
    func aConversationAndAChatWithTheSameFactsGiveTheSameItem(_ shape: ReportParityShape) throws {
      let f = facts(try shape.events() + strayReports)
      let conversation = kindSession(.manager, waits: shape.waits)
      let chat = kindSession(.chat, waits: shape.waits)

      #expect(item(f, session: conversation) == item(f, session: chat))
      #expect(Triage.inInbox(opSummary(conversation, f)) == Triage.inInbox(opSummary(chat, f)))
    }
  }
}
