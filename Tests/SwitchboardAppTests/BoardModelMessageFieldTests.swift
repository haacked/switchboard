import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// ⇧⌘E reveals the Message Claude field under the terminal view that shows now. The menu item is enabled only
/// while `messageFieldTarget` names a session whose `SessionView` shows, so it never reveals a field that no view
/// draws, and it never navigates.
@MainActor
@Suite struct BoardModelMessageField {
  /// Where the window shows the session.
  enum Place: CaseIterable {
    case selection, inboxSummary, inboxTerminal, board, issues, loops
  }

  /// The sessions the target tests cover. A chat and a Manager come with the Inbox's Terminal toggle off and on,
  /// and the toggle must not change what their own view shows.
  enum Kind: CaseIterable {
    case work, chatToggleOff, chatToggleOn, managerToggleOff, managerToggleOn
    case docketRow, followupNotStarted, unstartedFollowupWithFolder, cleanedUp

    func session(_ id: String) -> SessionSummary {
      switch self {
      case .work: return needsItem(id)
      case .chatToggleOff, .chatToggleOn: return chatItem(id, group: "g1")
      case .managerToggleOff, .managerToggleOn: return needsItem(id, manager: true)
      case .docketRow: return docketSession(id)
      case .followupNotStarted: return unstartedFollowup(id)
      case .unstartedFollowupWithFolder:
        var s = needsItem(id)
        s.followup = Followup(prompt: "p")
        return s
      case .cleanedUp:
        var s = needsItem(id, state: .done)
        s.cleanup = CleanupStatus(state: .removed)
        return s
      }
    }

    /// The Terminal toggle while the session is selected. The Inbox's toggle is its place's.
    var toggle: Bool? {
      switch self {
      case .chatToggleOff, .managerToggleOff: return false
      case .chatToggleOn, .managerToggleOn: return true
      default: return nil
      }
    }

    /// Whether the session has a Claude terminal for its `SessionView` to show.
    var hasClaudeTerminal: Bool {
      switch self {
      case .work, .chatToggleOff, .chatToggleOn, .managerToggleOff, .managerToggleOn: return true
      case .docketRow, .followupNotStarted, .unstartedFollowupWithFolder, .cleanedUp: return false
      }
    }
  }

  /// Whether `place` draws the session's `SessionView`. A selected session draws it whatever the Terminal toggle
  /// says. The Inbox in terminal mode draws it for any session with a Claude terminal.
  nonisolated static func showsTerminalView(_ kind: Kind, at place: Place) -> Bool {
    switch place {
    case .selection: return kind.hasClaudeTerminal
    case .inboxTerminal: return kind.hasClaudeTerminal
    case .inboxSummary, .board, .issues, .loops: return false
    }
  }

  /// Every kind and place where no `SessionView` shows.
  nonisolated static let untargeted: [(Kind, Place)] = Kind.allCases.flatMap { kind in
    Place.allCases.filter { !showsTerminalView(kind, at: $0) }.map { (kind, $0) }
  }

  /// A model whose current target at `place` is `target`. The session is in the Inbox list.
  static func model(_ target: SessionSummary, at place: Place, toggle: Bool? = nil) throws -> BoardModel {
    var target = target
    if place == .loops { target.schedules = [scheduleFixture("rl")] }
    let model = appliedModel([target, needsItem("other")])
    switch place {
    case .selection:
      model.selection = target.id
      model.showingTerminal = toggle ?? false
    case .inboxSummary, .inboxTerminal:
      model.show(.inbox)
      model.inboxFocus = target.id
      model.showingTerminal = place == .inboxTerminal
      try #require(model.currentInboxItem == target.id)
    case .board:
      model.show(.board)
      model.boardGrid = BoardGrid(lanes: [[["other"], [target.id]]])
      model.boardFocus = target.id
      try #require(model.currentBoardCard == target.id)
    case .issues:
      model.show(.issues)
    case .loops:
      model.show(.loops)
      model.loopFocus = "rl"
    }
    return model
  }

  static func model(_ kind: Kind, at place: Place) throws -> BoardModel {
    try model(kind.session("a"), at: place, toggle: place == .selection ? kind.toggle : nil)
  }

  /// Everything a reveal must leave alone, and the two ids it sets.
  struct Snapshot: Equatable {
    var selection: String?
    var mainView: MainView
    var showingTerminal: Bool
    var inboxFocus: String?
    var boardFocus: String?
    var terminalFocus: String?
    var revealedMessageField: String?
    var messageFieldFocus: String?

    @MainActor init(_ model: BoardModel) {
      selection = model.selection
      mainView = model.mainView
      showingTerminal = model.showingTerminal
      inboxFocus = model.inboxFocus
      boardFocus = model.boardFocus
      terminalFocus = model.terminalFocus
      revealedMessageField = model.revealedMessageField
      messageFieldFocus = model.messageFieldFocus
    }
  }

  // MARK: messageFieldTarget

  @Test(arguments: [false, true])
  func aSelectedWorkSessionIsTheTarget(_ toggle: Bool) throws {
    let model = try Self.model(needsItem("a"), at: .selection, toggle: toggle)

    #expect(model.messageFieldTarget?.id == "a")
  }

  /// The Terminal toggle belongs to the Inbox, so ⇧⌘E reaches a selected conversation with the toggle off or on.
  @Test(arguments: [Kind.chatToggleOff, .chatToggleOn, .managerToggleOff, .managerToggleOn])
  func aSelectedChatOrManagerIsTheTarget(_ kind: Kind) throws {
    #expect(try Self.model(kind, at: .selection).messageFieldTarget?.id == "a")
  }

  @Test func theInboxInSummaryModeHasNoTarget() throws {
    #expect(try Self.model(needsItem("a"), at: .inboxSummary).messageFieldTarget == nil)
  }

  @Test func theInboxInTerminalModeTargetsTheCurrentItem() throws {
    #expect(try Self.model(needsItem("a"), at: .inboxTerminal).messageFieldTarget?.id == "a")
  }

  /// `terminalTarget` names the focused card, but the Board draws no `SessionView`.
  @Test func theBoardHasNoTarget() throws {
    let model = try Self.model(needsItem("a"), at: .board)
    try #require(model.terminalTarget?.id == "a")

    #expect(model.messageFieldTarget == nil)
  }

  @Test func theIssuesViewHasNoTarget() throws {
    #expect(try Self.model(needsItem("a"), at: .issues).messageFieldTarget == nil)
  }

  /// The Loops view's current row names a session, but the view draws no `SessionView`.
  @Test func theLoopsViewHasNoTarget() throws {
    let model = try Self.model(needsItem("a"), at: .loops)
    try #require(model.currentLoop?.session.id == "a")

    #expect(model.messageFieldTarget == nil)
  }

  @Test(arguments: [Kind.docketRow, .followupNotStarted, .unstartedFollowupWithFolder, .cleanedUp])
  func aSessionWithNoClaudeTerminalHasNoTarget(_ kind: Kind) throws {
    #expect(try Self.model(kind, at: .selection).messageFieldTarget == nil)
  }

  @Test func anUnlistedSelectionHasNoTarget() {
    let model = appliedModel([needsItem("a")])
    model.selectUnlisted("new")

    #expect(model.messageFieldTarget == nil)
  }

  @Test func anEmptyInboxHasNoTarget() {
    let model = offlineModel()
    model.show(.inbox)
    model.showingTerminal = true

    #expect(model.messageFieldTarget == nil)
  }

  /// The menu item is enabled exactly where a `SessionView` with a Claude terminal shows.
  @Test(arguments: Kind.allCases, Place.allCases)
  func theTargetIsTheSessionExactlyWhereItsTerminalViewShows(_ kind: Kind, _ place: Place) throws {
    let model = try Self.model(kind, at: place)

    #expect(model.messageFieldTarget?.id == (Self.showsTerminalView(kind, at: place) ? "a" : nil))
  }

  // MARK: revealMessageField

  @Test func revealSetsTheRevealToTheTarget() throws {
    let model = try Self.model(needsItem("a"), at: .selection)

    model.revealMessageField()

    #expect(model.revealedMessageField == "a")
  }

  @Test func revealAsksTheTargetsFieldToTakeFocus() throws {
    let model = try Self.model(needsItem("a"), at: .selection)

    model.revealMessageField()

    #expect(model.messageFieldFocus == "a")
  }

  /// A draft already shows the field. The menu item still focuses it.
  @Test func revealWithADraftThatAlreadyShowsTheFieldStillFocusesIt() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.messageDraft(for: session).text = "Rebase onto main"

    model.revealMessageField()

    #expect(model.messageFieldFocus == "a")
  }

  /// The reveal shows the field in place. It changes nothing but the two ids.
  @Test(arguments: [Place.selection, .inboxTerminal])
  func revealNeverNavigates(_ place: Place) throws {
    let model = try Self.model(needsItem("a"), at: place)
    var expected = Snapshot(model)
    expected.revealedMessageField = "a"
    expected.messageFieldFocus = "a"

    model.revealMessageField()

    #expect(Snapshot(model) == expected)
  }

  @Test(arguments: untargeted)
  func revealWithoutATargetChangesNothing(_ kind: Kind, _ place: Place) throws {
    let model = try Self.model(kind, at: place)
    let before = Snapshot(model)

    model.revealMessageField()

    #expect(Snapshot(model) == before)
  }

  // MARK: hideMessageField

  @Test func hideClearsTheReveal() throws {
    let model = try Self.model(needsItem("a"), at: .selection)
    model.revealMessageField()

    model.hideMessageField("a")

    #expect(model.revealedMessageField == nil)
  }

  /// An error alone keeps the field showing, so the field could not hide without this.
  @Test func hideClearsTheDraftsError() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.revealMessageField()
    model.messageDraft(for: session).error = "notes.txt isn't an image"

    model.hideMessageField("a")

    #expect(model.messageDraft(for: session).error == nil)
  }

  @Test func hideKeepsTheDraftsText() throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.messageDraft(for: session).text = "Rebase onto main"

    model.hideMessageField("a")

    #expect(model.messageDraft(for: session).text == "Rebase onto main")
  }

  // MARK: hideMessageFieldIfEmpty

  /// The draft is empty once sbd accepted the send and nobody typed more. `isEmpty` trims, so whitespace counts
  /// as empty. Text or an image the user added while the send was on its way keeps the field.
  @Test(arguments: [("", false, true), ("  \n", false, true), ("And rebase", false, false), ("", true, false)])
  func hideIfEmptyHidesOnlyAnEmptyDraft(_ text: String, _ image: Bool, _ hides: Bool) throws {
    let session = needsItem("a")
    let model = try Self.model(session, at: .selection)
    model.revealMessageField()
    let draft = model.messageDraft(for: session)
    draft.text = text
    if image { draft.images = [MessageField.Draft.Image(name: "shot.png", data: Data([0x89]), thumbnail: nil)] }

    model.hideMessageFieldIfEmpty("a", draft: draft)

    #expect(model.revealedMessageField == (hides ? nil : "a"))
  }

  @Test func hideReturnsKeyboardFocusToTheClaudeTerminal() throws {
    let model = try Self.model(needsItem("a"), at: .selection)
    model.revealMessageField()

    model.hideMessageField("a")

    #expect(model.terminalFocus == "a")
  }
}

/// On an Operator question, the Inbox's message field answers the Operator through the item's Reply, so the answer
/// never reaches the owner's claude (#410, Decision 49). sbd turns the `choose` into a message to the Operator.
@MainActor
@Suite struct BoardModelMessageFieldAsk {
  nonisolated static let reply = TriageOption(
    label: "Reply", action: .reply, placeholder: "Your answer to the operator")

  /// A session that holds the Operator's question as its Inbox item, as sbd builds it, with `options`.
  nonisolated static func askOwner(options: [TriageOption] = [reply]) -> SessionSummary {
    var s = needsItem("k1")
    s.triage = TriageItem(
      title: "Operator: Merge #7 with an open thread?", kind: .question, summary: "Merge #7 with an open thread?",
      options: options, source: .report, ref: "report:7")
    return s
  }

  static func theOperator() -> SessionSummary {
    var s = needsItem("op", manager: true, state: .waiting)
    s.kind = .operator
    s.name = Manager.operatorName
    return s
  }

  /// Types `text` in the owner's Inbox field and submits it with `ref`, as `TriageView`'s field does.
  static func submit(
    _ text: String = "  Yes, merge it.\n", ref: String?, owner: SessionSummary = askOwner()
  ) async -> (BoardModel, SentRequests, MessageField.Draft) {
    let (model, sent) = recordingModel()
    model.apply(.success([owner, theOperator()]), followups: nil)
    let draft = model.inboxDraft(for: owner)
    draft.text = text
    draft.submit(owner.id, ref: ref, to: model)
    await settle { !sent.value.isEmpty }
    return (model, sent, draft)
  }

  /// The session view and the chat pane show the owner's own draft, so an answer typed on the ask must not be in it.
  @Test func anAnswerOnAnAskLeavesTheOwnersOwnDraftEmpty() {
    let (model, _) = recordingModel()
    let owner = Self.askOwner()
    model.apply(.success([owner, Self.theOperator()]), followups: nil)

    model.inboxDraft(for: owner).text = "Yes, merge it."

    #expect(model.messageDraft(for: owner).text.isEmpty)
  }

  /// Once the ask closes, the Inbox field shows the owner's own draft, which never received the unsent answer.
  @Test func anAnswerOnAnAskThatClosesNeverReachesTheOwnersDraft() {
    let (model, _) = recordingModel()
    var owner = Self.askOwner()
    model.apply(.success([owner, Self.theOperator()]), followups: nil)
    model.inboxDraft(for: owner).text = "Yes, merge it."

    owner.triage = nil
    model.apply(.success([owner, Self.theOperator()]), followups: nil)

    #expect(model.inboxDraft(for: owner).text.isEmpty)
    #expect(model.messageDraft(for: owner).text.isEmpty)
  }

  @Test func theFieldOnAnAskSendsAChooseForTheOwnersItem() async throws {
    let (_, sent, _) = await Self.submit(ref: "report:7")

    let request = try #require(sent.value.first)
    #expect(request.op == "choose")
    #expect(request.args["session"] == "k1")
    #expect(request.args["ref"] == "report:7")
  }

  @Test func theChooseCarriesTheReplyOptionAndTheTrimmedText() async throws {
    let (_, sent, _) = await Self.submit(ref: "report:7")

    let request = try #require(sent.value.first { $0.op == "choose" })
    #expect(request.args["option"] == "1")
    #expect(request.args["text"] == "Yes, merge it.")
  }

  /// The field finds the Reply option by its action, wherever it sits in the item's options.
  @Test func theChooseNamesTheReplyOptionByItsPlace() async throws {
    let owner = Self.askOwner(options: [TriageOption(label: "Dismiss", action: .dismiss), Self.reply])

    let (_, sent, _) = await Self.submit(ref: "report:7", owner: owner)

    let request = try #require(sent.value.first { $0.op == "choose" })
    #expect(request.args["option"] == "2")
  }

  @Test func theFieldOnAnAskSendsNothingToTheOwner() async {
    let (_, sent, _) = await Self.submit(ref: "report:7")
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(!sent.ops.contains("send"))
  }

  @Test func theFieldEmptiesOnceSbdAcceptsTheReply() async {
    let (_, _, draft) = await Self.submit(ref: "report:7")
    await settle { draft.text.isEmpty }

    #expect(draft.text.isEmpty)
  }

  /// Only an ask's ref routes to the Operator. The session view's field passes no ref, and a held wait has no Reply,
  /// so both still message the session's claude.
  @Test(arguments: [nil, "held:w1", "summary:3", "card:1"] as [String?])
  func theFieldOnAnyOtherRefSendsToTheSession(_ ref: String?) async throws {
    let (_, sent, _) = await Self.submit(ref: ref)

    let request = try #require(sent.value.first)
    #expect(request.op == "send")
    #expect(request.args["session"] == "k1")
  }

  /// An ask's ref never falls back to a message to the owner. A ref that is no longer the owner's item, an item with
  /// no Reply, or a draft with images sends nothing and says why.
  @Test func theFieldOnAnAskThatIsNoLongerTheItemSendsNothing() async {
    let (model, sent) = recordingModel()
    let owner = Self.askOwner()
    model.apply(.success([owner, Self.theOperator()]), followups: nil)
    let draft = model.inboxDraft(for: owner)
    draft.text = "Yes"

    draft.submit(owner.id, ref: "report:6", to: model)
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(sent.value.isEmpty)
    #expect(draft.error != nil)
    #expect(draft.text == "Yes")
  }

  @Test func theFieldOnAnAskWithoutAReplySendsNothing() async {
    let (model, sent) = recordingModel()
    let owner = Self.askOwner(options: [TriageOption(label: "Dismiss", action: .dismiss)])
    model.apply(.success([owner, Self.theOperator()]), followups: nil)
    let draft = model.inboxDraft(for: owner)
    draft.text = "Yes"

    draft.submit(owner.id, ref: "report:7", to: model)
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(sent.value.isEmpty)
    #expect(draft.error != nil)
  }

  @Test func theFieldOnAnAskRefusesImages() async {
    let (model, sent) = recordingModel()
    let owner = Self.askOwner()
    model.apply(.success([owner, Self.theOperator()]), followups: nil)
    let draft = model.inboxDraft(for: owner)
    draft.text = "See this"
    draft.images = [.init(name: "a.png", data: Data([1]), thumbnail: nil)]

    draft.submit(owner.id, ref: "report:7", to: model)
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(sent.value.isEmpty)
    #expect(draft.error != nil)
    #expect(draft.images.count == 1)
  }
}
