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

  @Test(arguments: [Card.Kind.permission, .question, .trust])
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

  @Test func movingBetweenNeedsYouAndReadyToMergeDoesNotNotify() {
    #expect(model([needsItem("a")]).sessionsToNotify([needsItem("a", state: .readyToMerge)]).isEmpty)
    #expect(model([needsItem("a", state: .readyToMerge)]).sessionsToNotify([needsItem("a")]).isEmpty)
  }
}
