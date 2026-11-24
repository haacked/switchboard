import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelManager {
  func model(_ list: [SessionSummary]) -> BoardModel {
    appliedModel(list)
  }

  /// The app checks for the prompt itself. A card item with no card in
  /// `cards` therefore stays out, the same as a reply item.
  @Test func theInboxLeavesOutAManagerWithOnlyAReplyItem() {
    for state in [AttentionState.needsYou, .canContinue] {
      for card in [false, true] {
        let model = model([needsItem("m", manager: true, state: state, card: card), needsItem("a")])
        #expect(model.triage.map(\.id) == ["a"])
        #expect(model.currentInboxItem == "a")
      }
    }
  }

  @Test(arguments: [Card.Kind.permission, .question, .trust, .mcp])
  func aManagersBlockingCardGoesInTheInbox(_ kind: Card.Kind) throws {
    let model = model([try needsItem("m", manager: true, waitingOn: kind), needsItem("a")])

    #expect(model.triage.map(\.id) == ["m", "a"])
    #expect(Set(model.needsUser.map(\.id)) == ["m", "a"])
    #expect(model.currentInboxItem == "m")
  }

  @Test func aManagerWithOnlyAReplyItemLeavesTheInboxEmpty() {
    let model = model([needsItem("m", manager: true, card: true)])
    #expect(model.triage.isEmpty)
    #expect(model.needsUser.isEmpty)
    #expect(model.currentInboxItem == nil)
  }

  @Test func aManagersMCPCardCountsTowardTheBadge() throws {
    let model = model([try needsItem("m", manager: true, waitingOn: .mcp)])

    #expect(model.needsUser.map(\.id) == ["m"])
  }

  @Test(arguments: ["allow", "deny"]) func answeringAnMCPCardSendsAnswerWithTheBehavior(_ behavior: String) async throws
  {
    let card = try cardFixture(7, session: "m", kind: .mcp)

    let request = await firstRequest { $0.answer(card, behavior: behavior) }

    #expect(request.op == "answer")
    #expect(request.args == ["session": "m", "card": 7, "behavior": .string(behavior)])
  }

  @Test func aManagersSendCardStaysOutOfTheInbox() throws {
    let model = model([try needsItem("m", manager: true, waitingOn: .send), needsItem("a")])

    #expect(model.triage.map(\.id) == ["a"])
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  @Test func nextNeedingYouSkipsTheManagerInTheInboxAndOutsideIt() {
    let model = model([needsItem("m", manager: true), needsItem("a"), needsItem("b")])
    model.show(.inbox)
    var seen: [String?] = []
    for _ in 0..<4 {
      model.selectNextNeedingYou()
      seen.append(model.currentInboxItem)
    }
    #expect(seen == ["b", "a", "b", "a"])
    model.show(.board)
    seen = []
    for _ in 0..<4 {
      model.selectNextNeedingYou()
      seen.append(model.selection)
    }
    #expect(seen == ["a", "b", "a", "b"])
  }

  @Test func theManagerDoesNotNotifyWhenItStartsNeedingYou() {
    let model = model([needsItem("m", manager: true, state: .working), needsItem("a", state: .working)])
    let next = [needsItem("m", manager: true), needsItem("a")]
    #expect(model.sessionsToNotify(next).map(\.id) == ["a"])
  }

  @Test func theManagerNotifiesWhenItStartsWaitingOnACard() throws {
    let model = model([needsItem("m", manager: true, state: .working), needsItem("a", state: .working)])

    let next = [try needsItem("m", manager: true, waitingOn: .permission), needsItem("a")]

    #expect(model.sessionsToNotify(next).map(\.id) == ["m", "a"])
  }

  @Test func aFollowupNotifiesOnlyWhileItWaitsToStart() {
    func followup(started: Bool) -> SessionSummary {
      var s = needsItem("f")
      s.followup = Followup(prompt: "p")
      if started { s.followup?.started = 1 }
      return s
    }
    let model = model([needsItem("f", state: .notStarted)])
    #expect(model.sessionsToNotify([followup(started: false)]).map(\.id) == ["f"])
    #expect(model.sessionsToNotify([followup(started: true)]).isEmpty)
  }

  @Test func aSessionSeenForTheFirstTimeDoesNotNotify() {
    let model = model([needsItem("a")])
    #expect(model.sessionsToNotify([needsItem("a"), needsItem("new")]).isEmpty)
  }

  @Test func aSessionThatBecomesReadyToMergeNotifiesAndCounts() {
    let model = model([needsItem("a", state: .working)])
    let next = [needsItem("a", state: .readyToMerge)]
    #expect(model.sessionsToNotify(next).map(\.id) == ["a"])
    model.apply(.success(next), followups: nil)
    #expect(model.needsUser.map(\.id) == ["a"])
  }

  // MARK: The operator

  func conversation(_ id: String, state: AttentionState = .working, lastActivity: Int64 = 1) -> SessionSummary {
    var s = needsItem(id, manager: true, state: state)
    s.openPrompt = state == .needsYou
    s.lastActivity = lastActivity
    return s
  }

  @Test func managersLeaveOutTheOperatorWithTheNewestActivity() {
    let model = model([conversation("m1", lastActivity: 1), conversation("m2", lastActivity: 2), operatorItem()])

    #expect(model.managers.map(\.id) == ["m2", "m1"])
  }

  @Test func waitingManagerIsNilWhenOnlyTheOperatorNeedsYou() {
    let model = model([conversation("m"), operatorItem(state: .needsYou)])

    #expect(model.waitingManager == nil)
  }

  @Test func waitingManagerNamesTheConversationWhenItAndTheOperatorNeedYou() {
    let model = model([operatorItem(state: .needsYou), conversation("m", state: .needsYou)])

    #expect(model.waitingManager?.id == "m")
  }

  @Test func operatorSessionReturnsTheOperator() {
    let model = model([conversation("m"), needsItem("a"), operatorItem("op")])

    #expect(model.operatorSession?.id == "op")
  }

  @Test func operatorSessionIsNilWithoutAnOperator() {
    let model = model([conversation("m"), needsItem("a")])

    #expect(model.operatorSession == nil)
  }

  @Test func theOperatorIsInNoSidebarStateGroup() {
    for state in [AttentionState.working, .needsYou, .waiting] {
      let model = model([operatorItem(state: state), needsItem("a", state: .working)])

      #expect(!model.sidebarGroups.flatMap { $0.rows.map(\.id) }.contains("op"))
    }
  }

  @Test func openOperatorAsksSbdForTheOperatorWithNoText() async {
    let sent = await firstRequest { $0.openOperator() }

    #expect(sent.op == "operator")
    #expect(sent.args["text"] == nil)
  }

  @Test func openOperatorSelectsTheSessionThatSbdNames() async {
    let model = offlineModel()
    model.send = { _, _ in ["id": "op"] }

    model.openOperator()

    await settle { model.selection == "op" }
    #expect(model.selection == "op")
  }

  @Test func movingBetweenNeedsYouAndReadyToMergeDoesNotNotify() {
    #expect(model([needsItem("a")]).sessionsToNotify([needsItem("a", state: .readyToMerge)]).isEmpty)
    #expect(model([needsItem("a", state: .readyToMerge)]).sessionsToNotify([needsItem("a")]).isEmpty)
  }
}
