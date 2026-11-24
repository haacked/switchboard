import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// What a conversation holds when the user asks to end it. Each case stores its waits, pause, and schedules the
/// way sbd stores them on a `Session`, so the parity test can compare the app's `drop` with sbd's guard.
enum EndShape: CaseIterable, Sendable, CustomTestStringConvertible {
  case nothing, ownWaits, pauseWithCondition, pauseWithoutCondition, schedules, handedOnly, everything

  var testDescription: String { "\(self)" }

  var waits: [Wait]? {
    switch self {
    case .ownWaits, .everything: [EndFixtures.mergeWait, EndFixtures.dateWait]
    default: nil
    }
  }

  var pause: Pause? {
    switch self {
    case .pauseWithCondition, .everything: EndFixtures.conditionalPause
    case .pauseWithoutCondition: Pause(by: .you, reason: "Lunch", since: 1)
    default: nil
    }
  }

  var schedules: [Schedule]? {
    switch self {
    case .schedules, .everything: [EndFixtures.schedule]
    default: nil
    }
  }

  var handed: [Wait]? {
    switch self {
    case .handedOnly, .everything: [EndFixtures.handedWait]
    default: nil
    }
  }
}

enum EndFixtures {
  static let name = "Cache work"

  static let mergeWait = Wait(id: "w1", kind: .merge, pr: .init(number: 12), by: .claude, created: 1)
  static let dateWait = Wait(id: "w2", kind: .date, until: 1_794_377_400_000, by: .you, created: 1)
  static let schedule = Schedule(
    id: "s1", prompt: "Check the flaky tests", every: 3_600_000, next: 0, by: .you, created: 1)
  static let conditionalPause = Pause(
    by: .you, since: 1, until: Wait(id: "p1", kind: .merge, pr: .init(number: 90), created: 1))

  static var handedWait: Wait {
    var w = Wait(id: "h1", kind: .merge, pr: .init(repository: "PostHog/posthog", number: 77), by: .claude, created: 1)
    w.handedFrom = .init(id: "m", name: name)
    return w
  }

  static var secondHandedWait: Wait {
    var w = Wait(id: "h2", kind: .ci, pr: .init(repository: "PostHog/posthog", number: 78), by: .claude, created: 1)
    w.handedFrom = .init(id: "m", name: name)
    return w
  }

  /// Conversation `m` named `name`, with the given own waits, pause, schedules, handed waits, and cards.
  static func conversation(
    waits: [Wait] = [], pause: Pause? = nil, schedules: [Schedule]? = nil, handed: [Wait]? = nil,
    cards: [Card] = []
  ) -> SessionSummary {
    var s = needsItem("m", manager: true, state: .waiting)
    s.name = name
    s.waits = waits
    s.pause = pause
    s.schedules = schedules
    s.handedWaits = handed
    s.cards = cards
    return s
  }

  /// The session as sbd stores it for `shape`.
  static func session(_ shape: EndShape) -> Session {
    var session = Session(id: "m", name: name, cwd: "/tmp", claudeSessionId: "m", created: 0)
    session.manager = true
    session.waits = shape.waits
    session.pause = shape.pause
    session.schedules = shape.schedules
    return session
  }

  /// The summary that sbd builds from `session`, as `Service.summary` and `addConversationFields` fill it.
  static func summary(of session: Session, handed: [Wait]?) -> SessionSummary {
    conversation(
      waits: session.waits ?? [], pause: session.pause,
      schedules: session.schedules?.isEmpty == false ? session.schedules : nil, handed: handed)
  }
}

@MainActor
@Suite struct EndConversationTests {
  // MARK: The confirmation's text

  @Test func theTitleNamesTheConversation() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .end)

    #expect(text.title.contains(EndFixtures.name))
  }

  @Test func theDestructiveButtonEndsTheConversation() {
    #expect(ConversationRemovalText(EndFixtures.conversation(), .end).button.hasPrefix("End"))
  }

  @Test func withNoWaitsTheMessageSaysTheTranscriptStaysOnDiskAndNothingIsDropped() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .end)

    #expect(text.message.localizedCaseInsensitiveContains("transcript"))
    #expect(text.drop == [])
  }

  @Test func withNoHandedWaitsTheMessageDoesNotMentionTheOperator() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .end)

    #expect(!text.message.contains(Manager.operatorName))
  }

  @Test func oneOwnWaitIsListedByItsLineAndDropped() {
    let text = ConversationRemovalText(EndFixtures.conversation(waits: [EndFixtures.mergeWait]), .end)

    #expect(text.message.contains(EndFixtures.mergeWait.line))
    #expect(text.drop == ["w1"])
  }

  @Test func twoOwnWaitsAndAScheduleAreEachListedAndDroppedWaitsFirst() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(
        waits: [EndFixtures.mergeWait, EndFixtures.dateWait], schedules: [EndFixtures.schedule]), .end)

    #expect(text.message.contains(EndFixtures.mergeWait.line))
    #expect(text.message.contains(EndFixtures.dateWait.line))
    #expect(text.message.contains("Loop: \(EndFixtures.schedule.prompt)"))
    #expect(text.drop == ["w1", "w2", "s1"])
  }

  @Test func handedWaitsAreCountedAsTheOperatorsAndNotListedOrDropped() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(handed: [EndFixtures.handedWait, EndFixtures.secondHandedWait]), .end)

    #expect(text.drop == [])
    #expect(text.message.contains(Manager.operatorName))
    #expect(text.message.contains("2 waits"))
    #expect(!text.message.contains(EndFixtures.handedWait.line))
    #expect(!text.message.contains(EndFixtures.secondHandedWait.line))
  }

  @Test func ownAndHandedWaitsDropOnlyTheOwnOne() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(waits: [EndFixtures.mergeWait], handed: [EndFixtures.handedWait]), .end)

    #expect(text.drop == ["w1"])
  }

  @Test func aPauseConditionIsListedByThePausesLine() {
    let text = ConversationRemovalText(EndFixtures.conversation(pause: EndFixtures.conditionalPause), .end)

    #expect(text.message.contains(EndFixtures.conditionalPause.line))
  }

  @Test func aPauseConditionIsDroppedAfterTheWaitsAndBeforeTheSchedules() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(
        waits: [EndFixtures.mergeWait], pause: EndFixtures.conditionalPause, schedules: [EndFixtures.schedule]), .end)

    #expect(text.drop == ["w1", "p1", "s1"])
  }

  @Test func aPauseWithoutAConditionDropsNothing() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(pause: Pause(by: .you, reason: "Lunch", since: 1)), .end)

    #expect(text.drop == [])
  }

  @Test func openCardsAreCountedAsRequestsThatClose() throws {
    let cards = [
      try cardFixture(1, session: "m", kind: .permission), try cardFixture(2, session: "m", kind: .question),
    ]

    let text = ConversationRemovalText(EndFixtures.conversation(cards: cards), .end)

    #expect(text.message.contains("2 open requests"))
  }

  @Test func oneOpenCardIsCountedInTheSingular() throws {
    let text = ConversationRemovalText(
      EndFixtures.conversation(cards: [try cardFixture(1, session: "m", kind: .mcp)]), .end)

    #expect(text.message.contains("1 open request"))
    #expect(!text.message.contains("1 open requests"))
  }

  @Test func withNoCardsTheMessageDoesNotMentionOpenRequests() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .end)

    #expect(!text.message.contains("open request"))
  }

  /// sbd's guard refuses the end unless `drop` names every id in the session's `ownItems`. The app reads the
  /// summary's `ownItems`, which has to hold exactly those ids, so it neither drops a handed wait nor leaves the
  /// guard an id to refuse on.
  @Test(arguments: EndShape.allCases)
  func dropMatchesTheIdsThatSbdsGuardRefusesOn(_ shape: EndShape) {
    let session = EndFixtures.session(shape)
    let guarded = session.ownItems.map(\.id)

    let text = ConversationRemovalText(EndFixtures.summary(of: session, handed: shape.handed), .end)

    #expect(text.drop == guarded)
  }

  // MARK: Ending

  @Test func endConversationSendsManagerEndWithNewAndTheDropIds() async {
    let sent = await firstRequest {
      $0.endConversation(EndFixtures.conversation(), new: true, drop: ["w1", "p1", "s1"])
    }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "new": true, "drop": ["w1", "p1", "s1"]])
  }

  @Test func endConversationWithNothingToDropNamesNoIdsAndNoCaller() async {
    let sent = await firstRequest { $0.endConversation(EndFixtures.conversation(), new: true, drop: []) }

    #expect(sent.op == "manager-end")
    #expect(sent.args["session"] == "m")
    #expect(sent.args["new"] == true)
    #expect(sent.args["drop"] == nil || sent.args["drop"] == [])
    #expect(sent.args["caller"] == nil)
  }

  @Test func aSuccessfulEndSelectsTheNewConversation() async throws {
    let conversation = EndFixtures.conversation()
    let model = appliedModel([conversation])
    let answer: JSON = [
      "ended": "m", "name": .string(EndFixtures.name), "transcript": "/tmp/m.jsonl", "claudeSessionId": "m",
      "handed": [], "dropped": [], "started": try JSON(encoding: needsItem("m2", manager: true)),
    ]
    model.send = { op, _ in op == "manager-end" ? answer : .null }
    model.selection = "m"

    model.endConversation(conversation, new: true, drop: [])

    await settle { model.selection == "m2" }
    #expect(model.selection == "m2")
  }

  @Test func aRefusedEndShowsTheBannerAndKeepsTheConversationSelected() async {
    let refusal =
      "Cache work has 1 message on its way to it that removing it would drop:\n  Rebase first.\n"
      + "They reach claude once it is ready for them. Try again then."
    let conversation = EndFixtures.conversation()
    let (model, _) = recordingModel { op, _ in op == "manager-end" ? refusal : nil }
    model.apply(.success([conversation]), followups: nil)
    model.selection = "m"

    model.endConversation(conversation, new: true, drop: [])
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains(refusal) == true)
    #expect(model.selection == "m")
  }

  // MARK: The hint

  @Test func dismissEndHintSendsManagerHintWithDismissAndNoCaller() async {
    let sent = await firstRequest { $0.dismissEndHint("m") }

    #expect(sent.op == "manager-hint")
    #expect(sent.args == ["session": "m", "dismiss": true])
  }
}
