import AppKit
import Combine
import SwitchboardCore
import Testing

@testable import SwitchboardApp

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  @discardableResult func increment() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
}

/// A session whose triage item is a decision, or a card when `card` is true.
func needsItem(_ id: String, manager: Bool = false, state: AttentionState = .needsYou, card: Bool = false)
  -> SessionSummary
{
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
  s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: card ? .card : .summary)
  s.manager = manager ? true : nil
  if manager { s.kind = .manager }
  return s
}

/// A model whose client finds no sbd, so a refresh fails at once. `Client()`
/// reads `SB_HOME`, which can name the user's running sbd. A refresh from that
/// sbd replaces the test's groups and sessions. `apply` sets the Dock badge,
/// which needs NSApp.
@MainActor
func offlineModel() -> BoardModel {
  _ = NSApplication.shared
  return BoardModel(client: Client(home: Home(path: NSTemporaryDirectory() + "no-sbd-" + UUID().uuidString)))
}

/// Runs `action` on a model whose `send` counts requests, waits until sbd gets
/// the first one, and returns that request and the count at that moment.
@MainActor
func firstRequest(_ action: (BoardModel) -> Void) async -> (op: String, args: [String: JSON], count: Int) {
  let model = offlineModel()
  let sent = Counter()
  let (op, args) = await withCheckedContinuation { first in
    model.send = { op, args in
      if sent.increment() == 1 { first.resume(returning: (op, args)) }
      return .null
    }
    action(model)
  }
  return (op, args, sent.value)
}

/// A model that has applied `list`.
@MainActor
func appliedModel(_ list: [SessionSummary], followups: [SessionSummary]? = nil) -> BoardModel {
  let model = offlineModel()
  model.apply(.success(list), followups: followups)
  return model
}

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    needsItem(id, state: state)
  }

  func model(_ ids: [String]) -> BoardModel { appliedModel(ids.map { summary($0) }) }

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

  @Test func boardCardForAnInboxSessionFocusesItInTheInbox() {
    let model = model(["a", "b"])
    model.show(.board)
    let jumps = model.inboxJumps
    model.openFromBoard("b")
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
    #expect(model.inboxFocus == "b")
    #expect(model.inboxJumps == jumps + 1)
  }

  @Test func boardCardForACanContinueSessionFocusesItInTheInbox() {
    let model = model(["a"])
    model.apply(.success([summary("a"), summary("c", state: .canContinue)]), followups: nil)
    model.show(.board)
    model.openFromBoard("c")
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
    #expect(model.inboxFocus == "c")
  }

  @Test func boardCardForAFollowupOnlySessionSelectsIt() {
    let model = model(["a"])
    model.apply(.success([summary("a")]), followups: [summary("f", state: .notStarted)])
    model.show(.board)
    let jumps = model.inboxJumps
    model.openFromBoard("f")
    #expect(model.selection == "f")
    #expect(model.inboxJumps == jumps)
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
    #expect(model.currentInboxItem == "c")
    #expect(model.visibleView == .inbox)
  }

  @Test func movingUpFromTheFirstItemWrapsToTheLast() {
    let model = model(["a", "b", "c"])
    model.show(.inbox)
    model.moveInbox(by: -1)
    #expect(model.currentInboxItem == "c")
    model.moveInbox(by: -1)
    #expect(model.currentInboxItem == "b")
  }

  @Test func boardCardForASessionOutsideTheInboxSelectsIt() {
    for state in [AttentionState.working, .done, .stale] {
      let model = model(["a"])
      var outside = summary("r", state: state)
      outside.triage = nil
      model.apply(.success([summary("a"), outside]), followups: nil)
      model.show(.board)
      let jumps = model.inboxJumps
      model.openFromBoard("r")
      #expect(model.selection == "r")
      #expect(model.visibleView == nil)
      #expect(model.inboxJumps == jumps)
    }
  }

  @Test func nextNeedingYouWithAStaleSelectionActsAsWithNone() {
    let model = model(["a", "b"])
    model.show(.inbox)
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    let jumps = model.inboxJumps
    model.selectNextNeedingYou()
    #expect(model.selection == nil)
    #expect(model.inboxJumps == jumps + 1)
  }
}

@MainActor
@Suite struct BoardModelVisibleView {
  @Test func isTheMainViewWhileNothingIsSelected() {
    let model = offlineModel()
    #expect(model.visibleView == .inbox)
    model.show(.board)
    #expect(model.visibleView == .board)
  }

  @Test func isNilWhileASessionIsSelected() {
    let model = offlineModel()
    model.selection = "a"
    #expect(model.visibleView == nil)
  }

  @Test func showClearsTheSelection() {
    let model = offlineModel()
    model.selection = "a"
    model.show(.inbox)
    #expect(model.selection == nil)
    #expect(model.visibleView == .inbox)
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
    s.kind = SessionKind(manager: manager, chat: nil)
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
    #expect(done().isRemovableDone)
  }

  @Test func neverOffersTheIconOnTheManager() {
    #expect(!done(manager: true).isRemovableDone)
  }

  @Test func neverOffersTheIconOnAFollowupThatHasNotStarted() {
    var s = done()
    s.followup = Followup(prompt: "p")
    #expect(!s.isRemovableDone)
  }

  @Test func neverOffersTheIconOutsideTheDoneColumn() {
    for state in AttentionState.allCases where state != .done {
      #expect(!done(state: state).isRemovableDone)
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
    #expect(text.contains("A refusal before anything stops deletes nothing"))
  }

  @Test func saysThatTheSessionAndWorktreeGoEvenWhenTheBranchCheckFails() {
    let text = BoardModel.deletePlan(done()).message
    #expect(text.contains("fails its check after the worktree is gone"))
  }

  @Test func ignoresASecondDeleteWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      let session = done()
      model.deleteDone(session)
      model.deleteDone(session)
      #expect(model.deleting == [session.id])
    }
    #expect(sent.count == 1)
  }

  @Test func labelsTheIconWithWhatItRemoves() {
    #expect(BoardModel.deletePlan(done()).summary == "the session, its worktree, and its branch")
    #expect(BoardModel.deletePlan(done(pr: .closed)).summary == "the session and its worktree")
    #expect(BoardModel.deletePlan(done(repo: nil, branch: nil)).summary == "the session")
  }
}

@MainActor
@Suite struct BoardModelManager {
  func model(_ list: [SessionSummary]) -> BoardModel {
    appliedModel(list)
  }

  @Test func theInboxLeavesOutTheManagerWhateverItsItemIs() {
    for state in [AttentionState.needsYou, .canContinue] {
      for card in [false, true] {
        let model = model([needsItem("m", manager: true, state: state, card: card), needsItem("a")])
        #expect(model.triage.map(\.id) == ["a"])
        #expect(model.currentInboxItem == "a")
      }
    }
  }

  @Test func theManagerAloneLeavesTheInboxEmpty() {
    let model = model([needsItem("m", manager: true, card: true)])
    #expect(model.triage.isEmpty)
    #expect(model.needsUser.isEmpty)
    #expect(model.currentInboxItem == nil)
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

@MainActor
@Suite struct BoardModelSidebar {
  func summary(_ id: String, parent: String? = nil, manager: Bool = false, state: AttentionState = .working)
    -> SessionSummary
  {
    var s = needsItem(id, manager: manager, state: state)
    s.parent = parent
    return s
  }

  func model(_ sessions: [SessionSummary], followups: [SessionSummary]? = nil) -> BoardModel {
    appliedModel(sessions, followups: followups)
  }

  /// The sidebar as "state: id, >child" lines.
  func shown(_ model: BoardModel) -> [String] {
    model.sidebarGroups.map { group in
      "\(group.state): " + group.rows.map { String(repeating: ">", count: $0.depth) + $0.id }.joined(separator: ",")
    }
  }

  @Test func aManagerChildIsTopLevel() {
    let model = model([summary("m", manager: true), summary("a", parent: "m"), summary("b", parent: "m")])
    #expect(shown(model) == ["working: a,b"])
  }

  @Test func aChildOfAnOrdinarySessionStillNests() {
    let model = model([summary("p"), summary("c", parent: "p")])
    #expect(shown(model) == ["working: p,>c"])
  }

  @Test func theManagerIsPinnedAndNotInAStateGroup() {
    for state in [AttentionState.working, .needsYou, .done] {
      let model = model([summary("m", manager: true, state: state), summary("a", parent: "m")])
      #expect(model.managers.map(\.id) == ["m"])
      let ids = model.sidebarGroups.flatMap { $0.rows.map(\.id) }
      #expect(!ids.contains("m"))
      #expect(ids == ["a"])
    }
  }

  @Test func managerConversationsArePinnedNewestActivityFirst() {
    var old = summary("m1", manager: true)
    old.lastActivity = 1
    var recent = summary("m2", manager: true)
    recent.lastActivity = 2
    let model = model([old, recent, summary("a")])
    #expect(model.managers.map(\.id) == ["m2", "m1"])
    #expect(model.sidebarOrder == ["m2", "m1", "a"])
  }

  @Test func withoutAManagerThereIsNoPinnedRow() {
    #expect(model([summary("a")]).managers.isEmpty)
  }

  @Test func aGrandchildOfTheManagerNestsUnderItsParent() {
    let model = model([summary("m", manager: true), summary("a", parent: "m"), summary("g", parent: "a")])
    #expect(shown(model) == ["working: a,>g"])
  }

  @Test func aManagerWithNoChildrenLeavesTheGroupsEmptyButNotTheSidebar() {
    let model = model([summary("m", manager: true)])
    #expect(model.sidebarGroups.isEmpty)
    #expect(!model.sidebarIsEmpty)
  }

  @Test func withNoSessionsTheSidebarIsEmpty() {
    #expect(model([]).sidebarIsEmpty)
  }

  @Test func ordinarySessionsWithoutAManagerFillTheSidebar() {
    #expect(!model([summary("a")]).sidebarIsEmpty)
  }

  @Test func anUnreachableServiceIsNotAnEmptySidebar() {
    struct Down: Error {}
    let model = model([])
    model.apply(.failure(Down()), followups: nil)
    #expect(!model.sidebarIsEmpty)
  }

  @Test func aChildInAnotherStateIsTopLevelInItsOwnGroup() {
    let model = model([summary("p"), summary("c", parent: "p", state: .needsYou)])
    #expect(shown(model) == ["needsYou: c", "working: p"])
  }

  @Test func aFollowupThatHasNotStartedShowsInItsGroup() {
    let model = model([summary("a")], followups: [summary("f", state: .notStarted)])
    #expect(shown(model) == ["working: a", "notStarted: f"])
  }

  @Test func readyForReviewGroupSitsBetweenClaudeCanContinueAndWaiting() {
    let model = model([
      summary("w", state: .waiting), summary("r", state: .readyForReview), summary("c", state: .canContinue),
    ])
    #expect(shown(model) == ["canContinue: c", "readyForReview: r", "waiting: w"])
  }

  @Test func theManagerStaysSelectedAcrossARefresh() {
    let sessions = [summary("m", manager: true, state: .needsYou)]
    let model = model(sessions)
    model.selection = "m"
    model.apply(.success(sessions), followups: nil)
    #expect(model.managers.map(\.id) == ["m"])
    #expect(model.selection == "m")
    #expect(model.selected?.id == "m")
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelSuggestions {
  @Test func acceptSendsGroupSuggestWithTheId() async {
    let sent = await firstRequest { $0.acceptSuggestion("merge:g1:g2") }

    #expect(sent.op == "group-suggest")
    #expect(sent.args == ["accept": "merge:g1:g2"])
  }

  @Test func declineSendsGroupSuggestWithTheId() async {
    let sent = await firstRequest { $0.declineSuggestion("dependency:s1:g1") }

    #expect(sent.op == "group-suggest")
    #expect(sent.args == ["decline": "dependency:s1:g1"])
  }

  func suggestion(_ id: String) -> GroupSuggestion {
    GroupSuggestion(id: id, name: "Flags", group: nil, sessions: ["a", "b"], reason: "branches start with \(id)")
  }

  @Test func aDeclineThatSbdTakesRemovesTheRowFromTheSuggestions() async {
    let model = offlineModel()
    model.send = { _, _ in .null }
    model.suggestions = ["prefix:flag-evaluations", "prefix:billing-retry"].map(suggestion)

    model.declineSuggestion("prefix:flag-evaluations")
    await settle { model.suggestions.count == 1 }

    #expect(model.suggestions.map(\.id) == ["prefix:billing-retry"])
  }

  @Test func aDeclineThatSbdRefusesKeepsTheRow() async {
    let model = offlineModel()
    model.send = { _, _ in throw APIError("no suggestion prefix:flag-evaluations") }
    model.suggestions = ["prefix:flag-evaluations", "prefix:billing-retry"].map(suggestion)

    model.declineSuggestion("prefix:flag-evaluations")
    await settle { model.actionError != nil }

    #expect(model.actionError != nil)
    #expect(model.suggestions.map(\.id) == ["prefix:flag-evaluations", "prefix:billing-retry"])
  }

  @Test func theSuggestionButtonHasNoLabelWithoutSuggestions() {
    #expect(GroupSuggestionButton.label(count: 0) == nil)
  }

  @Test func theSuggestionButtonsLabelCountsOneSuggestion() throws {
    let label = try #require(GroupSuggestionButton.label(count: 1))

    #expect(label.contains("1"))
    #expect(label.hasSuffix("suggestion"))
  }

  @Test func theSuggestionButtonsLabelCountsThreeSuggestions() throws {
    let label = try #require(GroupSuggestionButton.label(count: 3))

    #expect(label.contains("3"))
    #expect(label.hasSuffix("suggestions"))
  }

  @Test func mergeSendsMergeWithTheSession() async {
    let sent = await firstRequest { $0.merge("a") }

    #expect(sent.op == "merge")
    #expect(sent.args == ["session": "a"])
  }

  @Test(arguments: [true, false]) func setShellOpenSendsShellWithTheSession(open: Bool) async {
    let sent = await firstRequest { $0.setShellOpen("a", open) }

    #expect(sent.op == "shell")
    #expect(sent.args == ["session": "a", "open": .bool(open)])
  }

  @Test func ignoresASecondMergeWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.merge("a")
      model.merge("a")
      #expect(model.merging == ["a"])
    }
    #expect(sent.count == 1)
  }

  @Test func chooseSendsTheTypedTextOfAReplyOption() async {
    let sent = await firstRequest { $0.choose("a", ref: "summary:1", option: 2, action: .reply, text: "Use SQLite.") }

    #expect(sent.op == "choose")
    #expect(sent.args == ["session": "a", "option": "2", "ref": "summary:1", "text": "Use SQLite."])
  }

  @Test func chooseSendsTheTickedOptionsAsAList() async {
    let sent = await firstRequest { $0.choose("a", ref: "summary:1", picks: ["1", "3"]) }

    #expect(sent.op == "choose")
    #expect(sent.args == ["session": "a", "options": ["1", "3"], "ref": "summary:1"])
  }

  @Test func ignoresASecondSubmitWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.choose("a", ref: "summary:1", picks: ["1"])
      model.choose("a", ref: "summary:1", picks: ["1"])
      #expect(model.choosing == ["a/picks"])
    }
    #expect(sent.count == 1)
  }

  @Test func submitWithNoPicksSendsNothing() async {
    let sent = await firstRequest { model in
      model.choose("a", ref: "summary:1", picks: [])
      #expect(model.choosing.isEmpty)
      model.choose("a", ref: "summary:1", picks: ["2"])
    }
    #expect(sent.count == 1)
    #expect(sent.args == ["session": "a", "options": ["2"], "ref": "summary:1"])
  }

  @Test func ignoresACardsMergeWhileAMergeRuns() async {
    let sent = await firstRequest { model in
      model.merge("a")
      model.choose("a", ref: "summary:1", option: 2, action: .dismiss)
      #expect(model.merging == ["a"])
      #expect(model.choosing.isEmpty)
    }
    #expect(sent.count == 1)
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.acceptSuggestion("merge:g1:g2")
      model.declineSuggestion("merge:g1:g2")
      #expect(model.answeringSuggestions == ["merge:g1:g2"])
    }
    #expect(sent.count == 1)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelPlanFollowups {
  @Test func followUpSendsPlanFollowupWithThePlanAndRow() async {
    let sent = await firstRequest { $0.followUp(plan: "p1", row: "2") }

    #expect(sent.op == "plan-followup")
    #expect(sent.args == ["plan": "p1", "row": "2"])
  }

  @Test func ignoresASecondFollowUpWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.followUp(plan: "p1", row: "2")
      model.followUp(plan: "p1", row: "2")
      #expect(model.followingUp == ["p1 2"])
    }
    #expect(sent.count == 1)
  }

  /// The row leaves `canFollowUp` in the same turn that turns its button
  /// back on, before the refresh lists the plan again.
  @Test func aMadeFollowUpDropsItsRowBeforeTheButtonTurnsBackOn() async {
    let model = offlineModel()
    var plan = PlanDocument(id: "p1", source: PlanSource(kind: .file, path: "/tmp/plan.md"), group: "g", attached: 0)
    plan.update(from: "| # | Item | Status |\n| --- | --- | --- |\n| 2 | Docs | Not started |\n", now: 1)
    var group = GroupSummary(SessionGroup(id: "g", name: "G", created: 0), sessions: [])
    group.plans = [PlanSummary(plan)]
    model.groups = [group]
    model.send = { _, _ in .null }
    func rows() -> [PlanRow]? { model.groups.first?.plans?.first?.canFollowUp }

    // `@Published` publishes before it stores the new value, so the sink runs
    // in the turn that turns the button back on.
    var turnedOn: AnyCancellable?
    let rowsWhenTheButtonTurnsOn = await withCheckedContinuation { done in
      turnedOn = model.$followingUp.dropFirst().first(where: \.isEmpty).sink { _ in
        done.resume(returning: MainActor.assumeIsolated { rows() })
      }
      model.followUp(plan: "p1", row: "2")
    }
    turnedOn?.cancel()
    #expect(rowsWhenTheButtonTurnsOn?.isEmpty == true)

    // The refresh that the follow-up started finds no sbd and sets `unreachable`.
    for await problem in model.$unreachable.values where problem != nil { break }
    #expect(rows()?.isEmpty == true)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelAcknowledge {
  @Test func acknowledgeSendsAckWithTheSession() async {
    let sent = await firstRequest { $0.acknowledge("a") }

    #expect(sent.op == "ack")
    #expect(sent.args == ["session": "a"])
  }

  @Test func undoSendsAckWithUndo() async {
    let sent = await firstRequest { $0.acknowledge("a", undo: true) }

    #expect(sent.op == "ack")
    #expect(sent.args == ["session": "a", "undo": true])
  }

  @Test func ignoresASecondAcknowledgeWhileTheFirstRuns() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.acknowledge("a")
    model.acknowledge("a", undo: true)
    #expect(model.acknowledging == ["a"])
    for _ in 0..<100 where sent.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 1)
  }

  @Test func acknowledgingOneSessionLeavesAnotherFree() {
    let model = offlineModel()
    let sent = Counter()
    model.send = { _, _ in
      sent.increment()
      return .null
    }
    model.acknowledge("a")
    model.acknowledge("b")
    #expect(model.acknowledging == ["a", "b"])
    for _ in 0..<100 where sent.value < 2 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sent.value == 2)
  }

  @Test func theAcknowledgingSetEmptiesWhenTheRequestFinishes() async throws {
    let model = offlineModel()
    model.send = { _, _ in .null }

    model.acknowledge("a")
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.acknowledging.isEmpty)
  }

  @Test func theAcknowledgingSetEmptiesWhenTheRequestFails() async throws {
    struct Refused: Error {}
    let model = offlineModel()
    model.send = { _, _ in throw Refused() }

    model.acknowledge("a")
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.acknowledging.isEmpty)
  }

  func inboxModel(focus: String) -> BoardModel {
    let model = appliedModel([needsItem("a"), needsItem("b"), needsItem("c")])
    model.send = { _, _ in .null }
    model.show(.inbox)
    model.inboxFocus = focus
    return model
  }

  @Test func acknowledgingTheCurrentItemFocusesTheNextOne() {
    let model = inboxModel(focus: "b")
    model.acknowledge("b")
    #expect(model.inboxFocus == "c")
  }

  @Test func acknowledgingAnotherItemLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.acknowledge("c")
    #expect(model.inboxFocus == "b")
  }

  @Test func undoLeavesTheFocus() {
    let model = inboxModel(focus: "b")
    model.acknowledge("b", undo: true)
    #expect(model.inboxFocus == "b")
  }

  @Test func acknowledgeTargetIsTheCurrentInboxItemWhileTheInboxShows() {
    #expect(inboxModel(focus: "b").acknowledgeTarget?.id == "b")
  }

  /// A selection shows the session's terminals in place of the Inbox.
  @Test func acknowledgeTargetIsTheSelectionOutsideTheInbox() {
    let model = inboxModel(focus: "b")
    model.selection = "a"
    #expect(model.acknowledgeTarget?.id == "a")
  }

  @Test func undoDoesNotNotifyAboutTheRestoredItem() async throws {
    var acked = needsItem("a", state: .waiting)
    acked.acknowledged = true
    let model = appliedModel([acked])
    let restored = try JSON(encoding: needsItem("a"))
    model.send = { _, _ in restored }

    model.acknowledge("a", undo: true)
    for _ in 0..<100 where !model.acknowledging.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

    #expect(model.sessionsToNotify([needsItem("a")]).isEmpty)
  }
}

/// Whether the Inbox makes Acknowledge the item's primary button.
@Suite struct InformationalItems {
  func item(
    state: AttentionState = .needsYou, kind: TriageKind = .info, options: [TriageOption] = [], card: Bool = false,
    openPrompt: Bool = false, triage: Bool = true
  ) throws -> SessionSummary {
    var s = needsItem("a", state: state)
    s.triage = triage ? TriageItem(title: "Done", kind: kind, summary: "", options: options, source: .summary) : nil
    s.openPrompt = openPrompt
    if card {
      let json: JSON = [
        "id": 3, "session": "a", "kind": "permission", "tool": "Bash", "summary": "`ls`", "input": [:],
        "questions": [], "since": 0, "deferred": false, "hookClosed": false,
      ]
      s.cards = [try JSONCoding.convert(json, to: Card.self)]
    }
    return s
  }

  static let option = TriageOption(label: "Go", message: "go")

  @Test func needsYouInfoItemIsInformational() throws {
    #expect(try item().isInformational)
  }

  @Test(arguments: [TriageKind.decision, .question, .approval, .review, .action])
  func needsYouItemWithNoOptionsIsInformational(_ kind: TriageKind) throws {
    #expect(try item(kind: kind).isInformational)
  }

  /// An item with options has its own primary button, so Acknowledge stays quiet.
  @Test(arguments: [TriageKind.decision, .question, .approval, .review, .action, .info])
  func itemWithOptionsIsNotInformational(_ kind: TriageKind) throws {
    #expect(try !item(kind: kind, options: [InformationalItems.option]).isInformational)
  }

  @Test(arguments: AttentionState.allCases.filter { $0 != .needsYou })
  func itemOutsideNeedsYouIsNotInformational(_ state: AttentionState) throws {
    #expect(try !item(state: state).isInformational)
  }

  @Test func sessionWithACardIsNotInformational() throws {
    #expect(try !item(card: true).isInformational)
  }

  @Test func sessionWithAnOpenDialogIsNotInformational() throws {
    #expect(try !item(openPrompt: true).isInformational)
  }

  @Test func sessionWithoutATriageItemIsNotInformational() throws {
    #expect(try !item(triage: false).isInformational)
  }

  /// The step view's Next and Submit take ⇧⌘Return, so Acknowledge stays quiet.
  @Test func itemWithDecisionsToStepThroughIsNotInformational() throws {
    var s = try item(kind: .decision)
    let yesNo = [PendingDecision.Option(label: "Yes"), PendingDecision.Option(label: "No")]
    s.triage?.decisions = [1, 2].map {
      PendingDecision(number: $0, header: "H\($0)", question: "Q\($0)?", options: yesNo)
    }

    #expect(!s.isInformational)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelProposalAnswers {
  @Test(arguments: [(true, "plan-apply"), (false, "plan-reject")])
  func answerSendsTheOpWithTheProposal(_ apply: Bool, _ op: String) async {
    let sent = await firstRequest { apply ? $0.applyProposal("u1") : $0.rejectProposal("u1") }

    #expect(sent.op == op)
    #expect(sent.args == ["proposal": "u1"])
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.applyProposal("u1")
      model.rejectProposal("u1")
      #expect(model.answeringProposals == ["u1"])
    }
    #expect(sent.count == 1)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BoardModelArtifactAnswers {
  @Test(arguments: [(true, "plan-artifact-apply"), (false, "plan-artifact-reject")])
  func answerSendsTheOpForApplyOrReject(_ apply: Bool, _ op: String) async {
    let sent = await firstRequest { $0.answerArtifact(plan: "p1", apply: apply) }

    #expect(sent.op == op)
    #expect(sent.args == ["plan": "p1"])
  }

  @Test func ignoresASecondAnswerWhileTheFirstRuns() async {
    let sent = await firstRequest { model in
      model.answerArtifact(plan: "p1", apply: true)
      model.answerArtifact(plan: "p1", apply: false)
      #expect(model.answeringArtifacts == ["p1"])
    }
    #expect(sent.count == 1)
  }

  /// sbd's reply replaces the plan's summary in the same turn that turns the
  /// buttons back on, before the refresh lists the plan again.
  @Test func answerTakesThePlanFromSbdsReply() async throws {
    let model = offlineModel()
    var plan = PlanDocument(
      id: "p1", source: PlanSource(kind: .artifact, url: "https://claude.ai/artifact/a"), group: "g", attached: 0)
    plan.artifact?.copy = "a\n"
    plan.artifact?.proposal = ArtifactProposal(rows: [], base: "a\n", version: nil, text: "b\n", created: 1)
    var group = GroupSummary(SessionGroup(id: "g", name: "G", created: 0), sessions: [])
    group.plans = [PlanSummary(plan)]
    model.groups = [group]
    var answered = plan
    answered.artifact?.proposal = nil
    let reply = try JSONCoding.convert(answered, to: JSON.self)
    model.send = { _, _ in reply }

    // `@Published` publishes before it stores the new value, so the sink runs
    // in the turn that turns the buttons back on.
    var turnedOn: AnyCancellable?
    let proposalGoneWhenTheButtonsTurnOn = await withCheckedContinuation { done in
      turnedOn = model.$answeringArtifacts.dropFirst().first(where: \.isEmpty).sink { _ in
        done.resume(returning: MainActor.assumeIsolated { model.groups.first?.plans?.first?.proposal == nil })
      }
      model.answerArtifact(plan: "p1", apply: false)
    }
    turnedOn?.cancel()
    #expect(proposalGoneWhenTheButtonsTurnOn)
  }
}
