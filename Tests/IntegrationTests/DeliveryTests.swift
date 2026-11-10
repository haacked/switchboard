import Foundation
import SwitchboardCore
import Testing

/// The first line of the message that `answerThreeDecisions` makes a submit send.
private let decisionsLead = "My decisions on the 3 questions in your last reply:"

extension Instance {
  /// The session's events of the kind whose `text` is the text.
  func events(_ id: String, _ kind: String, text: String) throws -> [Event] {
    try events(id).filter { $0.kind == kind && $0.data["text"]?.string == text }
  }

  /// The message that the session's one decisions submit sent.
  func submittedMessage(_ id: String) throws -> String {
    try #require(try decisionMessages(id).first)
  }

  /// The session's `decisionsDelivery` as `sb get --json` prints it, or nil when it prints none.
  func decisionsDelivery(_ id: String) throws -> String? {
    try #require(JSON.parse(try sb("get", "--json", id)))["decisionsDelivery"]?.string
  }

  /// Waits until a paste that started after `before` complete pastes reached
  /// the stub with its Enter. sbd then has recorded `pasting`, and only
  /// `delivered` remains.
  func waitForCompletePaste(after before: Int) throws {
    try waitFor("the paste and its Enter to reach the stub") { completePastes() > before }
  }

  /// A session with its three decisions answered and a submit whose paste
  /// reached the stub, Enter included, while `hold-delivered` keeps sbd from
  /// recording `delivered`. The stub's `hold` keeps the prompt from landing,
  /// so the transcript lacks the message. sbd then dies with SIGKILL. On
  /// return, the gate is open again and sbd is still down. It returns the
  /// submitted message too, because sbd can't report it while it is down.
  func submitKilledBeforeDelivered() throws -> (SessionSummary, String) {
    let s = try decisionSession()
    try answerThreeDecisions(s.id)
    hold("hold-delivered")
    hold("hold")
    let before = completePastes()

    try sb("decide", s.id, "--submit")
    try waitForCompletePaste(after: before)

    let message = try submittedMessage(s.id)
    try #require(try events(s.id, "pasting", text: message).count == 1, "sbd records pasting before the paste")
    try #require(try events(s.id, "delivered", text: message).isEmpty, "hold-delivered let delivered through")
    try #require(!transcriptContains(s, decisionsLead), "the stub's hold let the prompt land")
    killSbd()
    try release("hold-delivered")
    return (s, message)
  }

  /// Runs `body` while a second connection holds the database's write lock.
  /// Each write of sbd waits out its busy timeout of 2 s and fails.
  func whileTheLogIsLocked<T>(_ body: () throws -> T) throws -> T {
    try Store(path: home.database).transaction(body)
  }

  /// Waits a moment for a paste that should not come, then returns how many
  /// times the stub read the text.
  func settledStubInputCount(_ text: String) -> Int {
    usleep(1_500_000)
    return stubInputCount(text)
  }
}

/// A decisions submit that sbd accepted reaches the session exactly once, or
/// sbd says that it can't tell, when sbd dies between accepting the message
/// and recording that it arrived.
@Suite(.blocking(timeLimit: .seconds(120))) struct DecisionDeliveryTests {
  /// `hold-paste` keeps the paste from starting, so sbd never recorded
  /// `pasting`. The stub's `hold` keeps the prompt from landing, so the item
  /// still shows the sent decisions after the restart. Any second paste waits
  /// in the terminal until the stub's turn ends, so the count after the reply
  /// shows every paste.
  @Test func aSubmitKilledBeforeItsPasteReachesTheSessionOnceAfterARestart() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    sbd.hold("hold-paste")
    sbd.hold("hold")

    try sbd.sb("decide", s.id, "--submit")
    usleep(1_000_000)
    let message = try sbd.submittedMessage(s.id)
    try #require(try sbd.count("decisions_submitted", of: s.id) == 1)
    try #require(try sbd.events(s.id, "pasting", text: message).isEmpty, "hold-paste let the paste start")
    try #require(sbd.stubInputCount(decisionsLead) == 0, "hold-paste let the paste through")
    sbd.killSbd()
    try sbd.release("hold-paste")
    try sbd.startSbd()

    try sbd.waitFor("the restarted sbd to paste the submit") { sbd.stubInputCount(decisionsLead) == 1 }
    try sbd.waitFor("delivered") { try !sbd.events(s.id, "delivered", text: message).isEmpty }
    let restored = try sbd.get(s.id)
    #expect(restored.decisionsSent == true)
    let again = try sbd.run(["decide", s.id, "--submit"])
    #expect(again.status != 0, "a second submit was accepted: \(again.stdout)")
    #expect(again.stderr.contains("already got your answers to these decisions"), "\(again.stderr)")
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the decisions") { $0.lastReply?.hasPrefix("Done: My decisions") == true }
    #expect(sbd.settledStubInputCount(decisionsLead) == 1)
    #expect(try sbd.decisionMessages(s.id).count == 1)
  }

  /// The stub's turn writes the transcript line while sbd is down, so its
  /// hooks reach no sbd and the log has no UserPromptSubmit for the message.
  /// Only the transcript shows that the paste landed.
  @Test func aPasteThatLandedBeforeTheKillIsMarkedDeliveredFromTheTranscript() throws {
    let sbd = try Instance()
    let (s, message) = try sbd.submitKilledBeforeDelivered()
    sbd.hold("report")
    try sbd.waitFor("the stub to write the message to the transcript") { sbd.transcriptContains(s, decisionsLead) }

    try sbd.startSbd()

    let prompts = try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" && $0.data["prompt"]?.string == message }
    try #require(prompts.isEmpty, "a hook of the held turn reached sbd")
    try sbd.waitFor("delivered") { try sbd.events(s.id, "delivered", text: message).count == 1 }
    #expect(try sbd.events(s.id, "delivery_unknown", text: message).isEmpty)
    #expect(try sbd.decisionsDelivery(s.id) == "delivered")
    #expect(sbd.settledStubInputCount(decisionsLead) == 1)
  }

  /// The stub read the paste but holds its turn, so the transcript lacks the
  /// message. sbd can't tell whether claude got it. Any paste after the
  /// restart waits in the terminal until the held turn ends, so the count
  /// after the reply shows every paste.
  @Test func aPasteWithoutATranscriptLineIsReportedUnknownAndNotPastedAgain() throws {
    let sbd = try Instance()
    let (s, message) = try sbd.submitKilledBeforeDelivered()

    try sbd.startSbd()

    try sbd.waitFor("delivery_unknown") { try sbd.events(s.id, "delivery_unknown", text: message).count == 1 }
    #expect(try sbd.events(s.id, "delivered", text: message).isEmpty)
    #expect(try sbd.decisionsDelivery(s.id) == "unknown")
    let again = try sbd.run(["decide", s.id, "--submit"])
    #expect(again.status != 0, "a second submit was accepted: \(again.stdout)")
    sbd.hold("report")
    try sbd.waitFor(s.id, "the reply to the held turn") { $0.lastReply?.hasPrefix("Done: My decisions") == true }
    #expect(sbd.settledStubInputCount(decisionsLead) == 1)
  }

  /// The resend's paste waits in the terminal behind the held turn. Once the
  /// stub reads both, the session got the message twice: the paste from
  /// before the kill and the one resend.
  @Test func resendSendsAnUnknownDeliveryOnceAndThenRefuses() throws {
    let sbd = try Instance()
    let (s, message) = try sbd.submitKilledBeforeDelivered()
    try sbd.startSbd()
    try sbd.waitFor("delivery_unknown") { try !sbd.events(s.id, "delivery_unknown", text: message).isEmpty }

    try sbd.sb("decide", s.id, "--resend")

    let again = try sbd.run(["decide", s.id, "--resend"])
    #expect(again.status != 0, "a second resend was accepted: \(again.stdout)")
    #expect(try sbd.events(s.id, "sent", text: message).count == 2)
    sbd.hold("report")
    try sbd.waitFor("the stub to read the resend") { sbd.stubInputCount(decisionsLead) >= 2 }
    try sbd.waitFor("the resend's delivered") { try !sbd.events(s.id, "delivered", text: message).isEmpty }
    #expect(sbd.settledStubInputCount(decisionsLead) == 2)
    #expect(try sbd.decisionsDelivery(s.id) == "delivered")
  }

  /// Each case refuses before anything was sent, so one `sent` event at most stays.
  @Test(arguments: ResendRefusal.allCases)
  func resendRefusesUnlessTheDeliveryIsUnknown(_ refusal: ResendRefusal) throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    try refusal.arrange(sbd, s)
    let sent = try sbd.decisionMessages(s.id).count

    let r = try sbd.run(["decide", s.id, "--resend"])

    #expect(r.status != 0, "the resend was accepted: \(r.stdout)")
    #expect(r.stderr.contains("resend"), "the refusal does not come from the resend: \(r.stderr)")
    #expect(try sbd.decisionMessages(s.id).count == sent)
  }

  /// sbd can't start the submit's transaction, so it refuses the submit
  /// before anything goes out, and the answers stay for a later submit.
  @Test func aSubmitThatCantStoreItsEventsSendsNothing() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)

    let r = try sbd.whileTheLogIsLocked { try sbd.run(["decide", s.id, "--submit"]) }

    #expect(r.status != 0, "the submit was accepted: \(r.stdout)")
    #expect(sbd.settledStubInputCount(decisionsLead) == 0)
    #expect(try sbd.decisionMessages(s.id).isEmpty)
    #expect(try sbd.decisionList(s.id).message != nil)
    try sbd.sb("decide", s.id, "--submit")
    try sbd.waitFor("the submit's paste") { sbd.stubInputCount(decisionsLead) == 1 }
    #expect(sbd.settledStubInputCount(decisionsLead) == 1)
  }

  /// claude gets nothing until the transaction that records the submit
  /// commits. A stopped claude therefore starts without the answers as its
  /// prompt, and they arrive as a paste after SessionStart.
  @Test func aSubmitToAStoppedClaudeStartsItWithoutThePrompt() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()
    try sbd.answerThreeDecisions(s.id)
    try sbd.stopClaude(s.id)
    let launches = sbd.stubArgs().count

    #expect(try sbd.sb("decide", s.id, "--submit") == "queued\n")

    try sbd.waitFor("the submit's paste", timeout: 20) { sbd.stubInputCount(decisionsLead) == 1 }
    let args = sbd.stubArgs().dropFirst(launches)
    #expect(!args.isEmpty, "claude did not start")
    #expect(!args.contains { $0.contains(decisionsLead) }, "claude started with the answers as its prompt")
    #expect(try sbd.count("decisions_submitted", of: s.id) == 1)
    #expect(sbd.settledStubInputCount(decisionsLead) == 1)
  }

  /// The app's Send again calls the `decision-resend` op instead of the CLI.
  @Test func theResendOpSendsAnUnknownDeliveryAgain() throws {
    let sbd = try Instance()
    let (s, message) = try sbd.submitKilledBeforeDelivered()
    try sbd.startSbd()
    try sbd.waitFor("delivery_unknown") { try !sbd.events(s.id, "delivery_unknown", text: message).isEmpty }

    _ = try sbd.client.call("decision-resend", ["session": .string(s.id)])

    #expect(try sbd.events(s.id, "sent", text: message).count == 2)
  }
}

/// A state of the decisions submit in which a resend has nothing uncertain to send.
enum ResendRefusal: String, CaseIterable, CustomStringConvertible {
  case nothingSubmitted
  /// `hold-delivered` keeps the submit's paste from recording `delivered`.
  case sending
  case delivered

  var description: String { rawValue }

  func arrange(_ sbd: Instance, _ s: SessionSummary) throws {
    switch self {
    case .nothingSubmitted: break
    case .sending:
      // The stub's hold keeps the prompt from landing, so the item still shows the submitted decisions.
      sbd.hold("hold-delivered")
      sbd.hold("hold")
      try sbd.sb("decide", s.id, "--submit")
      try #require(try sbd.decisionsDelivery(s.id) == "sending")
    case .delivered:
      try sbd.sb("decide", s.id, "--submit")
      try sbd.waitFor(s.id, "the reply to the decisions") { $0.lastReply?.hasPrefix("Done: My decisions") == true }
      try #require(try !sbd.events(s.id, "delivered", text: try sbd.submittedMessage(s.id)).isEmpty)
    }
  }
}

/// Every send gets the same guarantee as a decisions submit, whether sbd
/// pastes it at once or queues it behind a turn.
@Suite(.blocking(timeLimit: .seconds(120))) struct SendDeliveryTests {
  /// How the message reached the paste queue.
  enum Path: String, CaseIterable, CustomStringConvertible {
    /// claude is idle, so `send` pastes at once.
    case direct
    /// A turn runs, so `send` queues the message and pastes it after Stop.
    case queued

    var description: String { rawValue }

    /// A session in the state that sends the message down this path.
    func session(_ sbd: Instance) throws -> SessionSummary {
      switch self {
      case .direct:
        // sbd pastes at once only 1.5 s after SessionStart.
        let s = try sbd.endedSession()
        let start = try #require(try sbd.events(s.id).last { $0.kind == "SessionStart" }?.t)
        try sbd.waitFor("claude's prompt to settle") { try sbd.now() - start >= 1600 }
        return s
      case .queued:
        let s = try sbd.new(prompt: "slow 4")
        return try sbd.waitFor(s.id, "the turn") { $0.state == .working }
      }
    }

    /// Waits until sbd has handed the message to the paste queue. A queued
    /// message goes there after the slow turn's Stop.
    func waitForPasteQueue(_ sbd: Instance, _ s: SessionSummary) throws {
      guard self == .queued else { return }
      try sbd.waitFor("the slow turn's Stop", timeout: 20) { try sbd.count("Stop", of: s.id) >= 1 }
    }
  }

  /// sbd never recorded `pasting`, so the restarted sbd pastes the message
  /// again on its own, without waiting for a hook.
  @Test(arguments: Path.allCases)
  func aSendKilledBeforeItsPasteReachesTheSessionOnce(_ path: Path) throws {
    let sbd = try Instance()
    let s = try path.session(sbd)
    sbd.hold("hold-paste")
    let text = "sent before the kill"

    let delivery = try sbd.sb("send", s.id, text)
    try #require(delivery == (path == .direct ? "pasted\n" : "queued\n"), "sbd sent it another way: \(delivery)")
    try path.waitForPasteQueue(sbd, s)
    usleep(1_000_000)
    try #require(try sbd.events(s.id, "pasting", text: text).isEmpty, "hold-paste let the paste start")
    try #require(sbd.stubInputCount(text) == 0, "hold-paste let the paste through")
    sbd.killSbd()
    try sbd.release("hold-paste")
    try sbd.startSbd()

    try sbd.waitFor(s.id, "the message's reply", timeout: 20) { $0.lastReply == "Done: \(text)" }
    #expect(sbd.settledStubInputCount(text) == 1)
  }

  /// The paste landed and claude took the turn while `delivered` waited.
  @Test func aQueuedPasteThatLandedIsNotPastedAgainAfterAKill() throws {
    let sbd = try Instance()
    let s = try Path.queued.session(sbd)
    sbd.hold("hold-delivered")
    let text = "queued before the kill"
    let before = sbd.completePastes()

    #expect(try sbd.sb("send", s.id, text) == "queued\n")
    try sbd.waitForCompletePaste(after: before)
    try sbd.waitFor("the transcript line") { sbd.transcriptContains(s, text) }
    try #require(try sbd.events(s.id, "pasting", text: text).count == 1, "sbd records pasting before the paste")
    sbd.killSbd()
    try sbd.release("hold-delivered")
    try sbd.startSbd()

    try sbd.waitFor("delivered") { try sbd.events(s.id, "delivered", text: text).count == 1 }
    #expect(try sbd.events(s.id, "delivery_unknown", text: text).isEmpty)
    #expect(sbd.settledStubInputCount(text) == 1)
  }

  /// sbd can't store the `sent` event, so it refuses the send and pastes nothing.
  @Test func aSendThatCantStoreItsSentEventPastesNothing() throws {
    let sbd = try Instance()
    let s = try Path.direct.session(sbd)
    let text = "sent while the log is locked"

    let r = try sbd.whileTheLogIsLocked { try sbd.run(["send", s.id, text]) }

    #expect(r.status != 0, "the send was accepted: \(r.stdout)")
    #expect(sbd.settledStubInputCount(text) == 0)
    #expect(try sbd.events(s.id, "sent", text: text).isEmpty)
  }

  /// A stopped claude would start with the message as its prompt. sbd can't
  /// store the `sent` event, so it refuses the send and starts nothing.
  @Test func aSendToAStoppedClaudeThatCantStoreItsSentEventStartsNothing() throws {
    let sbd = try Instance()
    let s = try Path.direct.session(sbd)
    try sbd.stopClaude(s.id)
    let launches = sbd.stubArgs().count
    let text = "resumed while the log is locked"

    let r = try sbd.whileTheLogIsLocked { try sbd.run(["send", s.id, text]) }

    #expect(r.status != 0, "the send was accepted: \(r.stdout)")
    #expect(sbd.settledStubInputCount(text) == 0)
    #expect(!sbd.stubArgs().dropFirst(launches).contains { $0.contains(text) }, "claude started with the message")
    #expect(try sbd.events(s.id, "sent", text: text).isEmpty)
  }

  /// The `sent` event is stored, but sbd can't store `pasting` while the
  /// lock holds, so it pastes nothing. It tries again until the lock goes,
  /// and then pastes the message once.
  @Test func aPasteWaitsUntilItsPastingEventIsStored() throws {
    let sbd = try Instance()
    let s = try Path.direct.session(sbd)
    sbd.hold("hold-paste")
    let text = "pasted after the lock"
    #expect(try sbd.sb("send", s.id, text) == "pasted\n")

    try sbd.whileTheLogIsLocked {
      try sbd.release("hold-paste")
      usleep(3_500_000)
      #expect(sbd.stubInputCount(text) == 0, "sbd pasted without a stored pasting event")
    }

    try sbd.waitFor(s.id, "the message's reply", timeout: 20) { $0.lastReply == "Done: \(text)" }
    #expect(try sbd.events(s.id, "pasting", text: text).count == 1)
    #expect(sbd.settledStubInputCount(text) == 1)
  }

  /// The transcript already holds the text from an earlier send that
  /// arrived. Only a line written after this send's `sent` event shows that
  /// this paste landed, and the stub's hold keeps that line from being written.
  @Test func anEarlierCopyOfTheTextInTheTranscriptDoesNotMarkALaterPasteDelivered() throws {
    let sbd = try Instance()
    let s = try Path.direct.session(sbd)
    let text = "the same words twice"
    try sbd.sb("send", s.id, text)
    try sbd.waitFor(s.id, "the first copy's reply") { $0.lastReply == "Done: \(text)" }
    try #require(sbd.transcriptContains(s, text))
    let deliveredBefore = try sbd.events(s.id, "delivered", text: text).count
    sbd.hold("hold-delivered")
    sbd.hold("hold")
    let before = sbd.completePastes()

    try sbd.sb("send", s.id, text)
    try sbd.waitForCompletePaste(after: before)
    try #require(try sbd.events(s.id, "pasting", text: text).count == 2, "sbd records pasting before the paste")
    sbd.killSbd()
    try sbd.release("hold-delivered")
    try sbd.startSbd()

    try sbd.waitFor("delivery_unknown") { try sbd.events(s.id, "delivery_unknown", text: text).count == 1 }
    #expect(try sbd.events(s.id, "delivered", text: text).count == deliveredBefore)
  }
}
