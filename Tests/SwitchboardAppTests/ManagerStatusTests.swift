import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct ManagerStatusTests {
  static let conversation = needsItem("m", manager: true)
  static let clear =
    "<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"

  /// A work session that conversation `parent` started, which entered `state` at `since`.
  func child(_ id: String, of parent: String? = "m", since: Int64, state: AttentionState = .working)
    -> SessionSummary
  {
    var s = needsItem(id, state: state)
    s.parent = parent
    s.since = since
    return s
  }

  func user(_ t: Int64?, _ text: String = "How is it going?") -> ChatMessage {
    ChatMessage(role: .user, text: text, t: t)
  }

  func notice(_ t: Int64) -> ChatMessage {
    ChatMessage(role: .user, text: "Switchboard: a is ready to merge.", t: t)
  }

  func assistant(_ t: Int64) -> ChatMessage { ChatMessage(role: .assistant, text: "Done.", t: t) }

  /// A model with conversation `m`, the `children`, and `m`'s log.
  func model(_ children: [SessionSummary], log: [ChatMessage]?) -> BoardModel {
    let model = appliedModel([Self.conversation] + children)
    model.chatLogs["m"] = log
    return model
  }

  /// A PostHog-only model whose conversation `m` started `hk`, a haacked session that changed after the user wrote.
  func hiddenChildModel() -> BoardModel {
    var hidden = orgSession("hk", "haacked/switchboard", state: .needsYou)
    hidden.parent = "m"
    hidden.since = 150
    let model = orgFilterModel(posthogOnly)
    model.apply(.success([Self.conversation, hidden]), followups: nil)
    model.chatLogs["m"] = [user(100)]
    return model
  }

  func changed(_ model: BoardModel) -> [String]? {
    model.managerStatus(for: Self.conversation).changed?.map(\.id)
  }

  // MARK: Counts

  @Test func countsNeedsYouReadyToMergeAndWorkingWorkSessions() {
    let model = appliedModel([
      Self.conversation,
      needsItem("n", state: .needsYou),
      needsItem("r", state: .readyToMerge),
      needsItem("w1", state: .working),
      needsItem("w2", state: .working),
      needsItem("m2", manager: true, state: .needsYou),
      chatItem("c", group: "g1", state: .working),
    ])

    let status = model.managerStatus(for: Self.conversation)

    // Needs you is `needsUser.count`, as the Dock badge and the Inbox count it, so a ready-to-merge session counts in it too.
    #expect(status.needsYou == 2)
    #expect(status.readyToMerge == 1)
    #expect(status.working == 2)
  }

  @Test(arguments: AttentionState.allCases)
  func aManagerConversationAndAChatNeverCount(_ state: AttentionState) {
    let model = appliedModel([
      Self.conversation, needsItem("m2", manager: true, state: state), chatItem("c", group: "g1", state: state),
    ])

    let status = model.managerStatus(for: Self.conversation)

    #expect(status.needsYou == 0)
    #expect(status.readyToMerge == 0)
    #expect(status.working == 0)
  }

  @Test(arguments: [AttentionState.canContinue, .readyForReview, .waiting, .done, .stale, .notStarted])
  func aWorkSessionInAnotherStateCountsNowhere(_ state: AttentionState) {
    let model = appliedModel([Self.conversation, needsItem("a", state: state)])

    let status = model.managerStatus(for: Self.conversation)

    #expect(status.needsYou == 0)
    #expect(status.readyToMerge == 0)
    #expect(status.working == 0)
  }

  @Test func theCountsMatchWhatTheInboxAndTheBoardShow() {
    let model = appliedModel([
      Self.conversation, needsItem("n"), needsItem("r", state: .readyToMerge), needsItem("w", state: .working),
    ])

    let status = model.managerStatus(for: Self.conversation)

    #expect(status.needsYou == model.needsUser.count)
    #expect(status.readyToMerge == model.workBoard.filter { $0.state == .readyToMerge }.count)
    #expect(status.working == model.workBoard.filter { $0.state == .working }.count)
  }

  // MARK: Org filter

  @Test func aSessionThatTheOrgFilterHidesDoesNotCount() {
    let model = orgFilterModel(posthogOnly)
    model.apply(
      .success([
        Self.conversation,
        orgSession("ph-n", "PostHog/posthog", state: .needsYou),
        orgSession("ph-r", "PostHog/posthog", state: .readyToMerge),
        orgSession("ph-w", "PostHog/posthog", state: .working),
        orgSession("hk-n", "haacked/switchboard", state: .needsYou),
        orgSession("hk-r", "haacked/switchboard", state: .readyToMerge),
        orgSession("hk-w", "haacked/switchboard", state: .working),
      ]), followups: nil)

    let status = model.managerStatus(for: Self.conversation)

    #expect(status.needsYou == 2)
    #expect(status.readyToMerge == 1)
    #expect(status.working == 1)
  }

  @Test func aChildThatTheOrgFilterHidesStillChanged() {
    let model = hiddenChildModel()

    let status = model.managerStatus(for: Self.conversation)

    #expect(status.needsYou == 0)
    #expect(status.changed?.map(\.id) == ["hk"])
  }

  // MARK: Changed children

  @Test func changedIsNilWhileTheLogHasNotLoaded() {
    let model = model([child("a", since: 150)], log: nil)

    #expect(changed(model) == nil)
  }

  @Test func changedIsNilForAnEmptyLog() {
    let model = model([child("a", since: 150)], log: [])

    #expect(changed(model) == nil)
  }

  @Test func changedIsNilWhenTheLogHoldsOnlyClaudesRepliesAndNotices() {
    let model = model([child("a", since: 150)], log: [notice(100), assistant(110), notice(120), assistant(130)])

    #expect(changed(model) == nil)
  }

  @Test func changedReadsTheLogOfThatConversationOnly() {
    let model = model([child("a", since: 150)], log: nil)
    model.chatLogs["m2"] = [user(100)]

    #expect(changed(model) == nil)
  }

  @Test func aChildThatChangedAfterTheUsersLastMessageChanged() {
    let model = model([child("late", since: 150), child("early", since: 50)], log: [user(100)])

    #expect(changed(model) == ["late"])
  }

  @Test func aSessionThatTheConversationDidNotStartIsNotChanged() {
    let model = model(
      [child("other", of: "m2", since: 150), child("orphan", of: nil, since: 150)], log: [user(100)])

    #expect(changed(model) == [])
  }

  @Test func aGrandchildIsNotChanged() {
    let model = model([child("a", since: 50), child("grandchild", of: "a", since: 150)], log: [user(100)])

    #expect(changed(model) == [])
  }

  @Test func aChildThatChangedAtTheSameMomentAsTheMessageIsNotChanged() {
    let model = model([child("a", since: 100)], log: [user(100)])

    #expect(changed(model) == [])
  }

  @Test func changedIsEmptyNotNilWhenNoChildChanged() {
    let model = model([child("a", since: 50)], log: [user(100)])

    #expect(changed(model) == [])
  }

  @Test func changedListsTheNewestChangeFirst() {
    let model = model(
      [child("b", since: 200), child("c", since: 300), child("a", since: 150)], log: [user(100)])

    #expect(changed(model) == ["c", "b", "a"])
  }

  @Test(arguments: AttentionState.allCases)
  func aChildInAnyStateCanHaveChanged(_ state: AttentionState) {
    let model = model([child("a", since: 150, state: state)], log: [user(100)])

    #expect(changed(model) == ["a"])
  }

  @Test func aFollowupThatTheConversationStartedCanHaveChanged() {
    var followup = unstartedFollowup("f", "PostHog/posthog")
    followup.parent = "m"
    followup.since = 150
    let model = appliedModel([Self.conversation], followups: [followup])
    model.chatLogs["m"] = [user(100)]

    #expect(changed(model) == ["f"])
  }

  // MARK: The cutoff

  @Test func aNoticeAfterTheUsersMessageDoesNotMoveTheCutoff() {
    let model = model([child("a", since: 150)], log: [user(100), notice(200)])

    #expect(changed(model) == ["a"])
  }

  @Test func aReplyAfterTheUsersMessageDoesNotMoveTheCutoff() {
    let model = model([child("a", since: 150)], log: [user(100), assistant(200)])

    #expect(changed(model) == ["a"])
  }

  @Test func aSlashCommandMovesTheCutoff() {
    let model = model(
      [child("a", since: 150), child("b", since: 350)], log: [user(100), notice(200), user(300, Self.clear)])

    #expect(changed(model) == ["b"])
  }

  @Test func aUserMessageThatMentionsSwitchboardMidLineMovesTheCutoff() {
    let model = model(
      [child("a", since: 150), child("b", since: 350)],
      log: [user(100), user(300, "Ask Switchboard: which sessions are done?")])

    #expect(changed(model) == ["b"])
  }

  @Test func aUserMessageWithNoTimeFallsBackToTheMessageBeforeIt() {
    let model = model(
      [child("early", since: 50), child("late", since: 150)], log: [user(100), assistant(120), user(nil)])

    #expect(changed(model) == ["late"])
  }

  @Test func onlyUserMessagesWithNoTimeGiveNoCutoff() {
    let model = model([child("a", since: 150)], log: [user(nil), assistant(120), user(nil)])

    #expect(changed(model) == nil)
  }

  // MARK: Links

  @Test(arguments: [MainView.inbox, .board])
  func aCountsLinkLeavesThePaneForItsView(_ view: MainView) {
    let model = appliedModel([Self.conversation, needsItem("a")])
    model.selection = "m"

    model.show(view)

    #expect(model.selection == nil)
    #expect(model.mainView == view)
  }

  @Test func choosingAChangedChildThatTheOrgFilterHidesShowsIt() {
    let model = hiddenChildModel()
    model.selection = "m"

    model.selection = model.managerStatus(for: Self.conversation).changed?.first?.id

    #expect(model.selected?.id == "hk")
  }
}
