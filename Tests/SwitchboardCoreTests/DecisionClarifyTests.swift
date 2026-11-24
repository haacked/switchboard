import Foundation
import Testing

@testable import SwitchboardCore

// The clarifying turn: the turn that a question about one decision starts.
// These tests apply events to `SessionFacts` and run `Attention.track` after
// each one, as sbd does, so `stateSince` moves only when the state changes.

/// The ref of the item whose decisions the list holds: the card that
/// `decisionTurn` writes as event 3.
private let listRef = "summary:3"
private let askNumber = 2
private let askText = "Why not call it task?"
private let askMessage = DecisionAsk.message(
  about: PendingDecision(number: askNumber, header: "Name", question: "", options: []), askText)

/// The verdict that `decision_asked` saves: what sbd showed when the user asked.
private struct SavedVerdict: Equatable, CustomStringConvertible {
  var state: AttentionState
  var reason: String
  var since: Int64

  var description: String { "\(state.rawValue) \"\(reason)\" since \(since)" }
}

/// The two Inbox states that a decision list opens from.
enum ClarifyStart: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// A reply that ends with a question.
  case needsYou
  /// A prose reply that ends with an offer.
  case canContinue

  var testDescription: String { rawValue }

  var state: AttentionState { self == .needsYou ? .needsYou : .canContinue }

  var reply: String {
    switch self {
    case .needsYou: "I planned the storage. Which of the three decisions should I take up first?"
    case .canContinue: "I planned the storage and listed three decisions. Want me to start once you decide?"
    }
  }

  /// A clarifying answer whose own verdict differs from the start's, so that
  /// a missing hold shows in the state and the reason.
  var clarifyingReply: String {
    switch self {
    case .needsYou: "A log line is noisy at this volume. Want me to show the numbers?"
    case .canContinue: "A log line is noisy at this volume. Which volume do you expect?"
    }
  }
}

/// Applies each event and tracks the verdict at the event's time, as sbd does.
@discardableResult
private func track(_ f: inout SessionFacts, _ events: [Event], session s: Session = session()) -> Verdict {
  var verdict: Verdict?
  for e in events {
    f.apply(e)
    verdict = Attention.track(s, &f, now: e.t)
  }
  return verdict ?? Attention.evaluate(s, f, now: f.lastActivity)
}

/// The facts of a turn that ended at `start`, whose card holds three
/// decisions, with the list opened at the first answer.
private func openList(_ start: ClarifyStart, card: JSON = decisionSummaryJSON) throws -> SessionFacts {
  var f = SessionFacts()
  let v = track(
    &f,
    [
      Event(id: 1, session: "s1", t: 0, kind: "UserPromptSubmit", data: ["prompt": "plan it"]),
      stop(2, 10, start.reply),
      Event(id: 3, session: "s1", t: 20, kind: Triage.sessionEvent, data: card),
      decisionsOpened(4, ref: listRef),
    ])
  try #require(v.state == start.state, "the start reads \(v.state) \(v.reason)")
  try #require(f.decisionList?.ref == listRef)
  try #require(f.stateSince > 0, "the start never moved stateSince")
  return f
}

/// The tracked verdict at `now`, in the form that `decision_asked` saves it.
private func current(_ f: SessionFacts, now: Int64) throws -> SavedVerdict {
  let v = Attention.evaluate(session(), f, now: now)
  return SavedVerdict(state: try #require(f.lastState), reason: v.reason, since: f.stateSince)
}

private func decisionAsked(
  _ id: Int64, t: Int64, ref: String = listRef, askId: String = "ask-1", number: Int = askNumber,
  text: String = askText, message: String = askMessage, verdict: SavedVerdict, item: TriageItem
) throws -> Event {
  Event(
    id: id, session: "s1", t: t, kind: "decision_asked",
    data: [
      "ref": .string(ref), "number": .number(Double(number)), "askId": .string(askId), "text": .string(text),
      "message": .string(message),
      "verdict": ["state": .string(verdict.state.rawValue), "reason": .string(verdict.reason)],
      "item": try JSON(encoding: item),
    ])
}

/// The `sent` that sbd records for the question, by sbd and for a decision.
private func sentQuestion(_ id: Int64, t: Int64, message: String = askMessage) -> Event {
  Event(
    id: id, session: "s1", t: t, kind: "sent",
    data: [
      "text": .string(message), "by": "sbd", "trigger": "decision", "delivery": .string(Delivery.pasted.rawValue),
    ])
}

private func pasting(_ id: Int64, t: Int64, message: String = askMessage) -> Event {
  Event(id: id, session: "s1", t: t, kind: "pasting", data: ["text": .string(message)])
}

private func promptEvent(_ id: Int64, t: Int64, _ text: String) -> Event {
  Event(id: id, session: "s1", t: t, kind: "UserPromptSubmit", data: ["prompt": .string(text)])
}

/// A list opened from `start`, then an ask about decision 2 with the
/// verdict and item that sbd would save. Event ids continue from 6.
private struct Asked {
  var facts: SessionFacts
  var verdict: SavedVerdict
  var item: TriageItem

  init(_ start: ClarifyStart, card: JSON = decisionSummaryJSON) throws {
    var f = try openList(start, card: card)
    let verdict = try current(f, now: 300)
    let snapshot = try #require(
      Triage.item(f, Attention.evaluate(session(), f, now: 300), kind: .work), "the open list has no item")
    try #require(snapshot.ref == listRef)
    track(&f, [try decisionAsked(5, t: 300, verdict: verdict, item: snapshot)])
    facts = f
    self.verdict = verdict
    item = snapshot
  }

  /// The send of the question: `sent`, then `pasting`, which leaves the
  /// message on its way.
  mutating func send() {
    track(&facts, [sentQuestion(6, t: 301), pasting(7, t: 302)])
  }

  /// The clarifying turn after the send: its prompt, a tool call, and its Stop.
  mutating func clarify(_ start: ClarifyStart, prompt text: String = askMessage) {
    send()
    track(
      &facts,
      [
        promptEvent(8, t: 310, text),
        Event(id: 9, session: "s1", t: 315, kind: "PreToolUse", data: .object(tool("Read", ["file_path": "/a"]))),
        Event(id: 10, session: "s1", t: 316, kind: "PostToolUse", data: .object(tool("Read", ["file_path": "/a"]))),
        stop(11, 320, start.clarifyingReply),
      ])
  }

  func now(_ t: Int64) throws -> SavedVerdict { try current(facts, now: t) }
}

// MARK: The hold

@Suite struct DecisionClarifyVerdictTests {
  /// Test 1. After each step the verdict is the one saved on `decision_asked`:
  /// same state, reason, and `since`.
  @Test(arguments: ClarifyStart.allCases)
  func aClarifyingTurnNeverChangesTheVerdict(_ start: ClarifyStart) throws {
    let a = try Asked(start)
    let saved = a.verdict
    var f = a.facts
    try #require(f.clarifying != nil, "the facts ignore decision_asked")
    #expect(try current(f, now: 300) == saved, "after decision_asked")

    track(&f, [sentQuestion(6, t: 301), pasting(7, t: 302)])
    try #require(f.promptOnItsWaySince != nil, "the send left no message on its way")
    #expect(try current(f, now: 302) == saved, "after the send")

    track(&f, [promptEvent(8, t: 310, askMessage)])
    try #require(f.turnRunning)
    #expect(try current(f, now: 310) == saved, "after the clarifying UserPromptSubmit")

    track(
      &f, [Event(id: 9, session: "s1", t: 315, kind: "PreToolUse", data: .object(tool("Read", ["file_path": "/a"])))])
    try #require(f.runningTool != nil)
    #expect(try current(f, now: 315) == saved, "while the clarifying turn runs a tool")

    track(
      &f,
      [
        Event(id: 10, session: "s1", t: 316, kind: "PostToolUse", data: .object(tool("Read", ["file_path": "/a"]))),
        stop(11, 320, start.clarifyingReply),
      ])
    try #require(!f.turnRunning)
    try #require(f.lastReply == start.clarifyingReply)
    #expect(try current(f, now: 320) == saved, "after the clarifying Stop")
    #expect(try current(f, now: 5_000) == saved, "on a later tick")
  }

  /// A later ask inside the same hold keeps the first ask's snapshots, even
  /// when its event carries other ones.
  @Test(arguments: ClarifyStart.allCases)
  func aLaterAskInTheSameHoldKeepsTheFirstSnapshots(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    var other = a.item
    other.title = "Read the answer about the name"
    other.summary = "It explained the name."
    other.ref = "stop:11"
    let otherVerdict = SavedVerdict(state: .waiting, reason: "waits on something else", since: 999)

    track(&a.facts, [try decisionAsked(12, t: 400, askId: "ask-2", number: 3, verdict: otherVerdict, item: other)])

    #expect(try a.now(400) == a.verdict)
    let live = try #require(Triage.liveItem(a.facts, Attention.evaluate(session(), a.facts, now: 400)))
    #expect(live.title == a.item.title)
    #expect(live.summary == a.item.summary)
    #expect(live.ref == listRef)
  }

  /// A typed prompt makes the list stale, and a stale list ends the hold.
  @Test(arguments: ClarifyStart.allCases)
  func aTypedPromptEndsTheHold(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.send()

    let v = track(&a.facts, [promptEvent(8, t: 310, "go on")])

    #expect(v.state == .working, "\(v.state) \(v.reason)")
  }

  /// A normal turn after the clarifying turn ends the hold.
  @Test(arguments: ClarifyStart.allCases)
  func aNormalTurnAfterTheClarifyingTurnEndsTheHold(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)

    let v = track(&a.facts, [promptEvent(12, t: 400, "go on")])

    #expect(v.state == .working, "\(v.state) \(v.reason)")
  }

  /// Discarding the list ends the hold. The clarifying reply then decides the state.
  @Test func discardingTheListEndsTheHold() throws {
    let start = ClarifyStart.needsYou
    var a = try Asked(start)
    a.clarify(start)

    let v = track(&a.facts, [Event(id: 12, session: "s1", t: 400, kind: "decisions_discarded", data: [:])])

    let own = Attention.replyVerdict(start.clarifyingReply)
    #expect(v.state == own.state, "\(v.state) \(v.reason)")
    #expect(v.reason == own.reason)
  }

  /// A submit keeps the hold until the next prompt. Until then, the item keeps the sent decisions that Resend needs.
  /// The clarifying reply gets no summary.
  @Test(arguments: ClarifyStart.allCases)
  func aSubmitKeepsTheHoldUntilTheNextPrompt(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    let submit = Event(
      id: 12, session: "s1", t: 400, kind: "decisions_submitted",
      data: ["message": "My decisions", "ref": .string(listRef)])

    let held = track(&a.facts, [submit])

    #expect(try a.now(400) == a.verdict)
    #expect(held.savedAtAsk)
    #expect(Triage.itemAndDecisions(a.facts, held, kind: .work).decisionsSent)
    #expect(!Triage.needsSummary(a.facts, held))

    let after = track(&a.facts, [promptEvent(13, t: 410, "My decisions")])

    #expect(a.facts.heldAsk == nil)
    #expect(!after.savedAtAsk)
  }

  /// A permission card during the clarifying turn outranks the hold.
  @Test(arguments: ClarifyStart.allCases)
  func aHeldCardOutranksTheHold(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])

    let v = track(
      &a.facts,
      [
        Event(
          id: 9, session: "s1", t: 315, kind: "PermissionRequest",
          data: .object(tool("Bash", ["command": "rm -rf build"])))
      ])

    let card = try #require(a.facts.cards.first, "the permission request opened no card")
    #expect(v.state == .needsYou)
    #expect(v.reason == card.reason, "\(v.reason)")
    #expect(v.reason != a.verdict.reason)
  }

  /// A failed removal outranks the hold.
  @Test(arguments: ClarifyStart.allCases)
  func aFailedRemovalOutranksTheHold(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    var s = session()
    var removal = Removal(requested: 0, notBefore: 0, worktree: true, branch: true, remoteBranch: false, resolve: [])
    removal.state = .failed
    removal.error = "git worktree remove failed"
    s.removal = removal

    let v = Attention.evaluate(s, a.facts, now: 400)

    #expect(v.reason.hasPrefix("Delete failed"), "\(v.state) \(v.reason)")
    #expect(v.removalFailed)
  }
}

extension DecisionClarifyVerdictTests {
  /// The request hold changes a rule verdict that a request covers. It must leave the saved verdict alone.
  @Test func aRequestThatCoversTheSavedVerdictLeavesIt() throws {
    var a = try Asked(.needsYou)
    a.clarify(.needsYou)

    track(
      &a.facts,
      [
        Event(
          id: 12, session: "s1", t: 400, kind: InboxRequest.event,
          data: [
            "state": .string(a.verdict.state.rawValue), "reason": .string(a.verdict.reason), "message": "Do it.",
            "until": 3_600_000, "readMs": 60_000,
          ])
      ])

    try #require(a.facts.request != nil)
    #expect(try a.now(400) == a.verdict)
  }

  /// `readyForReview` turns a Waiting verdict into Ready for review. It must leave a saved Waiting verdict alone.
  @Test func aReadyPRLeavesASavedWaitingVerdict() throws {
    var f = try openList(.needsYou)
    let item = try #require(Triage.item(f, Attention.evaluate(session(), f, now: 300), kind: .work))
    let saved = SavedVerdict(state: .waiting, reason: "waits on CI", since: f.stateSince)

    track(&f, [try decisionAsked(5, t: 300, verdict: saved, item: item), try prEvent(301, samplePR())])

    try #require(f.pr?.ready == true)
    let v = Attention.evaluate(session(), f, now: 301)
    #expect(v.state == .waiting, "\(v.state) \(v.reason)")
    #expect(v.reason == saved.reason)
  }

  /// A held card outranks the hold in the item too.
  @Test func aHeldCardGivesTheCardsItem() throws {
    var a = try Asked(.canContinue)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])
    track(
      &a.facts,
      [
        Event(
          id: 9, session: "s1", t: 315, kind: "PermissionRequest",
          data: .object(tool("Bash", ["command": "rm -rf build"])))
      ])
    let card = try #require(a.facts.cards.first)

    let live = try #require(Triage.liveItem(a.facts, Attention.evaluate(session(), a.facts, now: 315)))

    #expect(live.source == .card)
    #expect(live.ref == card.ref)
  }
}

// MARK: The list

@Suite struct DecisionClarifyListTests {
  struct PromptCase: Sendable, CustomTestStringConvertible {
    var name: String
    var prompt: String
    var clarifying: Bool
    var testDescription: String { name }
  }

  /// Tests 3 and 4. After the paste, only the question itself, with nothing after it but attached images, starts the
  /// clarifying turn. Any other prompt is the question as the user changed it in the terminal before claude took it.
  /// It makes the list stale, and the paste's `delivered` closes the ask with an error, because the question's own
  /// prompt never comes.
  @Test(arguments: [
    PromptCase(name: "the question", prompt: askMessage, clarifying: true),
    PromptCase(name: "the question with an image", prompt: askMessage + " [Image #1]", clarifying: true),
    PromptCase(name: "the question with two images", prompt: askMessage + "\n[Image #1] [Image #2]", clarifying: true),
    PromptCase(name: "a typed prompt", prompt: "go on", clarifying: false),
    PromptCase(name: "the question with more text", prompt: askMessage + " and rename it", clarifying: false),
    PromptCase(
      name: "the question with an image and text", prompt: askMessage + " [Image #1] and more", clarifying: false),
    PromptCase(name: "the start of the question", prompt: String(askMessage.dropLast(5)), clarifying: false),
    PromptCase(name: "the question as part of a longer prompt", prompt: "Also: " + askMessage, clarifying: false),
  ])
  func onlyTheClarifyingPromptLeavesTheListFresh(_ c: PromptCase) throws {
    var a = try Asked(.needsYou)
    a.send()

    track(
      &a.facts,
      [
        promptEvent(8, t: 310, c.prompt),
        Event(id: 9, session: "s1", t: 311, kind: "delivered", data: ["text": .string(askMessage)]),
      ])

    #expect(a.facts.decisionList?.stale == !c.clarifying)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    if c.clarifying {
      #expect(a.facts.clarifying?.started == true)
      #expect(exchange.pending)
    } else {
      #expect(a.facts.clarifying == nil)
      #expect(exchange.error == "The question changed before it reached the session. Ask again.")
      #expect(!exchange.pending)
      #expect(exchange.reply == nil)
    }
  }

  /// The question as the user changed it during its paste. Claude takes the changed text as one prompt.
  enum EditedPaste: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// The prompt comes while the paste runs, and the paste's `delivered` closes the ask.
    case promptBeforeDelivered
    /// A paste that sbd records only as `delivered` counts as a paste too.
    case onlyDelivered
    case promptAfterDelivered

    var testDescription: String { rawValue }

    var events: [Event] {
      let kinds: [String] =
        switch self {
        case .promptBeforeDelivered: ["pasting", "UserPromptSubmit", "delivered"]
        case .onlyDelivered: ["delivered", "UserPromptSubmit"]
        case .promptAfterDelivered: ["pasting", "delivered", "UserPromptSubmit"]
        }
      let edited = askMessage.replacingOccurrences(of: "task", with: "job")
      return kinds.enumerated().map { i, kind in
        let id = Int64(7 + i)
        return kind == "UserPromptSubmit"
          ? promptEvent(id, t: 302 + Int64(i), edited)
          : Event(id: id, session: "s1", t: 302 + Int64(i), kind: kind, data: ["text": .string(askMessage)])
      }
    }
  }

  @Test(arguments: EditedPaste.allCases)
  func anEditedQuestionThatIsDeliveredClosesTheAskAndMakesTheListStale(_ edited: EditedPaste) throws {
    var a = try Asked(.needsYou)
    track(&a.facts, [sentQuestion(6, t: 301)])

    let v = track(&a.facts, edited.events)

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == "The question changed before it reached the session. Ask again.")
    #expect(!exchange.pending)
    #expect(a.facts.decisionList?.stale == true)
    #expect(v.state == .working, "\(v.state) \(v.reason)")
  }

  /// A prompt that the user typed while the paste ran made the paste fail. The question waits in the queue again.
  @Test func aTypedPromptDuringAPasteThatFailsLeavesTheAskPending() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(
      &a.facts,
      [
        promptEvent(8, t: 305, "go on"),
        Event(id: 9, session: "s1", t: 306, kind: "requeued", data: ["text": .string(askMessage)]),
      ])

    #expect(a.facts.clarifying?.started == false)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
    #expect(a.facts.decisionList?.stale == true)
  }

  /// The retry of a paste that a typed prompt made fail delivers the question, and its turn files the reply.
  @Test func theRetryOfAPasteThatATypedPromptMadeFailFilesTheReply() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(
      &a.facts,
      [
        promptEvent(8, t: 305, "go on"),
        Event(id: 9, session: "s1", t: 306, kind: "requeued", data: ["text": .string(askMessage)]),
        stop(10, 308, "Going on."),
        pasting(11, t: 310),
        Event(id: 12, session: "s1", t: 311, kind: "delivered", data: ["text": .string(askMessage)]),
        promptEvent(13, t: 312, askMessage),
        stop(14, 320, ClarifyStart.needsYou.clarifyingReply),
      ])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.reply == ClarifyStart.needsYou.clarifyingReply)
    #expect(exchange.error == nil)
    #expect(!exchange.pending)
  }

  /// What came before a prompt that is not the question, while the question has not been pasted.
  enum BeforePaste: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// sbd chose to paste, but the paste waits until claude's prompt box shows empty.
    case sentToPaste
    case queued
    /// The paste failed and the question went back to the queue.
    case requeued
    case pasteOfAnotherMessage

    var testDescription: String { rawValue }

    var events: [Event] {
      switch self {
      case .sentToPaste: [sentQuestion(6, t: 301)]
      case .queued:
        [
          Event(
            id: 6, session: "s1", t: 301, kind: "sent",
            data: ["text": .string(askMessage), "by": "sbd", "delivery": .string(Delivery.queued.rawValue)])
        ]
      case .requeued:
        [
          sentQuestion(6, t: 301), pasting(7, t: 302),
          Event(id: 8, session: "s1", t: 303, kind: "requeued", data: ["text": .string(askMessage)]),
        ]
      case .pasteOfAnotherMessage: [sentQuestion(6, t: 301), pasting(7, t: 302, message: "hello")]
      }
    }
  }

  /// Test 4. A typed prompt that arrives before the question's paste starts leaves the ask waiting for its own
  /// prompt.
  @Test(arguments: BeforePaste.allCases)
  func aTypedPromptBeforeTheQuestionsPasteLeavesTheAskPending(_ before: BeforePaste) throws {
    var a = try Asked(.needsYou)
    track(&a.facts, before.events)

    track(&a.facts, [promptEvent(9, t: 305, "go on")])

    #expect(a.facts.clarifying?.started == false)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
    #expect(a.facts.decisionList?.stale == true)
  }

  /// The clarifying Stop leaves the list fresh.
  @Test(arguments: ClarifyStart.allCases)
  func theClarifyingTurnLeavesTheListFresh(_ start: ClarifyStart) throws {
    var a = try Asked(start)

    a.clarify(start)

    #expect(a.facts.decisionList?.stale == false)
    #expect(a.facts.clarifying == nil)
  }

  @Test func theAskRecordsAPendingExchangeUnderItsDecision() throws {
    let a = try Asked(.needsYou)

    let exchanges = try #require(a.facts.decisionList?.exchanges)
    #expect(exchanges.count == 1)
    #expect(exchanges.first?.askId == "ask-1")
    #expect(exchanges.first?.number == askNumber)
    #expect(exchanges.first?.text == askText)
    #expect(exchanges.first?.pending == true)
    #expect(exchanges.first?.reply == nil)
    #expect(exchanges.first?.error == nil)
  }

  @Test func theAskRecordsTheClarifyingTurnToCome() throws {
    let a = try Asked(.needsYou)

    let clarifying = try #require(a.facts.clarifying)
    #expect(clarifying.askId == "ask-1")
    #expect(clarifying.number == askNumber)
    #expect(clarifying.message == askMessage)
    #expect(clarifying.started == false)
  }

  /// Test 5. The Stop's reply goes under the decision asked about and nowhere else.
  @Test(arguments: ClarifyStart.allCases)
  func theReplyIsFiledUnderTheDecisionAskedAbout(_ start: ClarifyStart) throws {
    var a = try Asked(start)

    a.clarify(start)

    let exchanges = try #require(a.facts.decisionList?.exchanges)
    #expect(exchanges.map(\.number) == [askNumber])
    #expect(exchanges.first?.reply == start.clarifyingReply)
    #expect(exchanges.first?.pending == false)
    #expect(exchanges.first?.error == nil)
  }

  @Test func theReplyIsPendingUntilTheStop() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(&a.facts, [promptEvent(8, t: 310, askMessage)])

    #expect(a.facts.clarifying?.started == true)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
    #expect(a.facts.decisionList?.exchanges.first?.reply == nil)
  }

  /// claude shows an attached image as `[Image #n]` after the text. The turn
  /// it starts is still the clarifying turn, so its reply is filed.
  @Test func aQuestionWithAnAttachedImageStillFilesTheReply() throws {
    var a = try Asked(.needsYou)

    a.clarify(.needsYou, prompt: askMessage + " [Image #1]")

    #expect(a.facts.decisionList?.exchanges.first?.reply == ClarifyStart.needsYou.clarifyingReply)
    #expect(a.facts.decisionList?.stale == false)
  }

  @Test func aSecondAskAddsItsOwnExchangeAfterTheFirst() throws {
    var a = try Asked(.needsYou)
    a.clarify(.needsYou)

    track(
      &a.facts,
      [try decisionAsked(12, t: 400, askId: "ask-2", number: 3, text: "Why both?", verdict: a.verdict, item: a.item)])

    let exchanges = try #require(a.facts.decisionList?.exchanges)
    #expect(exchanges.map(\.askId) == ["ask-1", "ask-2"])
    #expect(exchanges.map(\.number) == [askNumber, 3])
    #expect(exchanges.map(\.pending) == [false, true])
  }

  /// Test 8. A clarifying turn that never stopped closes with an error at the
  /// next different prompt, and that prompt makes the list stale.
  @Test(arguments: ClarifyStart.allCases)
  func anInterruptedClarifyingTurnClosesWithAnError(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])
    try #require(a.facts.clarifying?.started == true)

    let v = track(&a.facts, [promptEvent(9, t: 330, "never mind, go on")])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error?.hasPrefix("The turn ended without an answer") == true, "\(exchange.error ?? "nil")")
    #expect(exchange.pending == false)
    #expect(exchange.reply == nil)
    #expect(a.facts.decisionList?.stale == true)
    #expect(v.state == .working, "\(v.state) \(v.reason)")
  }
}

extension DecisionClarifyListTests {
  /// A subagent's Stop doesn't end the clarifying turn.
  @Test func aSubagentStopFilesNoReply() throws {
    var a = try Asked(.needsYou)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])

    track(
      &a.facts,
      [
        Event(
          id: 9, session: "s1", t: 315, kind: "Stop",
          data: ["last_assistant_message": "a subagent's answer", "agent_id": "sub-1"])
      ])

    #expect(a.facts.clarifying?.started == true)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
  }

  /// A Stop with no message closes the ask with an error instead of an empty reply.
  @Test func aStopWithoutAMessageClosesTheAskWithAnError() throws {
    var a = try Asked(.needsYou)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage), Event(id: 9, session: "s1", t: 320, kind: "Stop", data: [:])])

    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.reply == nil)
    #expect(exchange.error?.hasPrefix("The turn ended without an answer") == true)
    #expect(a.facts.clarifying == nil)
  }

  /// Only one ask is pending at a time, so a second one records nothing.
  @Test func anAskWhileAnotherIsPendingRecordsNothing() throws {
    var a = try Asked(.needsYou)

    track(&a.facts, [try decisionAsked(6, t: 301, askId: "ask-2", number: 3, verdict: a.verdict, item: a.item)])

    #expect(a.facts.clarifying?.askId == "ask-1")
    #expect(a.facts.decisionList?.exchanges.map(\.askId) == ["ask-1"])
  }

  /// An ask about another list, or about a stale list, records nothing and holds nothing.
  @Test func anAskAboutAnotherOrStaleListRecordsNothing() throws {
    var f = try openList(.needsYou)
    let saved = try current(f, now: 300)
    let item = try #require(Triage.item(f, Attention.evaluate(session(), f, now: 300), kind: .work))

    track(&f, [try decisionAsked(5, t: 300, ref: "stop:2", verdict: saved, item: item)])

    #expect(f.clarifying == nil)
    #expect(f.decisionList?.exchanges.isEmpty == true)
    #expect(f.heldAsk == nil)

    track(
      &f,
      [
        promptEvent(6, t: 310, "go on"), stop(7, 320, "Done."),
        try decisionAsked(8, t: 330, verdict: saved, item: item),
      ])

    #expect(f.clarifying == nil)
    #expect(f.decisionList?.exchanges.isEmpty == true)
    #expect(f.heldAsk == nil)
  }

  /// Test 8's other ends. A turn that ends without a Stop closes the started ask with an error, so the pending-ask
  /// refusals don't block Submit. The list stays fresh and the hold stays.
  @Test(arguments: TurnEnd.allCases)
  func aClarifyingTurnThatEndsWithoutAStopClosesTheAskWithAnError(_ end: TurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])
    try #require(a.facts.clarifying?.started == true)

    track(&a.facts, [end.event(9, t: 320)])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == SessionFacts.unansweredAsk)
    #expect(exchange.pending == false)
    #expect(exchange.reply == nil)
    #expect(a.facts.decisionList?.stale == false)
    #expect(try a.now(330) == a.verdict)
  }

  /// Before its prompt arrives, the question may still be on its way, so an end of the earlier turn leaves it pending.
  @Test(arguments: [TurnEnd.idlePrompt, .stopFailure, .idle])
  func anEndBeforeTheClarifyingPromptLeavesTheAskPending(_ end: TurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()

    track(&a.facts, [end.event(8, t: 310)])

    #expect(a.facts.clarifying?.started == false)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
  }

  /// A claude that ends before the question's prompt arrived lost the question. The ask closes, so it doesn't
  /// refuse every change to the list for good.
  @Test(arguments: [TurnEnd.sessionEnd, .stopped, .exited])
  func anExitBeforeTheClarifyingPromptClosesTheAsk(_ end: TurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()

    track(&a.facts, [end.event(8, t: 310)])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == "The question never reached the session. Ask again.")
    #expect(exchange.pending == false)
    #expect(a.facts.decisionList?.stale == false)
  }

  /// sbd restarted during the question's paste and can't tell whether it landed. The ask closes, and a prompt of
  /// the message that arrives after all is an ordinary prompt.
  @Test func anUnknownDeliveryOfTheQuestionClosesTheAsk() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(
      &a.facts, [Event(id: 8, session: "s1", t: 310, kind: "delivery_unknown", data: ["text": .string(askMessage)])])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(
      exchange.error
        == "Switchboard can't tell whether your question reached the session. Ask again if no answer appears.")
    #expect(exchange.pending == false)
    track(&a.facts, [promptEvent(9, t: 320, askMessage)])
    #expect(a.facts.decisionList?.stale == true)
  }

  /// An unknown delivery of another message, or of the question after its turn started, leaves the ask pending.
  @Test func anUnknownDeliveryOfAnotherMessageOrAStartedQuestionLeavesTheAsk() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(&a.facts, [Event(id: 8, session: "s1", t: 310, kind: "delivery_unknown", data: ["text": "hello"])])
    #expect(a.facts.clarifying?.askId == "ask-1")

    track(
      &a.facts,
      [
        promptEvent(9, t: 320, askMessage),
        Event(id: 10, session: "s1", t: 330, kind: "delivery_unknown", data: ["text": .string(askMessage)]),
      ])
    #expect(a.facts.clarifying?.started == true)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
  }

  /// A subagent's StopFailure or idle prompt doesn't end the clarifying turn.
  @Test(arguments: [TurnEnd.stopFailure, .idlePrompt])
  func aSubagentsEndLeavesTheAskPending(_ end: TurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])

    var event = end.event(9, t: 320)
    event.data = .object((event.data.object ?? [:]).merging(["agent_id": "sub-1"]) { $1 })
    track(&a.facts, [event])

    #expect(a.facts.clarifying?.started == true)
    #expect(a.facts.decisionList?.exchanges.first?.pending == true)
  }

  /// A main Stop after a subagent's Stop still files the reply, although the subagent's Stop ended the turn.
  @Test func aMainStopAfterASubagentStopFilesTheReply() throws {
    var a = try Asked(.needsYou)
    a.send()

    track(
      &a.facts,
      [
        promptEvent(8, t: 310, askMessage),
        Event(
          id: 9, session: "s1", t: 315, kind: "Stop",
          data: ["last_assistant_message": "a subagent's answer", "agent_id": "sub-1"]),
        stop(10, 320, "B would break the public API."),
      ])

    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.reply == "B would break the public API.")
    #expect(exchange.pending == false)
    #expect(a.facts.clarifying == nil)
  }

  /// A subagent's end clears `turnRunning`, so the main session's later end of the turn ends no turn. It still
  /// closes the started ask with an error.
  @Test(arguments: ["Stop", "StopFailure"], [TurnEnd.stopFailure, .idlePrompt, .idle])
  func aMainEndAfterASubagentEndedTheTurnClosesTheStartedAsk(_ subagentKind: String, _ end: TurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()
    let subagentEnd = Event(
      id: 9, session: "s1", t: 315, kind: subagentKind,
      data: ["last_assistant_message": "a subagent's answer", "agent_id": "sub-1"])
    track(&a.facts, [promptEvent(8, t: 310, askMessage), subagentEnd])
    try #require(a.facts.clarifying?.started == true)
    try #require(!a.facts.turnRunning)

    track(&a.facts, [end.event(10, t: 320)])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == SessionFacts.unansweredAsk)
    #expect(!exchange.pending)
    #expect(exchange.reply == nil)
    #expect(a.facts.decisionList?.stale == false)
  }

  /// A subagent's end of the turn leaves the started ask open, so claude's exit closes it with an error.
  @Test func anExitAfterASubagentEndedTheTurnClosesTheStartedAsk() throws {
    var a = try Asked(.needsYou)
    a.send()
    var subagentEnd = TurnEnd.stopFailure.event(9, t: 315)
    subagentEnd.data = .object((subagentEnd.data.object ?? [:]).merging(["agent_id": "sub-1"]) { $1 })
    track(&a.facts, [promptEvent(8, t: 310, askMessage), subagentEnd])
    try #require(a.facts.clarifying?.started == true)
    try #require(!a.facts.turnRunning)

    track(&a.facts, [TurnEnd.exited.event(10, t: 320)])

    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == SessionFacts.unansweredAsk)
    #expect(exchange.pending == false)
  }

  /// Other events end the turn without a Stop too: a prompt that the skill check blocks, a card answer that
  /// interrupts the turn, and a deny without a message. Each closes the started ask with an error.
  @Test(arguments: SilentTurnEnd.allCases)
  func anyOtherEndOfTheClarifyingTurnClosesTheAskWithAnError(_ end: SilentTurnEnd) throws {
    var a = try Asked(.needsYou)
    a.send()
    track(
      &a.facts,
      [
        promptEvent(8, t: 310, askMessage),
        Event(
          id: 9, session: "s1", t: 315, kind: "PermissionRequest",
          data: .object(tool("Bash", ["command": "rm -rf build"]))),
      ])
    try #require(a.facts.clarifying?.started == true)
    try #require(a.facts.cards.first?.id == 9)

    track(&a.facts, [end.event(10, t: 320, card: 9)])

    #expect(!a.facts.turnRunning)
    #expect(a.facts.clarifying == nil)
    let exchange = try #require(a.facts.decisionList?.exchanges.first)
    #expect(exchange.error == SessionFacts.unansweredAsk)
    #expect(exchange.pending == false)
    #expect(exchange.reply == nil)
  }

  /// The one test that pins the message's text. The other tests build it with `DecisionAsk.message`.
  @Test func theMessageNamesTheDecisionByNumberAndHeader() throws {
    let decision = PendingDecision(
      number: askNumber, header: "Name", question: "What do we call it?",
      options: [.init(label: "A"), .init(label: "B")])

    #expect(
      DecisionAsk.message(about: decision, askText)
        == "Question about decision 2 (Name) in your last reply, before I decide: Why not call it task?\n\n"
        + "Answer only this question, in text. Don't change files, run commands that change anything, or start "
        + "work. Don't write `sb summary set` or ask with AskUserQuestion this turn. "
        + "I'll send all my decisions together when I'm done.")
  }

  /// A list that an older sbd wrote has no exchanges.
  @Test func aListWithoutExchangesDecodes() throws {
    let json = #"{"decisions":[],"ref":"summary:3","answers":[],"stale":false,"newer":[]}"#

    let list = try JSONCoding.decode(DecisionList.self, from: json)

    #expect(list.exchanges.isEmpty)
  }
}

/// An event that ends a turn without a Stop.
enum TurnEnd: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case idlePrompt
  case stopFailure
  /// sbd found that Escape ended the turn.
  case idle
  case sessionEnd
  case stopped
  case exited

  var testDescription: String { rawValue }

  func event(_ id: Int64, t: Int64) -> Event {
    switch self {
    case .idlePrompt:
      Event(id: id, session: "s1", t: t, kind: "Notification", data: ["notification_type": "idle_prompt"])
    case .stopFailure: Event(id: id, session: "s1", t: t, kind: "StopFailure", data: ["error": "rate_limit"])
    case .idle: Event(id: id, session: "s1", t: t, kind: "idle")
    case .sessionEnd: Event(id: id, session: "s1", t: t, kind: "SessionEnd")
    case .stopped: Event(id: id, session: "s1", t: t, kind: "stopped")
    case .exited: Event(id: id, session: "s1", t: t, kind: "exited")
    }
  }
}

/// An event that ends a turn in `SessionFacts.apply` without a Stop and that no `TurnEnd` covers.
enum SilentTurnEnd: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case skillBlocked
  case interruptedAnswer
  case denyWithoutMessage

  var testDescription: String { rawValue }

  func event(_ id: Int64, t: Int64, card: Int) -> Event {
    switch self {
    case .skillBlocked:
      Event(id: id, session: "s1", t: t, kind: "skill_blocked", data: ["skill": "go", "via": "prompt", "by": "haiku"])
    case .interruptedAnswer:
      Event(
        id: id, session: "s1", t: t, kind: "answered",
        data: ["card": .number(Double(card)), "behavior": "allow", "interrupted": true])
    case .denyWithoutMessage:
      Event(id: id, session: "s1", t: t, kind: "answered", data: ["card": .number(Double(card)), "behavior": "deny"])
    }
  }
}

// MARK: The item

@Suite struct DecisionClarifyItemTests {
  /// The item after the clarifying Stop keeps the card's callouts and drafts.
  @Test func theSnapshotKeepsTheCardsCalloutsAndDrafts() throws {
    var card = try #require(decisionSummaryJSON.object)
    card["callouts"] = [["kind": "warning", "title": "Drops events_old", "body": "The migration deletes the table."]]
    card["drafts"] = [["label": "Reply", "text": "Thanks, fixed."]]
    var a = try Asked(.needsYou, card: .object(card))
    try #require(a.item.callouts.count == 1, "the card's callout is missing before the ask")
    try #require(a.item.drafts.count == 1, "the card's draft is missing before the ask")
    a.clarify(.needsYou)

    let built = try #require(Triage.item(a.facts, Attention.evaluate(session(), a.facts, now: 400), kind: .work))

    #expect(built.callouts == a.item.callouts)
    #expect(built.drafts.map(\.text) == a.item.drafts.map(\.text))
  }

  /// Test 6. After the clarifying Stop the item is the snapshot from the ask,
  /// with the list's ref and decisions.
  @Test(arguments: ClarifyStart.allCases)
  func theItemIsTheSnapshotAfterTheClarifyingStop(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    let v = Attention.evaluate(session(), a.facts, now: 400)

    let live = try #require(Triage.liveItem(a.facts, v), "no live item after the clarifying Stop")
    #expect(live.title == a.item.title)
    #expect(live.summary == a.item.summary)
    #expect(live.kind == a.item.kind)
    #expect(live.ref == listRef)
    let built = try #require(Triage.item(a.facts, v, kind: .work))
    #expect(built.decisions == a.facts.decisionList?.decisions)
    #expect(built.ref == listRef)
  }

  /// The item stays the snapshot while the clarifying turn runs.
  @Test(arguments: ClarifyStart.allCases)
  func theItemIsTheSnapshotDuringTheClarifyingTurn(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.send()
    track(&a.facts, [promptEvent(8, t: 310, askMessage)])
    let v = Attention.evaluate(session(), a.facts, now: 310)

    let live = try #require(Triage.liveItem(a.facts, v), "no live item while the clarifying turn runs")
    #expect(live.title == a.item.title)
    #expect(live.ref == listRef)
  }

  /// Test 6. The clarifying reply's verdict isn't the reply's own, so it needs no summary.
  @Test(arguments: ClarifyStart.allCases)
  func theClarifyingReplyNeedsNoSummary(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    try #require(a.facts.triage == nil)
    try #require(a.facts.lastReply == start.clarifyingReply)

    let v = Attention.evaluate(session(), a.facts, now: 400)

    #expect(!Triage.needsSummary(a.facts, v))
  }

  /// Test 6. A summary of the clarifying turn with its own decisions puts
  /// nothing in `newer`, and the item stays the snapshot.
  @Test(arguments: ClarifyStart.allCases)
  func aSummaryOfTheClarifyingTurnAddsNoNewerDecisions(_ start: ClarifyStart) throws {
    var a = try Asked(start)
    a.clarify(start)
    let later: [JSON] = [
      [
        "number": 1, "header": "Volume", "question": "Which volume?",
        "options": [["label": "Low"], ["label": "High"]],
      ],
      [
        "number": 2, "header": "Numbers", "question": "Show the numbers?",
        "options": [["label": "Yes"], ["label": "No"]],
      ],
    ]
    track(
      &a.facts,
      [
        Event(
          id: 12, session: "s1", t: 330, kind: "triage",
          data: [
            "stop": 11, "title": "Pick a volume", "kind": "decision", "summary": "It asks about volume.",
            "options": [], "decisions": .array(later),
          ])
      ])
    let v = Attention.evaluate(session(), a.facts, now: 400)

    let (built, list, _) = Triage.itemAndDecisions(a.facts, v, kind: .work)

    let decisions = try #require(list, "the list closed")
    #expect(decisions.newer.isEmpty, "\(decisions.newer.map(\.header))")
    #expect(built?.title == a.item.title)
    #expect(built?.ref == listRef)
  }
}
