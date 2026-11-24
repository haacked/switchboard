import Foundation
import Testing

@testable import SwitchboardCore

/// The Operator's questions and held waits as items on the sessions that they are about (#410, Decisions 33 to 51).
/// sbd derives each owner's `facts.operatorItems` with `OperatorItems.assign`. These tests drive the derivation, the
/// fold that closes reports by owner, the verdicts, and the Inbox items. The suites nest under one name, so
/// `--filter OperatorItemsTests` runs them all.
@Suite struct OperatorItemsTests {}

// MARK: Builders

/// The time at which every builder below evaluates a session.
private let oiNow: Int64 = 1000

/// The Operator's id in `assign` calls.
private let op = "op"

/// An open needs-you report. The event is always valid, so the report always exists.
private func askReport(_ id: Int64, _ text: String = "Merge it?", about: String? = nil) -> OperatorReport {
  OperatorReport(opReport(id, text, about: about))!
}

/// An Operator wait on a session. `overdue` puts its recheck time before or after `oiNow`.
private func heldWait(
  _ id: String, action: WaitAction.Kind? = nil, watching target: String = "k1", subject: String? = nil,
  handedFrom: String? = nil, overdue: Bool = true, wanting wanted: AttentionState? = nil
) -> Wait {
  var w = Wait(
    id: id, kind: .session, session: Wait.SessionTarget(id: target, name: "kid"),
    state: wanted ?? (action == .merge ? .readyToMerge : .done), created: 0, recheck: overdue ? oiNow / 2 : oiNow * 10)
  w.action = action.map { WaitAction(kind: $0) }
  w.subject = subject.map { Wait.SessionTarget(id: $0, name: "subj") }
  w.handedFrom = handedFrom.map { Wait.SessionTarget(id: $0, name: "chat") }
  return w
}

/// A `merge` wait on a PR whose action acts on `subject`, which the wait does not watch.
private func prMergeWait(_ id: String, subject: String) -> Wait {
  var w = Wait(
    id: id, kind: .merge, pr: Wait.PullRequest(repository: "o/r", number: 7), created: 0, recheck: oiNow / 2)
  w.action = WaitAction(kind: .rmWorktree)
  w.subject = Wait.SessionTarget(id: subject, name: "subj")
  return w
}

private func assigned(
  _ reports: [OperatorReport], owners: [Int64: String] = [:], waits: [Wait] = [], live: Set<String>,
  conversation: String?
) -> [String: OperatorItems] {
  let alive = live.union([op])
  return OperatorItems.assign(
    openReports: reports, reportOwners: owners, waits: waits, operatorID: op, isLive: { alive.contains($0) },
    newestConversation: conversation)
}

/// The owners whose asks hold the report `id`.
private func owners(of id: Int64, in result: [String: OperatorItems]) -> [String] {
  result.filter { $0.value.asks.contains { $0.id == id } }.keys.sorted()
}

/// The owners whose held waits hold the wait `id`.
private func owners(ofWait id: String, in result: [String: OperatorItems]) -> [String] {
  result.filter { $0.value.heldWaits.contains { $0.id == id } }.keys.sorted()
}

/// The `report-routed` event that sbd records on the Operator right after the report.
func reportRouted(_ id: Int64, report: Int64, owner: String) -> Event {
  Event(
    id: id, session: "s1", t: id, kind: "report-routed",
    data: ["report": .number(Double(report)), "owner": .string(owner)])
}

/// The `report-closed` event that Acknowledge on an ask records on the Operator.
func reportClosed(_ id: Int64, _ reports: [Int64]) -> Event {
  Event(
    id: id, session: "s1", t: id, kind: "report-closed",
    data: ["reports": .array(reports.map { .number(Double($0)) })])
}

/// A `sent` event by `by`, with the optional `reports` and `handedFrom` keys.
func opSent(_ id: Int64, by: String, reports: [Int64]? = nil, handedFrom: String? = nil) -> Event {
  var data: [String: JSON] = ["text": "yes", "delivery": "pasted", "by": .string(by)]
  if let reports { data["reports"] = .array(reports.map { .number(Double($0)) }) }
  if let handedFrom { data["handedFrom"] = .string(handedFrom) }
  return Event(id: id, session: "s1", t: id, kind: "sent", data: .object(data))
}

private func withItems(_ f: SessionFacts, _ items: OperatorItems) -> SessionFacts {
  var f = f
  f.operatorItems = items
  return f
}

private func oiVerdict(_ s: Session, _ f: SessionFacts, now: Int64 = oiNow) -> Verdict {
  Attention.evaluate(s, f, now: now)
}

private func oiItem(_ s: Session, _ f: SessionFacts) -> TriageItem? {
  Triage.item(f, oiVerdict(s, f), kind: s.kind)
}

/// Every kind that can own an ask or a held wait.
private let everyOwnerKind: [SessionKind] = [.work, .manager, .chat, .operator]

// MARK: assign: asks (Decisions 35, 37, 51)

extension OperatorItemsTests {
  @Suite struct AssignAsks {
    @Test func aRoutedReportGoesToItsLiveOwner() {
      let result = assigned([askReport(10)], owners: [10: "k1"], live: ["k1", "c1"], conversation: "c1")

      #expect(owners(of: 10, in: result) == ["k1"])
    }

    /// Q8: the owner is pinned when the report is recorded, so a newer conversation does not take it.
    @Test func aRoutedReportStaysWithItsOwnerWhileANewerConversationIsLive() {
      let result = assigned([askReport(10)], owners: [10: "c1"], live: ["c1", "c2"], conversation: "c2")

      #expect(owners(of: 10, in: result) == ["c1"])
    }

    @Test func aRoutedReportStaysWithItsOwnerWhenAboutNamesAnotherLiveSession() {
      let result = assigned([askReport(10, about: "k2")], owners: [10: "k1"], live: ["k1", "k2"], conversation: nil)

      #expect(owners(of: 10, in: result) == ["k1"])
    }

    /// Decision 37: a removed owner falls back to the newest conversation, not to the report's `about`.
    @Test func aRoutedReportWhoseOwnerWasRemovedGoesToTheNewestConversation() {
      let result = assigned([askReport(10, about: "k2")], owners: [10: "k1"], live: ["k2", "c1"], conversation: "c1")

      #expect(owners(of: 10, in: result) == ["c1"])
    }

    @Test func aRoutedReportWhoseOwnerWasRemovedWithNoConversationStaysOnTheOperator() {
      let result = assigned([askReport(10)], owners: [10: "k1"], live: [], conversation: nil)

      #expect(owners(of: 10, in: result) == [op])
    }

    /// Decision 51: a report recorded before routing existed has no `reportOwners` entry.
    @Test func anUnroutedReportGoesToItsLiveAboutSession() {
      let result = assigned([askReport(10, about: "k1")], live: ["k1", "c1"], conversation: "c1")

      #expect(owners(of: 10, in: result) == ["k1"])
    }

    @Test func anUnroutedReportWhoseAboutWasRemovedGoesToTheNewestConversation() {
      let result = assigned([askReport(10, about: "k1")], live: ["c1"], conversation: "c1")

      #expect(owners(of: 10, in: result) == ["c1"])
    }

    @Test func anUnroutedReportWithoutAboutGoesToTheNewestConversation() {
      let result = assigned([askReport(10)], live: ["k1", "c1"], conversation: "c1")

      #expect(owners(of: 10, in: result) == ["c1"])
    }

    @Test func anUnroutedReportWithNoAboutAndNoConversationStaysOnTheOperator() {
      let result = assigned([askReport(10)], live: ["k1"], conversation: nil)

      #expect(owners(of: 10, in: result) == [op])
    }

    /// A report about the Operator itself never makes the Operator its owner while a conversation exists.
    @Test(arguments: [("c1", "c1"), (nil, op)] as [(String?, String)])
    func anUnroutedReportAboutTheOperatorGoesToTheConversationOrElseTheOperator(
      _ conversation: String?, _ owner: String
    ) {
      let result = assigned([askReport(10, about: op)], live: ["c1"], conversation: conversation)

      #expect(owners(of: 10, in: result) == [owner])
    }

    @Test func twoAsksOnOneOwnerKeepTheirOrder() {
      let result = assigned(
        [askReport(10, "a"), askReport(11, "b")], owners: [10: "k1", 11: "k1"], live: ["k1"], conversation: nil)

      #expect((result["k1"] ?? .init()).asks.map(\.id) == [10, 11])
    }

    @Test func twoOwnersEachGetOnlyTheirOwnAsk() {
      let result = assigned(
        [askReport(10, "a"), askReport(11, "b")], owners: [10: "k1", 11: "c1"], live: ["k1", "c1"], conversation: "c1")

      #expect((result["k1"] ?? .init()).asks.map(\.id) == [10])
      #expect((result["c1"] ?? .init()).asks.map(\.id) == [11])
    }

    @Test func noOpenReportsGiveNoAsks() {
      let result = assigned([], owners: [10: "k1"], live: ["k1", "c1"], conversation: "c1")

      #expect(result.values.allSatisfy { $0.asks.isEmpty })
    }

    /// Which sessions are live, and which conversation is the newest.
    struct Liveness: CustomTestStringConvertible, Sendable {
      var live: Set<String>
      var conversation: String?
      var testDescription: String { "live \(live.sorted()), conversation \(conversation ?? "none")" }
    }

    static let livenesses: [Liveness] = [
      Liveness(live: [], conversation: nil),
      Liveness(live: ["k1", "k2", "c1"], conversation: "c1"),
      Liveness(live: ["k1"], conversation: nil),
      Liveness(live: ["k2", "c2"], conversation: "c2"),
      Liveness(live: ["c1", "c2"], conversation: "c2"),
      Liveness(live: ["k1", "k2"], conversation: nil),
    ]

    /// Risk 7: whatever is live, each open report is on exactly one owner, and no report is dropped.
    @Test(arguments: livenesses)
    func everyOpenReportIsOnExactlyOneOwner(_ liveness: Liveness) {
      let reports = [
        askReport(10, about: "k1"), askReport(11), askReport(12, about: op), askReport(13, about: "k2"),
        askReport(14, about: "gone"), askReport(15),
      ]
      let routed: [Int64: String] = [10: "k1", 11: "c1", 15: "gone"]

      let result = assigned(reports, owners: routed, live: liveness.live, conversation: liveness.conversation)

      for report in reports { #expect(owners(of: report.id, in: result).count == 1, "report \(report.id)") }
      #expect(result.values.flatMap(\.asks).map(\.id).sorted() == reports.map(\.id).sorted())
    }
  }
}

// MARK: assign: held waits (Decisions 37, 38)

extension OperatorItemsTests {
  @Suite struct AssignWaits {
    @Test func anOverdueActionWaitGoesToItsLiveSubject() {
      let w = heldWait("w1", action: .merge, watching: "k1", handedFrom: "c1")

      let result = assigned([], waits: [w], live: ["k1", "c1", "c2"], conversation: "c2")

      #expect(owners(ofWait: "w1", in: result) == ["k1"])
    }

    /// `actionSubject` is the subject before the watched session.
    @Test func anActionWaitWithASubjectGoesToTheSubject() {
      let w = heldWait("w1", action: .rmWorktree, watching: "k1", subject: "k2")

      let result = assigned([], waits: [w], live: ["k1", "k2", "c1"], conversation: "c1")

      #expect(owners(ofWait: "w1", in: result) == ["k2"])
    }

    @Test func aPRMergeWaitGoesToItsSubject() {
      let result = assigned([], waits: [prMergeWait("w1", subject: "k2")], live: ["k2", "c1"], conversation: "c1")

      #expect(owners(ofWait: "w1", in: result) == ["k2"])
    }

    @Test func anActionWaitWhoseSubjectWasRemovedGoesToItsHandingConversation() {
      let w = heldWait("w1", action: .merge, watching: "k1", handedFrom: "c1")

      let result = assigned([], waits: [w], live: ["c1", "c2"], conversation: "c2")

      #expect(owners(ofWait: "w1", in: result) == ["c1"])
    }

    @Test func anActionWaitWithNeitherSubjectNorHandingConversationGoesToTheNewestConversation() {
      let w = heldWait("w1", action: .merge, watching: "k1", handedFrom: "c1")

      let result = assigned([], waits: [w], live: ["c2"], conversation: "c2")

      #expect(owners(ofWait: "w1", in: result) == ["c2"])
    }

    @Test func anActionWaitWithNothingLiveStaysOnTheOperator() {
      let w = heldWait("w1", action: .merge, watching: "k1", handedFrom: "c1")

      let result = assigned([], waits: [w], live: [], conversation: nil)

      #expect(owners(ofWait: "w1", in: result) == [op])
    }

    /// Only an action wait goes to the session that it acts on. A plain wait on a session only watches it.
    @Test func aWaitWithoutAnActionNeverGoesToTheSessionItWatches() {
      let w = heldWait("w1", watching: "k1")

      let result = assigned([], waits: [w], live: ["k1", "c1"], conversation: "c1")

      #expect(owners(ofWait: "w1", in: result) == ["c1"])
    }

    @Test func aWaitWithoutAnActionGoesToItsHandingConversation() {
      let w = heldWait("w1", watching: "k1", handedFrom: "c1")

      let result = assigned([], waits: [w], live: ["k1", "c1", "c2"], conversation: "c2")

      #expect(owners(ofWait: "w1", in: result) == ["c1"])
    }

    @Test func aWaitWithoutAnActionAndNoConversationStaysOnTheOperator() {
      let w = heldWait("w1", watching: "k1")

      let result = assigned([], waits: [w], live: ["k1"], conversation: nil)

      #expect(owners(ofWait: "w1", in: result) == [op])
    }

    /// `heldWaits` may hold a wait that is not overdue yet. Its owner shows no held verdict until it is.
    @Test func aWaitThatIsNotOverdueGivesItsOwnerNoHeldVerdict() {
      let w = heldWait("w1", action: .merge, watching: "k1", overdue: false)

      let result = assigned([], waits: [w], live: ["k1"], conversation: nil)

      #expect(Attention.heldWaitVerdict(result["k1"] ?? .init(), now: oiNow) == nil)
    }

    @Test(arguments: AssignAsks.livenesses)
    func everyOverdueWaitIsOnExactlyOneOwner(_ liveness: AssignAsks.Liveness) {
      let waits = [
        heldWait("w1", action: .merge, watching: "k1", handedFrom: "c1"),
        heldWait("w2", watching: "k2"),
        heldWait("w3", watching: "k1", handedFrom: "c2"),
        heldWait("w4", action: .rm, watching: "gone"),
        prMergeWait("w5", subject: "k2"),
      ]

      let result = assigned([], waits: waits, live: liveness.live, conversation: liveness.conversation)

      for w in waits { #expect(owners(ofWait: w.id, in: result).count == 1, "wait \(w.id)") }
    }
  }
}

// MARK: The fold (Decisions 36, 40)

extension OperatorItemsTests {
  @Suite struct Fold {
    @Test func reportRoutedSetsTheReportsOwner() {
      let f = facts(opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1")])

      #expect(f.reportOwners == [10: "k1"])
    }

    @Test func aRoutedReportStaysOpenOnTheOperator() {
      let f = facts(opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1")])

      #expect(f.openReports.map(\.id) == [10])
    }

    @Test func aSentByYouWithReportsClosesOnlyThoseReports() {
      let f = facts(
        opIdle + [opReport(10, "a"), opReport(11, "b"), opReport(12, "c"), opSent(13, by: "you", reports: [10, 12])])

      #expect(f.openReports.map(\.id) == [11])
    }

    /// `sb operator <text>` sends no `reports`, so it still closes every open report.
    @Test func aSentByYouWithoutReportsClosesEveryReport() {
      let f = facts(
        opIdle + [
          opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"), opSent(13, by: "you"),
        ])

      #expect(f.openReports.isEmpty)
    }

    @Test(arguments: ["claude", "sbd", "You", ""])
    func aSentNotByYouWithReportsClosesNothing(_ by: String) {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), opSent(12, by: by, reports: [10])])

      #expect(f.openReports.map(\.id) == [10, 11])
    }

    @Test func reportClosedClosesOnlyItsReports() {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), opReport(12, "c"), reportClosed(13, [11])])

      #expect(f.openReports.map(\.id) == [10, 12])
    }

    @Test func reportClosedForAReportThatIsNotOpenClosesNothing() {
      let f = facts(opIdle + [opReport(10, "a"), opReport(11, "b"), reportClosed(12, [99])])

      #expect(f.openReports.map(\.id) == [10, 11])
    }

    /// A report recorded after the close is a new question.
    @Test func reportClosedLeavesALaterReportOpen() {
      let f = facts(opIdle + [opReport(10, "a"), reportClosed(11, [10]), opReport(12, "b")])

      #expect(f.openReports.map(\.id) == [12])
    }

    @Test func aGenericAckLeavesRoutedReportsOpen() {
      let f = facts(
        opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"), opAck(13)])

      #expect(f.openReports.map(\.id) == [10])
    }

    @Test func aGenericAckAcknowledgesOnlyTheUnroutedReports() {
      let f = facts(
        opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"), opAck(13)])

      #expect(f.acknowledgedReports.map(\.id) == [12])
    }

    @Test func anUnackReopensNoRoutedReport() {
      let f = facts(
        opIdle + [
          opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"), opAck(13),
          reportClosed(14, [10]), opUnack(15),
        ])

      #expect(f.openReports.map(\.id) == [12])
    }

    @Test func anUnackAfterAnAckThatLeftARoutedReportOpenListsEachReportOnce() {
      let f = facts(
        opIdle + [
          opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"), opAck(13), opUnack(14),
        ])

      #expect(f.openReports.map(\.id).sorted() == [10, 12])
    }

    @Test func anAckDoesNotCloseReportsWhileEveryOpenReportIsRouted() {
      let f = facts(opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1")])

      #expect(!f.ackClosesReports)
    }

    @Test func anAckClosesReportsWhileAnUnroutedReportIsOpen() {
      let f = facts(opIdle + [opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b")])

      #expect(f.ackClosesReports)
    }

    /// A log written before routing existed, and the open reports that the fold gave it before.
    struct OldLog: CustomTestStringConvertible, Sendable {
      var name: String
      var events: @Sendable () -> [Event]
      var open: [Int64]
      var testDescription: String { name }
    }

    static let oldLogs: [OldLog] = [
      OldLog(name: "reports only", events: { opIdle + [opReport(10, "a"), opReport(11, "b")] }, open: [10, 11]),
      OldLog(
        name: "an ack between reports", events: { opIdle + [opReport(10, "a"), opAck(11), opReport(12, "b")] },
        open: [12]),
      OldLog(
        name: "the user's message closes everything",
        events: { opIdle + [opReport(10, "a"), opReport(11, "b"), opUserSent(12, "yes")] }, open: []),
      OldLog(
        name: "messages that the user did not write",
        events: {
          opIdle + [opReport(10, "a"), opSbdSent(11, "x"), opClaudeSent(12, "y"), opUnattributedSent(13, "z")]
        }, open: [10]),
      OldLog(
        name: "an ack and its unack",
        events: { opIdle + [opReport(10, "a"), opReport(11, "b"), opAck(12), opUnack(13)] },
        open: [10, 11]),
      OldLog(
        name: "an ack while a prompt blocks", events: { [opReport(0, "a", t: 0)] + permissionTurn() + [opAck(50)] },
        open: [0]),
    ]

    /// Decision 40: old logs have no `report-routed`, so a replay closes what it closed before.
    @Test(arguments: oldLogs) func anOldLogWithoutRoutingGivesTheSameOpenReports(_ log: OldLog) {
      #expect(facts(log.events()).openReports.map(\.id) == log.open)
    }

    /// A reply and an acknowledgment on the same owner close the same reports (Risk 7's paths that must agree).
    @Test(arguments: [opSent(20, by: "you", reports: [10]), reportClosed(20, [10])])
    func aReplyAndAnAckOnTheOwnerLeaveTheSameOpenReports(_ close: Event) {
      let f = facts(
        opIdle + [
          opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"),
          reportRouted(13, report: 12, owner: "c1"), close,
        ])

      #expect(f.openReports.map(\.id) == [12])
    }

    @Test(arguments: [opSent(20, by: "you", reports: [10]), reportClosed(20, [10])])
    func aReplyAndAnAckOnTheOwnerClearOnlyThatOwnersItem(_ close: Event) {
      let f = facts(
        opIdle + [
          opReport(10, "a"), reportRouted(11, report: 10, owner: "k1"), opReport(12, "b"),
          reportRouted(13, report: 12, owner: "c1"), close,
        ])

      let result = assigned(f.openReports, owners: f.reportOwners, live: ["k1", "c1"], conversation: "c1")

      #expect((result["k1"] ?? .init()).asks.isEmpty)
      #expect((result["c1"] ?? .init()).asks.map(\.id) == [12])
    }

    @Test(arguments: ["sbd", "you", "claude"])
    func aSentWithHandedFromSetsWorkFrom(_ by: String) {
      let f = facts(opIdle + [opSent(10, by: by, handedFrom: "c1")])

      #expect(f.workFrom == "c1")
    }

    /// A schedule prompt or the user's message carries no `handedFrom`, so it clears the wait's conversation.
    @Test(arguments: ["sbd", "you", "claude"])
    func aLaterSentWithoutHandedFromClearsWorkFrom(_ by: String) {
      let f = facts(opIdle + [opSent(10, by: "sbd", handedFrom: "c1"), opSent(11, by: by)])

      #expect(f.workFrom == nil)
    }

    @Test func aLaterSentWithAnotherHandedFromReplacesWorkFrom() {
      let f = facts(opIdle + [opSent(10, by: "sbd", handedFrom: "c1"), opSent(11, by: "sbd", handedFrom: "c2")])

      #expect(f.workFrom == "c2")
    }

    @Test func noSentLeavesWorkFromEmpty() {
      #expect(facts(opIdle).workFrom == nil)
    }
  }
}

// MARK: Coding

extension OperatorItemsTests {
  @Suite struct Coding {
    /// sbd derives `operatorItems` and never folds it, so facts decoded without the key get the empty default.
    @Test func factsDecodedWithoutOperatorItemsHaveNone() throws {
      var object = try #require(try JSON(encoding: SessionFacts()).object)
      object["operatorItems"] = nil

      let decoded = try JSONCoding.decode(SessionFacts.self, from: try JSONCoding.encode(JSON.object(object)))

      #expect(decoded.operatorItems == OperatorItems())
    }

    @Test func operatorItemsRoundTrip() throws {
      let items = OperatorItems(
        asks: [askReport(10, about: "k1")], heldWaits: [heldWait("w1", action: .merge)])

      #expect(try JSONCoding.decode(OperatorItems.self, from: try JSONCoding.encode(items)) == items)
    }
  }
}

// MARK: The verdicts (Attention.askVerdict, Attention.heldWaitVerdict)

extension OperatorItemsTests {
  @Suite struct AskVerdict {
    @Test func noAsksGiveNoVerdict() {
      #expect(Attention.askVerdict(OperatorItems()) == nil)
    }

    @Test func heldWaitsAloneGiveNoAskVerdict() {
      #expect(Attention.askVerdict(OperatorItems(heldWaits: [heldWait("w1")])) == nil)
    }

    @Test func anAskGivesNeedsYouWithTheOperatorsText() {
      let v = Attention.askVerdict(OperatorItems(asks: [askReport(10, "Merge it?")]))

      #expect(v == Verdict(state: .needsYou, reason: "Operator: Merge it?"))
    }

    @Test(arguments: [(2, "Operator: b (and 1 more)"), (3, "Operator: c (and 2 more)")] as [(Int, String)])
    func severalAsksGiveTheLatestTextAndTheCountOfTheRest(_ count: Int, _ reason: String) {
      let asks = ["a", "b", "c"].prefix(count).enumerated().map { askReport(Int64(10 + $0.offset), $0.element) }

      #expect(Attention.askVerdict(OperatorItems(asks: asks))?.reason == reason)
    }

    @Test func anAskIsAQuestion() {
      #expect(Attention.askVerdict(OperatorItems(asks: [askReport(10)]))?.kind == .question)
    }

    @Test func anAskVerdictComesFromTheOperator() {
      #expect(Attention.askVerdict(OperatorItems(asks: [askReport(10)]))?.fromOperator == true)
    }
  }

  @Suite struct HeldWaitVerdict {
    @Test func noHeldWaitsGiveNoVerdict() {
      #expect(Attention.heldWaitVerdict(OperatorItems(), now: oiNow) == nil)
    }

    @Test func aHeldWaitThatIsNotOverdueGivesNoVerdict() {
      let items = OperatorItems(heldWaits: [heldWait("w1", action: .merge, overdue: false)])

      #expect(Attention.heldWaitVerdict(items, now: oiNow) == nil)
    }

    @Test(arguments: [WaitAction.Kind.merge, .rmWorktree, .rm])
    func anOverdueActionWaitSaysWhatSbdStillWaitsToDo(_ action: WaitAction.Kind) {
      let w = heldWait("w1", action: action)

      let v = Attention.heldWaitVerdict(OperatorItems(heldWaits: [w]), now: oiNow)

      #expect(v == Verdict(state: .needsYou, reason: "sbd still waits to \(action.skipped): \(w.overdueLine)"))
    }

    @Test func anOverdueWaitWithoutAnActionSaysBackgroundFollowThroughStillWaits() {
      let w = heldWait("w1")

      let v = Attention.heldWaitVerdict(OperatorItems(heldWaits: [w]), now: oiNow)

      #expect(v == Verdict(state: .needsYou, reason: "Background follow-through still waits: \(w.overdueLine)"))
    }

    @Test func theVerdictNamesOnlyTheOverdueWaits() {
      let items = OperatorItems(
        heldWaits: [heldWait("w1"), heldWait("w2", overdue: false), heldWait("w3", action: .merge)])

      #expect(Attention.heldWaitVerdict(items, now: oiNow)?.overdueWaits == ["w1", "w3"])
    }

    @Test func aHeldWaitVerdictComesFromTheOperator() {
      let items = OperatorItems(heldWaits: [heldWait("w1")])

      #expect(Attention.heldWaitVerdict(items, now: oiNow)?.fromOperator == true)
    }
  }
}

// MARK: The Operator's own verdict (Attention.operatorRules, Decision 43)

/// What the Operator holds, and the state that its verdict must have.
struct OperatorVerdictShape: CustomTestStringConvertible, Sendable {
  var name: String
  var events: @Sendable () throws -> [Event]
  var waits: [Wait] = []
  var items = OperatorItems()
  var now: Int64 = 1000
  var state: AttentionState
  var testDescription: String { name }
}

let operatorVerdictShapes: [OperatorVerdictShape] = [
  OperatorVerdictShape(name: "a new operator that never had a prompt", events: { [] }, state: .waiting),
  OperatorVerdictShape(name: "an idle operator", events: { opIdle }, state: .waiting),
  OperatorVerdictShape(
    name: "a reply that reads as a question", events: { [opPrompt(1, "go"), stop(2, 2, proseQuestion)] },
    state: .waiting),
  OperatorVerdictShape(
    name: "a reply that offers a next step",
    events: { [opPrompt(1, "go"), stop(2, 2, "I removed the worktree. Want me to top up the queue?")] },
    state: .waiting),
  OperatorVerdictShape(name: "a send card", events: { opIdle + [sendPending()] }, state: .waiting),
  OperatorVerdictShape(
    name: "an idle operator days later", events: { opIdle }, now: 3 * Attention.staleAfterMs, state: .waiting),
  OperatorVerdictShape(
    name: "an sb summary set card", events: { opIdle + [try summaryEvent(9, 9, sessionCard)] }, state: .waiting),
  OperatorVerdictShape(name: "a running turn", events: { [opPrompt(1, "go")] }, state: .working),
  OperatorVerdictShape(
    name: "an open report that sbd routed to another session", events: { opIdle + [opReport(10, "Merge it?")] },
    state: .waiting),
  OperatorVerdictShape(
    name: "an overdue wait that sbd routed to another session", events: { opIdle }, waits: [overdueWait],
    state: .waiting),
  OperatorVerdictShape(
    name: "an open wait that is not overdue", events: { opIdle }, waits: [openWait], state: .waiting),
  OperatorVerdictShape(name: "a blocking permission card", events: { permissionTurn() }, state: .needsYou),
  OperatorVerdictShape(name: "a blocking question card", events: { questionTurn() }, state: .needsYou),
  OperatorVerdictShape(
    name: "a permission dialog without a card",
    events: {
      [
        opPrompt(1, "go"),
        Event(
          id: 2, session: "s1", t: 2, kind: "Notification",
          data: ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
      ]
    }, state: .needsYou),
  OperatorVerdictShape(
    name: "an exit at the trust dialog", events: { trustLaunch() + [trustClosed(5)] }, state: .needsYou),
  OperatorVerdictShape(name: "a notify outcome", events: { opIdle + [try opNotified(5)] }, state: .needsYou),
  OperatorVerdictShape(
    name: "an ask with no owner", events: { opIdle + [opReport(10, "Merge it?")] },
    items: OperatorItems(asks: [OperatorReport(opReport(10, "Merge it?"))!]), state: .needsYou),
  OperatorVerdictShape(
    name: "an ask with no owner while a turn runs",
    events: { opIdle + [opReport(10, "Merge it?"), opPrompt(11, "go")] },
    items: OperatorItems(asks: [OperatorReport(opReport(10, "Merge it?"))!]), state: .needsYou),
  OperatorVerdictShape(
    name: "an overdue wait with no owner", events: { opIdle }, waits: [overdueWait],
    items: OperatorItems(heldWaits: [overdueWait]), state: .needsYou),
  OperatorVerdictShape(
    name: "an overdue wait with no owner while a turn runs", events: { [opPrompt(1, "go")] }, waits: [overdueWait],
    items: OperatorItems(heldWaits: [overdueWait]), state: .working),
]

extension OperatorItemsTests {
  @Suite struct OperatorVerdict {
    func verdict(_ shape: OperatorVerdictShape) throws -> Verdict {
      let f = withItems(facts(try shape.events()), shape.items)
      return Attention.evaluate(operatorSession(waits: shape.waits), f, now: shape.now)
    }

    @Test(arguments: operatorVerdictShapes) func theOperatorsStateComesFromTheShape(_ shape: OperatorVerdictShape)
      throws
    {
      let v = try verdict(shape)

      #expect(v.state == shape.state, "\(v.reason)")
    }

    @Test(
      arguments: [
        ("new", [] as [Event]), ("idle", opIdle), ("question reply", [opPrompt(1, "go"), stop(2, 2, proseQuestion)]),
      ] as [(String, [Event])])
    func anOperatorWithoutWaitsWaitsIdle(_ name: String, _ events: [Event]) {
      let v = Attention.evaluate(operatorSession(), facts(events), now: oiNow)

      #expect(v == Verdict(state: .waiting, reason: "idle"), "\(name)")
    }

    @Test(arguments: [overdueWait, openWait])
    func anOperatorWithAWaitThatSbdRoutedAwayWaitsWithItsWaitLine(_ wait: Wait) {
      let v = Attention.evaluate(operatorSession(waits: [wait]), facts(opIdle), now: oiNow)

      #expect(v.state == .waiting)
      #expect(v.reason.contains(wait.summary), "\(v.reason)")
    }

    @Test func anAskWithNoOwnerGivesTheAskVerdict() {
      let items = OperatorItems(asks: [askReport(10, "Merge it?")])

      let v = Attention.evaluate(operatorSession(), withItems(facts(opIdle), items), now: oiNow)

      #expect(v == Verdict(state: .needsYou, reason: "Operator: Merge it?"))
      #expect(v.fromOperator)
    }

    @Test func anOverdueWaitWithNoOwnerGivesTheHeldVerdict() {
      let items = OperatorItems(heldWaits: [overdueWait])

      let v = Attention.evaluate(operatorSession(waits: [overdueWait]), withItems(facts(opIdle), items), now: oiNow)

      #expect(v.fromOperator)
      #expect(v.overdueWaits == [overdueWait.id])
    }

    @Test func aNotifyOutcomeComesBeforeAHeldWait() throws {
      let items = OperatorItems(heldWaits: [overdueWait])

      let v = Attention.evaluate(
        operatorSession(waits: [overdueWait]), withItems(facts(opIdle + [try opNotified(5)]), items), now: oiNow)

      #expect(v.byWaitRule)
      #expect(!v.fromOperator)
    }

    @Test func aBlockingCardComesBeforeAnAsk() {
      let items = OperatorItems(asks: [askReport(10)])

      let v = Attention.evaluate(operatorSession(), withItems(facts(permissionTurn()), items), now: oiNow)

      #expect(v.state == .needsYou)
      #expect(!v.fromOperator)
    }

    @Test func anOpenReportThatSbdRoutedAwayIsNotNeedsYou() {
      let v = Attention.evaluate(operatorSession(), facts(opIdle + [opReport(10, "Merge it?")]), now: oiNow)

      #expect(v.state != .needsYou, "\(v.reason)")
    }

    @Test func aMarkedDoneOperatorIsDone() {
      var s = operatorSession()
      s.done = true

      #expect(
        Attention.evaluate(s, withItems(facts(opIdle), OperatorItems(asks: [askReport(10)])), now: oiNow).state == .done
      )
    }
  }
}

// MARK: The items (Triage.operatorSourcedItem)

extension OperatorItemsTests {
  @Suite struct Items {
    @Test(arguments: everyOwnerKind) func anAskGivesAReportItem(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(asks: [askReport(10)]))

      #expect(try #require(oiItem(kindSession(kind), f)).source == .report)
    }

    @Test(arguments: everyOwnerKind) func anAsksRefNamesTheLatestReport(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(asks: [askReport(10, "a"), askReport(11, "b")]))

      #expect(try #require(oiItem(kindSession(kind), f)).ref == "report:11")
    }

    @Test(arguments: everyOwnerKind) func anAskOffersOnlyAReply(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(asks: [askReport(10)]))

      #expect(try #require(oiItem(kindSession(kind), f)).options.map(\.action) == [.reply])
    }

    @Test(arguments: everyOwnerKind) func aHeldWaitGivesAReportItem(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1", action: .merge)]))

      #expect(try #require(oiItem(kindSession(kind), f)).source == .report)
    }

    @Test(arguments: everyOwnerKind) func aHeldWaitsRefNamesItsWait(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1", action: .merge)]))

      #expect(try #require(oiItem(kindSession(kind), f)).ref == "held:w1")
    }

    @Test func severalHeldWaitsAreAllNamedInTheRef() throws {
      let f = withItems(
        facts(opIdle), OperatorItems(heldWaits: [heldWait("w1"), heldWait("w2", action: .rm)]))

      let ref = try #require(oiItem(kindSession(.work), f)).ref

      #expect(ref.hasPrefix("held:"))
      #expect(ref.contains("w1") && ref.contains("w2"), "\(ref)")
    }

    @Test(arguments: everyOwnerKind) func aHeldWaitOffersNoOptions(_ kind: SessionKind) throws {
      let f = withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1", action: .merge)]))

      #expect(try #require(oiItem(kindSession(kind), f)).options.isEmpty)
    }

    @Test(arguments: everyOwnerKind) func aHeldWaitsDetailsNameTheOverdueWaits(_ kind: SessionKind) throws {
      let items = OperatorItems(heldWaits: [heldWait("w1"), heldWait("w2", overdue: false)])

      #expect(try #require(oiItem(kindSession(kind), withItems(facts(opIdle), items))).details.overdueWaits == ["w1"])
    }

    @Test(arguments: everyOwnerKind) func aBlockingCardAboveAnAskIsTheItem(_ kind: SessionKind) throws {
      let f = withItems(facts(permissionTurn()), OperatorItems(asks: [askReport(10)]))

      #expect(try #require(oiItem(kindSession(kind), f)).source == .card)
    }

    /// The app's `inInbox` must admit the item that sbd builds (Risk 2's parity, for every owner kind).
    @Test(arguments: everyOwnerKind, [false, true])
    func inInboxAdmitsTheItemThatSbdBuilds(_ kind: SessionKind, _ held: Bool) {
      let items =
        held ? OperatorItems(heldWaits: [heldWait("w1")]) : OperatorItems(asks: [askReport(10)])

      let s = opSummary(kindSession(kind), withItems(facts(opIdle), items))

      #expect(s.triage?.source == .report)
      #expect(Triage.inInbox(s))
      #expect(Triage.needsYou(s))
    }

    /// Risk 7: a conversation's send card does not block, so the Inbox would show nothing for it. The ask must still
    /// reach the Inbox.
    @Test(arguments: [SessionKind.manager, .chat]) func anAskBehindAConversationsSendCardStillReachesTheInbox(
      _ kind: SessionKind
    ) {
      let s = opSummary(
        kindSession(kind), withItems(facts(opIdle + [sendPending()]), OperatorItems(asks: [askReport(10)])))

      #expect(Triage.inInbox(s), "\(s.triage.map { "\($0.source): \($0.title)" } ?? "no item")")
    }
  }
}

// MARK: Ask items carry nothing of the owner's own content (Decision 50)

extension OperatorItemsTests {
  @Suite struct OwnContent {
    /// A work session whose turn ended with a question, then opened a decision list.
    func ownerFacts() -> SessionFacts {
      facts([opPrompt(1, "go"), stop(2, 2, proseQuestion), decisionsOpened(3, t: 3, ref: "stop:2")])
    }

    @Test func theOwnersDecisionListIsOpenWithoutAnAsk() throws {
      let f = ownerFacts()
      try #require(f.decisionList != nil)

      #expect(Triage.itemAndDecisions(f, oiVerdict(session(), f), kind: .work).decisions != nil)
    }

    @Test func anAskItemCarriesNoDecisions() throws {
      let f = withItems(ownerFacts(), OperatorItems(asks: [askReport(10)]))

      #expect(try #require(oiItem(session(), f)).decisions.isEmpty)
    }

    @Test func anAskGivesNoDecisionList() {
      let f = withItems(ownerFacts(), OperatorItems(asks: [askReport(10)]))

      let built = Triage.itemAndDecisions(f, oiVerdict(session(), f), kind: .work)

      #expect(built.decisions == nil)
      #expect(!built.decisionsSent)
    }

    @Test func anAskItemCarriesNoQuestionFromTheOwnersReply() throws {
      let f = withItems(ownerFacts(), OperatorItems(asks: [askReport(10)]))

      let built = try #require(oiItem(session(), f))

      #expect(!built.callouts.contains { $0.title.hasPrefix(Triage.replyAskPrefix) }, "\(built.callouts)")
      #expect(built.ref == "report:10")
    }

    @Test func anAskItemCarriesNoDrafts() throws {
      let f = withItems(ownerFacts(), OperatorItems(asks: [askReport(10)]))

      #expect(try #require(oiItem(session(), f)).drafts.isEmpty)
    }

    @Test func aHeldWaitItemCarriesNoDecisionsOrQuestion() throws {
      let f = withItems(ownerFacts(), OperatorItems(heldWaits: [heldWait("w1")]))

      let built = try #require(oiItem(session(), f))

      #expect(built.decisions.isEmpty)
      #expect(!built.callouts.contains { $0.title.hasPrefix(Triage.replyAskPrefix) }, "\(built.callouts)")
    }
  }
}

// MARK: The Operator's own items (Decision 43)

extension OperatorItemsTests {
  @Suite struct OperatorOwnItems {
    @Test func aNotifyOutcomeGivesTheOperatorARuleItem() throws {
      let f = facts(opIdle + [try opNotified(5)])

      #expect(try #require(oiItem(operatorSession(), f)).source == .rule)
    }

    @Test func anExitAtTheTrustDialogGivesTheOperatorARuleItem() throws {
      let f = facts(trustLaunch() + [trustClosed(5)])

      #expect(try #require(oiItem(operatorSession(), f)).source == .rule)
    }

    @Test(arguments: [false, true]) func theOperatorsRuleItemReachesTheInbox(_ trustExit: Bool) throws {
      let events = trustExit ? trustLaunch() + [trustClosed(5)] : opIdle + [try opNotified(5)]

      let s = opSummary(operatorSession(), facts(events))

      #expect(Triage.inInbox(s))
      #expect(Triage.needsYou(s))
    }

    @Test func aBlockingCardGivesTheOperatorACardItem() throws {
      #expect(try #require(oiItem(operatorSession(), facts(permissionTurn()))).source == .card)
    }

    @Test func anOpenReportThatSbdRoutedAwayGivesTheOperatorNoItem() {
      #expect(oiItem(operatorSession(), facts(opIdle + [opReport(10, "Merge it?")])) == nil)
    }

    @Test func anOverdueWaitThatSbdRoutedAwayGivesTheOperatorNoItem() {
      #expect(oiItem(operatorSession(waits: [overdueWait]), facts(opIdle)) == nil)
    }

    @Test func theOperatorIsNamedBackgroundFollowThroughInTheInbox() {
      let s = opSummary(operatorSession(), facts(opIdle))

      #expect(Triage.inboxName(s, groupName: nil) == "Background follow-through")
    }
  }
}

// MARK: Where the routed verdicts sit (Decision 39, Risk B)

extension OperatorItemsTests {
  @Suite struct Order {
    /// The time of the PR builders' facts, and a wait that is overdue by then.
    static let prNow: Int64 = 10
    static let heldAtPRNow = Wait(
      id: "w1", kind: .session, session: Wait.SessionTarget(id: "k1", name: "kid"), state: .done, created: 0,
      recheck: 5)

    func prVerdict(_ f: SessionFacts, _ s: Session = session()) -> Verdict {
      Attention.evaluate(s, f, now: Self.prNow)
    }

    /// Decision 52: an open ask on S takes S out of Ready to merge until the ask closes.
    @Test func anAskComesBeforeReadyToMerge() throws {
      let f = try prFacts(readyPR())
      try #require(prVerdict(f).state == .readyToMerge)

      let v = prVerdict(withItems(f, OperatorItems(asks: [askReport(10)])))

      #expect(v.state == .needsYou)
      #expect(v.fromOperator)
    }

    /// A merge wait watches for Ready to merge, so a routed held wait must never hide it.
    @Test func aHeldWaitLeavesReadyToMerge() throws {
      let f = try prFacts(readyPR())

      let v = prVerdict(withItems(f, OperatorItems(heldWaits: [Self.heldAtPRNow])))

      #expect(v.state == .readyToMerge, "\(v.reason)")
    }

    /// An rm-worktree wait watches for Done, so a routed held wait must never hide it.
    @Test func aHeldWaitLeavesDone() throws {
      let f = try prFacts(samplePR(state: .merged), dirty: 0)
      try #require(prVerdict(f).state == .done)

      let v = prVerdict(withItems(f, OperatorItems(heldWaits: [Self.heldAtPRNow])))

      #expect(v.state == .done, "\(v.reason)")
    }

    /// A `session` wait settles on Stale, so a routed held wait must never hide it.
    @Test func aHeldWaitLeavesStale() {
      let f = facts(opIdle)
      let now = 3 * Attention.staleAfterMs
      #expect(oiVerdict(session(), f, now: now).state == .stale)

      let v = oiVerdict(session(), withItems(f, OperatorItems(heldWaits: [heldWait("w1")])), now: now)

      #expect(v.state == .stale, "\(v.reason)")
    }

    /// An Operator-held `session` wait that wants Waiting would never settle if its verdict hid Waiting.
    @Test func aHeldWaitLeavesTheStateThatAWaitOnThisSessionWants() {
      let job = facts(opIdle + [event("job", 2, ["count": 1])])
      #expect(oiVerdict(session(), job).state == .waiting)

      let v = oiVerdict(
        session(), withItems(job, OperatorItems(heldWaits: [heldWait("w1", watching: "s1", wanting: .waiting)])))

      #expect(v.state == .waiting, "\(v.reason)")
    }

    @Test func aHeldWaitStillWinsOverAStateThatNoWaitOnThisSessionWants() {
      let job = facts(opIdle + [event("job", 2, ["count": 1])])
      let waits = [
        heldWait("w1", watching: "s1", wanting: .needsYou), heldWait("w2", watching: "k1", wanting: .waiting),
      ]

      let v = oiVerdict(session(), withItems(job, OperatorItems(heldWaits: waits)))

      #expect(v.state == .needsYou, "\(v.reason)")
      #expect(v.fromOperator)
    }

    @Test func aHeldWaitLeavesAMarkedDoneSessionDone() {
      let v = oiVerdict(
        session(done: true), withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1")])))

      #expect(v.state == .done)
    }

    @Test func aHeldWaitLeavesARunningTurnWorking() {
      let f = withItems(facts([opPrompt(1, "go")]), OperatorItems(heldWaits: [heldWait("w1")]))

      #expect(oiVerdict(session(), f).state == .working)
    }

    @Test func anAskComesBeforeARunningTurn() {
      let f = withItems(facts([opPrompt(1, "go")]), OperatorItems(asks: [askReport(10)]))

      #expect(oiVerdict(session(), f).fromOperator)
    }

    @Test func aBlockingCardComesBeforeAnAsk() {
      let v = oiVerdict(session(), withItems(facts(permissionTurn()), OperatorItems(asks: [askReport(10)])))

      #expect(v.state == .needsYou)
      #expect(!v.fromOperator)
    }

    @Test func anOpenDialogComesBeforeAnAsk() {
      let dialog = [
        opPrompt(1, "go"),
        Event(
          id: 2, session: "s1", t: 2, kind: "Notification",
          data: ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
      ]
      let f = withItems(facts(dialog), OperatorItems(asks: [askReport(10)]))

      #expect(oiVerdict(session(), f) == Attention.openPromptVerdict(f))
    }

    @Test func aHeldWaitComesBeforeTheOwnersOwnOverdueWait() {
      var s = session()
      s.waits = [Wait(id: "own", kind: .manual, note: "own", created: 0, then: .notify, recheck: oiNow / 2)]
      let f = withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1")]))

      let v = oiVerdict(s, f)

      #expect(v.fromOperator)
      #expect(v.overdueWaits == ["w1"])
    }

    @Test func aHeldWaitComesBeforeTheOwnersOpenWait() {
      var s = session()
      s.waits = [Wait(id: "own", kind: .manual, note: "own", created: 0, then: .notify, recheck: oiNow * 10)]
      let f = withItems(facts(opIdle), OperatorItems(heldWaits: [heldWait("w1")]))

      let v = oiVerdict(s, f)

      #expect(v.state == .needsYou)
      #expect(v.fromOperator)
    }

    /// Risk B: a held wait that is not overdue changes no verdict and no item, on any kind.
    @Test(arguments: [SessionKind.work, .manager, .chat], reportParityShapes)
    func aHeldWaitThatIsNotOverdueChangesNothing(_ kind: SessionKind, _ shape: ReportParityShape) throws {
      let s = kindSession(kind, waits: shape.waits)
      let without = facts(try shape.events())
      let with = withItems(without, OperatorItems(heldWaits: [heldWait("w9", overdue: false)]))

      #expect(oiVerdict(s, with) == oiVerdict(s, without))
      #expect(oiItem(s, with) == oiItem(s, without))
    }
  }
}

// MARK: One report, one item (Risk 7)

extension OperatorItemsTests {
  @Suite struct OneItemPerReport {
    /// The owners in a world with the Operator, a work session, a conversation, and a group chat.
    static let kinds: [String: SessionKind] = [op: .operator, "k1": .work, "c1": .manager, "g1": .chat]

    @Test func eachOpenReportShowsOnExactlyOneOwnersInboxItem() throws {
      let reports = [
        askReport(10, about: "k1"), askReport(11), askReport(12, about: op), askReport(13, about: "gone"),
        askReport(14, about: "g1"),
      ]
      let result = assigned(
        reports, owners: [10: "k1", 11: "c1", 14: "g1"], live: ["k1", "c1", "g1"], conversation: "c1")

      for report in reports { #expect(owners(of: report.id, in: result).count == 1, "report \(report.id)") }
      for (owner, items) in result where !items.asks.isEmpty {
        let kind = try #require(Self.kinds[owner], "\(owner)")
        let s = opSummary(kindSession(kind), withItems(facts(opIdle), items))
        #expect(s.triage?.source == .report, "\(owner)")
        #expect(s.triage?.ref == "report:\(items.asks.last!.id)", "\(owner)")
        #expect(Triage.inInbox(s), "\(owner)")
      }
    }

    @Test func anOwnerWithoutAnAskHasNoReportItem() {
      let result = assigned([askReport(10)], owners: [10: "k1"], live: ["k1", "c1"], conversation: "c1")

      let s = opSummary(kindSession(.manager), withItems(facts(opIdle), result["c1"] ?? .init()))

      #expect(s.triage?.source != .report)
    }
  }
}
