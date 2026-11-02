import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: .summary)
    return s
  }

  func model(_ ids: [String]) -> BoardModel {
    // apply() sets the Dock badge, which needs NSApp.
    _ = NSApplication.shared
    let model = BoardModel()
    model.apply(.success(ids.map { summary($0) }), followups: nil)
    return model
  }

  @Test func clearsASelectionWhoseSessionWasRemoved() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func keepsASelectionWhoseSessionRemains() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "a")
  }

  @Test func keepsAnUnlistedSelectionThatCreateJustMade() {
    let model = model(["a"])
    model.selectUnlisted("new")
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "new")
  }

  @Test func clearsACreatedSelectionOnceItWasListedAndRemoved() {
    let model = model(["a"])
    model.selectUnlisted("new")
    model.apply(.success([summary("a"), summary("new")]), followups: nil)
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func clearsASelectionThatWasNeverListed() {
    // A click on the notification of a session that sbd has since removed.
    let model = model(["a"])
    model.selection = "gone"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func keepsAFollowupSelectionWhileTheFollowupListStillHoldsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.selection = "f"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "f")
  }

  @Test func boardCardForAQueueSessionFocusesItInTheQueue() {
    let model = model(["a", "b"])
    model.show(.board)
    let jumps = model.queueJumps
    model.openFromBoard("b")
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
    #expect(model.queueFocus == "b")
    #expect(model.queueJumps == jumps + 1)
  }

  @Test func boardCardForACanContinueSessionFocusesItInTheQueue() {
    let model = model(["a"])
    model.apply(.success([summary("a"), summary("c", state: .canContinue)]), followups: nil)
    model.show(.board)
    model.openFromBoard("c")
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
    #expect(model.queueFocus == "c")
  }

  @Test func boardCardForAFollowupOnlySessionSelectsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.show(.board)
    let jumps = model.queueJumps
    model.openFromBoard("f")
    #expect(model.selection == "f")
    #expect(model.queueJumps == jumps)
  }

  @Test func boardCardForAnUnlistedIdSelectsItUntilThePollClearsIt() {
    let model = model(["a"])
    model.show(.board)
    model.openFromBoard("gone")
    #expect(model.selection == "gone")
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func nextNeedingYouAfterABoardCardMovesOnFromTheClickedItem() {
    let model = model(["a", "b", "c"])
    model.show(.board)
    model.openFromBoard("b")
    model.selectNextNeedingYou()
    #expect(model.currentQueueItem == "c")
    #expect(model.visibleView == .queue)
  }

  @Test func boardCardForASessionOutsideTheQueueSelectsIt() {
    for state in [AttentionState.working, .done, .stale] {
      let model = model(["a"])
      var outside = summary("r", state: state)
      outside.triage = nil
      model.apply(.success([summary("a"), outside]), followups: nil)
      model.show(.board)
      let jumps = model.queueJumps
      model.openFromBoard("r")
      #expect(model.selection == "r")
      #expect(model.visibleView == nil)
      #expect(model.queueJumps == jumps)
    }
  }

  @Test func nextNeedingYouWithAStaleSelectionActsAsWithNone() {
    let model = model(["a", "b"])
    model.show(.queue)
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    let jumps = model.queueJumps
    model.selectNextNeedingYou()
    #expect(model.selection == nil)
    #expect(model.queueJumps == jumps + 1)
  }
}

@MainActor
@Suite struct BoardModelVisibleView {
  @Test func isTheMainViewWhileNothingIsSelected() {
    let model = BoardModel()
    #expect(model.visibleView == .queue)
    model.show(.board)
    #expect(model.visibleView == .board)
  }

  @Test func isNilWhileASessionIsSelected() {
    let model = BoardModel()
    model.selection = "a"
    #expect(model.visibleView == nil)
  }

  @Test func showClearsTheSelection() {
    let model = BoardModel()
    model.selection = "a"
    model.show(.queue)
    #expect(model.selection == nil)
    #expect(model.visibleView == .queue)
  }
}

@MainActor
@Suite struct BoardModelRead {
  @Test func readsTheFollowupsBeforeTheSessions() {
    var order: [String] = []
    _ = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      },
      followups: {
        order.append("followup-ls")
        return []
      })
    #expect(order == ["followup-ls", "ls"])
  }

  @Test func readsOnlyTheSessionsWithoutAFollowupRead() {
    var order: [String] = []
    let (_, more) = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      }, followups: nil)
    #expect(order == ["ls"])
    #expect(more == nil)
  }
}

@MainActor
@Suite struct DeletingDoneSessions {
  func done(
    repo: String? = "/repos/posthog", branch: String? = "haacked/fix", pr: PRState? = .merged,
    state: AttentionState = .done, manager: Bool? = nil
  ) -> SessionSummary {
    var s = SessionSummary(
      id: "s1", name: "fix", cwd: "/worktrees/posthog/haacked/fix", repo: repo, branch: branch, claudeSessionId: "c",
      state: state, reason: "", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false,
      lastReply: nil, waits: [], notes: [])
    s.manager = manager
    if let pr {
      s.pr = try! JSONDecoder().decode(
        PRSummary.self,
        from: Data(
          """
          {"number":7,"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"Fix","state":"\(pr.rawValue)","status":"\(pr == .merged ? "Merged" : "Closed")"}
          """.utf8))
    }
    return s
  }

  @Test func offersTheIconOnADoneSession() {
    #expect(BoardModel.canDelete(done()))
  }

  @Test func neverOffersTheIconOnTheManager() {
    #expect(!BoardModel.canDelete(done(manager: true)))
  }

  @Test func neverOffersTheIconOutsideTheDoneColumn() {
    for state in AttentionState.allCases where state != .done {
      #expect(!BoardModel.canDelete(done(state: state)))
    }
  }

  @Test func asksForTheWorktreeTheBranchAndTheRemoteBranchOfAMergedPR() {
    let request = BoardModel.deleteRequest(done())
    #expect(
      request == [
        "session": "s1", "worktree": true, "branch": true, "remote_branch": true,
      ])
  }

  @Test func keepsTheBranchWhenThePRIsNotMerged() {
    let request = BoardModel.deleteRequest(done(pr: .closed))
    #expect(request["worktree"] == true)
    #expect(request["branch"] == false)
    #expect(request["remote_branch"] == false)
    #expect(BoardModel.deletePlan(done(pr: nil)).branch == nil)
  }

  @Test func removesOnlyTheSessionWhenSbdMadeNoWorktree() {
    let request = BoardModel.deleteRequest(done(repo: nil, branch: nil))
    #expect(request == ["session": "s1", "worktree": false, "branch": false, "remote_branch": false])
    let plan = BoardModel.deletePlan(done(repo: nil, branch: nil))
    #expect(plan.worktree == nil)
  }

  @Test func namesEverythingItDeletesInTheConfirmation() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("the session fix"))
    #expect(text.contains("/worktrees/posthog/haacked/fix"))
    #expect(text.contains("local branch haacked/fix"))
    #expect(text.contains("remote branch haacked/fix"))
    #expect(text.contains("only if it is still at the merged PR's head"))
  }

  @Test func saysThatTheBranchStaysWhenThePRIsNotMerged() {
    let text = BoardModel.deletePlan(done(pr: .closed)).message
    #expect(!text.contains("the remote branch haacked/fix"))
    #expect(text.contains("The branch stays"))
  }

  @Test func namesTheRefusalsInTheConfirmation() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("uncommitted files"))
    #expect(text.contains("checked out in another worktree"))
    #expect(text.contains("Nothing is deleted"))
  }
}
