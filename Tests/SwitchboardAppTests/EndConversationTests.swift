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

  static let firstTodo = todoFixture("n1", "tell Alex in #flags")
  static let secondTodo = todoFixture("n2", "bump the SDK")

  /// Conversation `m` named `name`, with the given own waits, pause, schedules, handed waits, cards, and notes.
  static func conversation(
    waits: [Wait] = [], pause: Pause? = nil, schedules: [Schedule]? = nil, handed: [Wait]? = nil,
    cards: [Card] = [], notes: [Note] = []
  ) -> SessionSummary {
    var s = needsItem("m", manager: true, state: .waiting)
    s.name = name
    s.waits = waits
    s.pause = pause
    s.schedules = schedules
    s.handedWaits = handed
    s.cards = cards
    s.notes = notes
    return s
  }

  /// A conversation that holds one of each item that the confirmation lists or counts.
  static func everything() throws -> SessionSummary {
    conversation(
      waits: [mergeWait, dateWait], pause: conditionalPause, schedules: [schedule], handed: [handedWait],
      cards: [try cardFixture(1, session: "m", kind: .permission), try cardFixture(2, session: "m", kind: .question)],
      notes: [firstTodo, secondTodo])
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

  @Test func theEndMessageSaysANewConversationOpensInItsPlace() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .end)

    #expect(text.message.localizedCaseInsensitiveContains("new conversation"))
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
  @Test(arguments: EndShape.allCases, [ConversationRemovalText.Mode.end, .delete])
  func dropMatchesTheIdsThatSbdsGuardRefusesOn(_ shape: EndShape, _ mode: ConversationRemovalText.Mode) {
    let session = EndFixtures.session(shape)
    let guarded = session.ownItems.map(\.id)

    let text = ConversationRemovalText(EndFixtures.summary(of: session, handed: shape.handed), mode)

    #expect(text.drop == guarded)
  }

  // MARK: Open to-dos (Decision 9)

  @Test(arguments: [ConversationRemovalText.Mode.end, .delete])
  func withNoOpenTodoNothingIsResolved(_ mode: ConversationRemovalText.Mode) {
    let text = ConversationRemovalText(EndFixtures.conversation(notes: [noteFixture("n9", "plain")]), mode)

    #expect(text.resolve == [])
    #expect(!text.message.contains("to-do"))
  }

  @Test(arguments: [ConversationRemovalText.Mode.end, .delete])
  func openTodosAreListedAndResolved(_ mode: ConversationRemovalText.Mode) {
    let text = ConversationRemovalText(
      EndFixtures.conversation(notes: [EndFixtures.firstTodo, EndFixtures.secondTodo]), mode)

    #expect(text.resolve == ["n1", "n2"])
    #expect(text.message.contains(EndFixtures.firstTodo.text))
    #expect(text.message.contains(EndFixtures.secondTodo.text))
  }

  @Test(arguments: [ConversationRemovalText.Mode.end, .delete])
  func aResolvedTodoIsNeitherListedNorResolved(_ mode: ConversationRemovalText.Mode) {
    let done = todoFixture("n3", "ship the fix", resolved: true)

    let text = ConversationRemovalText(EndFixtures.conversation(notes: [EndFixtures.firstTodo, done]), mode)

    #expect(text.resolve == ["n1"])
    #expect(!text.message.contains(done.text))
  }

  @Test func endsButtonNamesOneTodoItResolves() {
    let text = ConversationRemovalText(EndFixtures.conversation(notes: [EndFixtures.firstTodo]), .end)

    #expect(text.button == "Resolve 1 To-do and End Conversation")
  }

  @Test func endsButtonWithoutTodosIsEndConversation() {
    #expect(ConversationRemovalText(EndFixtures.conversation(), .end).button == "End Conversation")
  }

  // MARK: The delete confirmation's text

  @Test func theDeleteTitleNamesTheConversation() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .delete)

    #expect(text.title == "Delete \(EndFixtures.name)?")
  }

  @Test func theDeleteMessageSaysTheTranscriptStaysOnDisk() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .delete)

    #expect(text.message.localizedCaseInsensitiveContains("transcript"))
  }

  @Test func theDeleteMessageSaysClaudeStops() {
    let text = ConversationRemovalText(EndFixtures.conversation(), .delete)

    #expect(text.message.localizedCaseInsensitiveContains("claude"))
  }

  /// Decision 1: a conversation has no worktree or branch, and a delete opens nothing in its place.
  @Test func theDeleteMessageNeverSaysANewConversationOpensOrNamesAWorktree() {
    let text = ConversationRemovalText(EndFixtures.conversation(notes: [EndFixtures.firstTodo]), .delete)

    #expect(!text.message.localizedCaseInsensitiveContains("new conversation"))
    #expect(!text.message.localizedCaseInsensitiveContains("in its place"))
    #expect(!text.message.localizedCaseInsensitiveContains("worktree"))
    #expect(!text.message.localizedCaseInsensitiveContains("branch"))
  }

  @Test func theDeleteButtonWithoutTodosIsDelete() {
    #expect(ConversationRemovalText(EndFixtures.conversation(), .delete).button == "Delete")
  }

  @Test func theDeleteButtonNamesTheTodosItResolves() {
    let text = ConversationRemovalText(
      EndFixtures.conversation(notes: [EndFixtures.firstTodo, EndFixtures.secondTodo]), .delete)

    #expect(text.button == "Resolve 2 To-dos and Delete")
  }

  @Test func theDeleteMessageListsEveryDropHandedWaitAndCardAsEndDoes() throws {
    let text = ConversationRemovalText(try EndFixtures.everything(), .delete)

    #expect(text.message.contains(EndFixtures.mergeWait.line))
    #expect(text.message.contains(EndFixtures.dateWait.line))
    #expect(text.message.contains(EndFixtures.conditionalPause.line))
    #expect(text.message.contains("Loop: \(EndFixtures.schedule.prompt)"))
    #expect(text.message.contains("\(Manager.operatorName) keeps following 1 wait"))
    #expect(!text.message.contains(EndFixtures.handedWait.line))
    #expect(text.message.contains("2 open requests"))
  }

  @Test func deleteAndEndDropAndResolveTheSameIds() throws {
    let s = try EndFixtures.everything()

    let end = ConversationRemovalText(s, .end)
    let delete = ConversationRemovalText(s, .delete)

    #expect(delete.drop == end.drop)
    #expect(delete.resolve == end.resolve)
  }

  // MARK: Ending

  @Test func endConversationSendsManagerEndWithNewAndTheDropIds() async {
    let sent = await firstRequest {
      $0.endConversation(EndFixtures.conversation(), new: true, drop: ["w1", "p1", "s1"])
    }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "new": true, "drop": ["w1", "p1", "s1"]])
  }

  /// Decision 9: End resolves the to-dos its confirmation lists and still opens a conversation in its place.
  @Test func endWithTodosSendsResolveAndNew() async {
    let sent = await firstRequest {
      $0.endConversation(EndFixtures.conversation(), new: true, drop: ["w1"], resolve: ["n1", "n2"])
    }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "new": true, "drop": ["w1"], "resolve": ["n1", "n2"]])
  }

  /// End's dialog sends the drop and resolve ids that it lists, with `new`.
  @Test func confirmingEndSendsTheListedDropAndResolveIdsAndNew() async throws {
    let session = try EndFixtures.everything()
    let text = ConversationRemovalText(session, .end)

    let sent = await firstRequest { text.confirm($0, session) }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "new": true, "drop": ["w1", "w2", "p1", "s1"], "resolve": ["n1", "n2"]])
  }

  /// A delete sends no `new` key, not `new: false`, and no caller.
  @Test func aDeleteSendsManagerEndWithTheDropAndResolveIdsAndNoNew() async {
    let sent = await firstRequest {
      $0.endConversation(EndFixtures.conversation(), new: false, drop: ["w1", "s1"], resolve: ["n1", "n2"])
    }

    #expect(sent.op == "manager-end")
    #expect(sent.args == ["session": "m", "drop": ["w1", "s1"], "resolve": ["n1", "n2"]])
  }

  @Test func aDeleteWithNoTodosSendsNoResolve() async {
    let sent = await firstRequest {
      $0.endConversation(EndFixtures.conversation(), new: false, drop: ["w1"], resolve: [])
    }

    #expect(sent.args == ["session": "m", "drop": ["w1"]])
  }

  @Test(arguments: [true, false])
  func theConversationIsInDeletingWhileTheRequestRuns(_ new: Bool) async {
    let conversation = EndFixtures.conversation()
    let (model, release, _) = heldModel([conversation])

    model.endConversation(conversation, new: new, drop: [])

    #expect(model.deleting.contains("m"))
    release.signal()
    await settle { !model.deleting.contains("m") }
    #expect(!model.deleting.contains("m"))
  }

  @Test(arguments: [true, false])
  func aSecondEndWhileTheFirstRunsSendsNothing(_ new: Bool) async {
    let sent = await firstRequest { model in
      let conversation = EndFixtures.conversation()
      model.endConversation(conversation, new: new, drop: [])
      model.endConversation(conversation, new: new, drop: [])
      #expect(model.deleting == ["m"])
    }

    #expect(sent.count == 1)
  }

  @Test func aSuccessfulDeleteDeselectsTheConversation() async {
    let conversation = EndFixtures.conversation()
    let (model, _) = recordingModel([conversation, needsItem("a")])
    model.selection = "m"

    model.endConversation(conversation, new: false, drop: [])
    await settle { model.selection == nil }

    #expect(model.selection == nil)
  }

  /// The Inbox can select another item while the delete runs. The deselect touches only the deleted id.
  @Test func aSuccessfulDeleteLeavesAnotherSelectionAlone() async {
    let conversation = EndFixtures.conversation()
    let (model, sent) = recordingModel([conversation, needsItem("a")])
    model.selection = "a"

    model.endConversation(conversation, new: false, drop: [])
    await sent.wait(for: "manager-end")
    await settle { !model.deleting.contains("m") }

    #expect(model.selection == "a")
  }

  @Test func aRefusedDeleteClearsDeletingAndKeepsTheSelection() async {
    let refusal = "Cache work is in a turn or runs a background job."
    let conversation = EndFixtures.conversation()
    let (model, _) = recordingModel([conversation]) { op, _ in op == "manager-end" ? refusal : nil }
    model.selection = "m"

    model.endConversation(conversation, new: false, drop: [])
    await settle { model.actionError != nil && !model.deleting.contains("m") }

    #expect(model.actionError?.contains(refusal) == true)
    #expect(!model.deleting.contains("m"))
    #expect(model.selection == "m")
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
