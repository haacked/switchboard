import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A live work session in `state` with no worktree, whose Delete label is "the session".
private func liveWork(_ state: AttentionState = .needsYou, id: String = "s1") -> SessionSummary {
  needsItem(id, state: state)
}

private func stoppedWork(_ state: AttentionState = .needsYou) -> SessionSummary {
  var s = needsItem("s1", state: state)
  s.live = false
  return s
}

/// A session in the worktree of branch haacked/fix whose PR merged, so Delete also removes the branch.
private func mergedWork(_ state: AttentionState = .done) -> SessionSummary {
  var s = notedSession([], state: state)
  s.pr = try! JSONDecoder().decode(
    PRSummary.self,
    from: Data(
      """
      {"number":7,"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"Fix","state":"MERGED","status":"Merged"}
      """.utf8))
  return s
}

private func ofKind(_ kind: SessionKind, live: Bool = true) -> SessionSummary {
  var s = needsItem("s1")
  s.kind = kind
  s.live = live
  return s
}

private func expectedDelete(_ s: SessionSummary) -> SessionMenuAction {
  .delete("Delete \(BoardModel.deletePlan(s).summary)…")
}

private func isDeleteSelection(_ a: SessionMenuAction) -> Bool {
  if case .deleteSelection = a { return true }
  return false
}

private func isDestructive(_ a: SessionMenuAction) -> Bool {
  switch a {
  case .cleanUp, .delete, .deleteSelection: true
  case .highlight, .snooze, .copyLink, .notes, .rename, .pause, .resume, .startNow, .stop, .moveToAccount,
    .unlinkParent, .divider:
    false
  }
}

private let paused = Pause(by: .you, since: 0)

private let startedStates = AttentionState.allCases.filter { $0 != .notStarted }

/// Every session row's context menu lists the same actions: the ones that keep the session, a divider, and then
/// the ones that remove something, with Delete last.
@Suite struct SessionMenuStop {
  @Test func offersStopForALiveSessionThatIsNotPaused() {
    #expect(SessionMenu.actions(for: liveWork(), selectionCount: nil).contains(.stop))
  }

  @Test func offersNoStopWhenClaudeIsNotRunning() {
    #expect(!SessionMenu.actions(for: stoppedWork(), selectionCount: nil).contains(.stop))
  }

  @Test func offersNoStopForAPausedSession() {
    var s = liveWork()
    s.pause = paused

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(.stop))
  }

  @Test(arguments: [SessionKind.manager, .chat, .operator])
  func offersStopForALiveSessionOfAnyKind(_ kind: SessionKind) {
    #expect(SessionMenu.actions(for: ofKind(kind), selectionCount: nil).contains(.stop))
  }
}

@Suite struct SessionMenuMoveToAccount {
  @Test func offersMoveToAccountAfterStopAndBeforeTheDivider() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: nil, movesAccount: true)

    let move = actions.firstIndex(of: .moveToAccount)
    #expect(move != nil)
    #expect(move.map { $0 > actions.firstIndex(of: .stop)! } == true)
    #expect(actions.firstIndex(of: .divider).map { move! < $0 } ?? true)
  }

  @Test func offersNoMoveToAccountWhenTheSessionCannotMove() {
    #expect(!SessionMenu.actions(for: liveWork(), selectionCount: nil).contains(.moveToAccount))
  }

  @Test(arguments: [SessionKind.manager, .chat, .operator])
  func offersMoveToAccountForASessionOfAnyKind(_ kind: SessionKind) {
    #expect(SessionMenu.actions(for: ofKind(kind), selectionCount: nil, movesAccount: true).contains(.moveToAccount))
  }
}

/// "Unlink from <parent>" shows only for a session whose parent matters, and it keeps the session, so it comes before
/// the divider.
@Suite struct SessionMenuUnlinkParent {
  @Test func offersUnlinkWithTheParentsNameWhenTheSessionHasAParent() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: nil, parentName: "planner")

    #expect(actions.contains(.unlinkParent("Unlink from planner")))
  }

  @Test func offersNoUnlinkWithoutAParentName() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: nil)

    #expect(!actions.contains { if case .unlinkParent = $0 { true } else { false } })
  }

  @Test func offersUnlinkOnce() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: nil, movesAccount: true, parentName: "planner")

    #expect(actions.filter { $0 == .unlinkParent("Unlink from planner") }.count == 1)
  }

  @Test func placesUnlinkAfterMoveToAccountAndBeforeTheDivider() {
    let s = liveWork()

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil, movesAccount: true, parentName: "planner") == [
        .highlight, .snooze, .copyLink, .notes, .pause, .stop, .moveToAccount, .unlinkParent("Unlink from planner"),
        .divider,
        expectedDelete(s),
      ])
  }

  @Test func placesUnlinkLastAmongTheSafeActionsWithoutMoveToAccount() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: nil, parentName: "planner")

    let unlink = actions.firstIndex(of: .unlinkParent("Unlink from planner"))
    #expect(unlink.map { $0 + 1 < actions.count && actions[$0 + 1] == .divider } == true, "\(actions)")
  }

  @Test func placesUnlinkBeforeTheDividerInAMultiSelection() {
    let actions = SessionMenu.actions(for: liveWork(), selectionCount: 3, parentName: "planner")

    let unlink = actions.firstIndex(of: .unlinkParent("Unlink from planner"))
    let divider = actions.firstIndex(of: .divider)
    #expect(unlink != nil && divider != nil && unlink! < divider!, "\(actions)")
  }

  /// A session with no destructive action shows no divider, and Unlink still shows.
  @Test func offersUnlinkForASessionWithNoDestructiveAction() {
    let actions = SessionMenu.actions(for: operatorItem(), selectionCount: nil, parentName: "planner")

    #expect(actions.last == .unlinkParent("Unlink from planner"))
    #expect(!actions.contains(.divider))
  }

  @Test func unlinkIsNotDestructive() {
    #expect(!isDestructive(.unlinkParent("Unlink from planner")))
  }

  /// The divider rules of `SessionMenuOrder` hold for every shape when the session also has a parent.
  @Test(arguments: SessionMenuOrder.shapes.indices)
  func placesNoDestructiveActionBeforeTheDividerWithAParent(_ i: Int) {
    let (name, s, count) = SessionMenuOrder.shapes[i]
    let actions = SessionMenu.actions(for: s, selectionCount: count, parentName: "planner")
    let firstDestructive = actions.firstIndex(where: isDestructive)
    let unlink = actions.firstIndex(of: .unlinkParent("Unlink from planner"))

    #expect(firstDestructive.map { $0 > 0 && actions[$0 - 1] == .divider } ?? true, "\(name)")
    #expect(unlink.map { u in firstDestructive.map { u < $0 } ?? true } == true, "\(name)")
  }
}

@Suite struct SessionMenuStartNow {
  @Test func offersStartNowForAQueuedSession() {
    var s = stoppedWork()
    s.queued = true

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(.startNow))
  }

  @Test(arguments: [Bool?.none, false])
  func offersNoStartNowForASessionThatIsNotQueued(_ queued: Bool?) {
    var s = stoppedWork()
    s.queued = queued

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(.startNow))
  }
}

@Suite struct SessionMenuDelete {
  @Test(arguments: startedStates)
  func offersDeleteForAWorkSessionInAnyState(_ state: AttentionState) {
    let s = liveWork(state)

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(expectedDelete(s)))
  }

  @Test(arguments: [AttentionState.needsYou, .canContinue, .readyToMerge, .working, .done])
  func labelsDeleteWithWhatItRemovesFromAWorktree(_ state: AttentionState) {
    let s = notedSession([], state: state)

    #expect(SessionMenu.actions(for: s, selectionCount: nil).last == .delete("Delete the session and its worktree…"))
  }

  @Test func labelsDeleteWithTheBranchWhenThePRMerged() {
    let s = mergedWork()

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil).last
        == .delete("Delete the session, its worktree, and its branch…"))
  }

  @Test func labelsDeleteWithOnlyTheSessionWithoutAWorktree() {
    #expect(SessionMenu.actions(for: liveWork(), selectionCount: nil).last == .delete("Delete the session…"))
  }

  @Test func offersNoDeleteForTheOperator() {
    let actions = SessionMenu.actions(for: ofKind(.operator), selectionCount: nil)

    #expect(!actions.contains(where: isDelete))
  }

  @Test func offersNoDeleteForAFollowupThatWaitsToStart() {
    var s = unstartedFollowup("f1")
    s.live = false

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(where: isDelete))
  }

  @Test func offersNoDeleteForASessionWhoseDeleteFailed() {
    var s = stoppedWork()
    s.removal = Removal(requested: 0, notBefore: 0, worktree: true, branch: false, remoteBranch: false, resolve: [])
    s.removal?.state = .failed

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(where: isDelete))
  }

  @Test func offersNoDeleteForADocketRowThatIsNotDone() {
    #expect(!SessionMenu.actions(for: docketSession("d1"), selectionCount: nil).contains(where: isDelete))
  }

  @Test func offersDeleteForADocketRowInDone() {
    var s = docketSession("d1")
    s.state = .done

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(where: isDelete))
  }

  @Test func offersDeleteForAFollowupThatStarted() {
    var s = liveWork(.working)
    s.followup = Followup(prompt: "p")
    s.followup?.started = 1

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(expectedDelete(s)))
  }
}

/// A Manager conversation's row offers "Delete the conversation…", which deletes it through `manager-end`.
@Suite struct SessionMenuConversationDelete {
  private static let conversationDelete = SessionMenuAction.delete("Delete the conversation…")

  @Test(arguments: [true, false])
  func offersDeleteTheConversationLastAfterTheDivider(_ live: Bool) {
    let actions = SessionMenu.actions(for: ofKind(.manager, live: live), selectionCount: nil)

    #expect(actions.last == Self.conversationDelete)
    #expect(actions.dropLast().last == .divider)
  }

  @Test func offersDeleteForAPausedConversation() {
    var s = ofKind(.manager)
    s.pause = paused

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(Self.conversationDelete))
  }

  /// Decision 12: the menu copies none of sbd's refusals, so a conversation in a turn still offers Delete.
  @Test(arguments: [AttentionState.working, .needsYou, .waiting, .done])
  func offersDeleteForAConversationInAnyState(_ state: AttentionState) {
    var s = ofKind(.manager)
    s.state = state

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(Self.conversationDelete))
  }

  /// Decision 13: a conversation in a multi-selection keeps the selection delete, whose count covers work only.
  @Test func offersTheSelectionDeleteForAConversationInAMultiSelection() {
    let actions = SessionMenu.actions(for: ofKind(.manager), selectionCount: 2)

    #expect(actions.last == .deleteSelection(count: 2))
  }

  /// The removal states of the matrix: none, or one of sbd's removal job states.
  enum RemovalShape: CaseIterable, Sendable, CustomTestStringConvertible {
    case none, queued, running, failed

    var testDescription: String { "\(self)" }

    var removal: Removal? {
      let state: Removal.State
      switch self {
      case .none: return nil
      case .queued: state = .queued
      case .running: state = .running
      case .failed: state = .failed
      }
      var r = Removal(requested: 0, notBefore: 0, worktree: false, branch: false, remoteBranch: false, resolve: [])
      r.state = state
      return r
    }
  }

  /// Risk 1: `.delete` shows only for a work session under today's rule, for a Manager conversation, and for a group
  /// chat conversation, and only with no removal outside a multi-selection. The Operator never gets it.
  @Test(
    arguments: [SessionKind.work, .manager, .chat, .operator], RemovalShape.allCases)
  func offersDeleteOnlyForWorkAndConversationsWithNoRemovalOutsideASelection(
    _ kind: SessionKind, _ removal: RemovalShape
  ) {
    for selectionCount in [nil, 3] as [Int?] {
      var s = ofKind(kind)
      s.removal = removal.removal

      let deletes = SessionMenu.actions(for: s, selectionCount: selectionCount).filter(isDelete)

      let offered = removal == .none && selectionCount == nil && kind != .operator
      let expected: [SessionMenuAction] =
        !offered ? [] : kind == .work ? [expectedDelete(s)] : [Self.conversationDelete]
      #expect(deletes == expected, "\(kind) \(removal) selection \(String(describing: selectionCount))")
    }
  }
}

/// Decision 6: a group chat's conversation row offers "Delete the conversation…", which removes it through
/// `manager-end` as a Manager conversation's does.
@Suite struct SessionMenuTests {
  private static let conversationDelete = SessionMenuAction.delete("Delete the conversation…")

  @Test(arguments: [true, false])
  func offersDeleteTheConversationLastAfterTheDividerForAChat(_ live: Bool) {
    var chat = chatItem("c1", group: "g1")
    chat.live = live

    let actions = SessionMenu.actions(for: chat, selectionCount: nil)

    #expect(actions.last == Self.conversationDelete)
    #expect(actions.dropLast().last == .divider)
  }

  @Test(arguments: [AttentionState.working, .needsYou, .waiting, .done])
  func offersDeleteForAChatInAnyState(_ state: AttentionState) {
    #expect(
      SessionMenu.actions(for: chatItem("c1", group: "g1", state: state), selectionCount: nil)
        .contains(Self.conversationDelete))
  }

  @Test func offersDeleteForAPausedChat() {
    var chat = chatItem("c1", group: "g1")
    chat.pause = paused

    #expect(SessionMenu.actions(for: chat, selectionCount: nil).contains(Self.conversationDelete))
  }

  // MARK: Rename (Decision 10)

  @Test(arguments: [SessionKind.manager, .chat], [true, false])
  func offersRenameForAConversation(_ kind: SessionKind, _ live: Bool) {
    #expect(SessionMenu.actions(for: ofKind(kind, live: live), selectionCount: nil).contains(.rename))
  }

  @Test(arguments: [SessionKind.work, .operator])
  func offersNoRenameForAWorkSessionOrTheOperator(_ kind: SessionKind) {
    #expect(!SessionMenu.actions(for: ofKind(kind), selectionCount: nil).contains(.rename))
  }

  @Test(arguments: [SessionKind.manager, .chat])
  func offersRenameOnceBeforeTheDivider(_ kind: SessionKind) {
    let actions = SessionMenu.actions(for: ofKind(kind), selectionCount: nil, parentName: "planner")

    #expect(actions.filter { $0 == .rename }.count == 1)
    let rename = actions.firstIndex(of: .rename)
    let divider = actions.firstIndex(of: .divider)
    #expect(rename != nil && divider != nil && rename! < divider!, "\(actions)")
  }

  @Test func offersRenameForAPausedConversation() {
    var s = ofKind(.chat)
    s.pause = paused

    #expect(SessionMenu.actions(for: s, selectionCount: nil).contains(.rename))
  }

  @Test func renameIsNotDestructive() {
    #expect(!isDestructive(.rename))
  }

  @Test func offersNoDeleteForAChatWithARemoval() {
    var chat = chatItem("c1", group: "g1")
    chat.removal = Removal(requested: 0, notBefore: 0, worktree: false, branch: false, remoteBranch: false, resolve: [])

    #expect(!SessionMenu.actions(for: chat, selectionCount: nil).contains(where: isDelete))
  }
}

@Suite struct SessionMenuMultiSelection {
  @Test func offersDeleteSelectionForARowInTheMultiSelection() {
    #expect(SessionMenu.actions(for: liveWork(), selectionCount: 3).contains(.deleteSelection(count: 3)))
  }

  @Test func offersNoSingleDeleteForARowInTheMultiSelection() {
    #expect(!SessionMenu.actions(for: liveWork(), selectionCount: 3).contains(where: isDelete))
  }

  @Test func putsDeleteSelectionLast() {
    let actions = SessionMenu.actions(for: cleanupSession(CleanupStatus(state: .ready)), selectionCount: 2)

    #expect(actions.last == .deleteSelection(count: 2))
  }

  @Test func offersNoDeleteSelectionForARowOutsideTheMultiSelection() {
    #expect(!SessionMenu.actions(for: liveWork(), selectionCount: nil).contains(where: isDeleteSelection))
  }

  @Test func passesTheRemovableCountForASidebarRowInTheMultiSelection() {
    let count = SessionMenu.selectionCount(
      for: "s1", removableSelection: 2, showsMultiSelection: true, multiSelection: ["s1", "s2"])

    #expect(count == 2)
  }

  @Test func passesNoCountForASidebarRowOutsideTheMultiSelection() {
    let count = SessionMenu.selectionCount(
      for: "s3", removableSelection: 2, showsMultiSelection: true, multiSelection: ["s1", "s2"])

    #expect(count == nil)
  }

  /// The Board and the Inbox pass no `removableSelection`, so their rows never offer the selection delete.
  @Test func passesNoCountForARowOutsideTheSidebar() {
    let count = SessionMenu.selectionCount(
      for: "s1", removableSelection: nil, showsMultiSelection: true, multiSelection: ["s1", "s2"])

    #expect(count == nil)
  }

  @Test func passesNoCountWithoutAMultiSelection() {
    let count = SessionMenu.selectionCount(
      for: "s1", removableSelection: 1, showsMultiSelection: false, multiSelection: ["s1"])

    #expect(count == nil)
  }
}

@Suite struct SessionMenuCleanUp {
  @Test func offersCleanUpWhenEveryCheckPassed() {
    #expect(
      SessionMenu.actions(for: cleanupSession(CleanupStatus(state: .ready)), selectionCount: nil).contains(.cleanUp))
  }

  @Test(arguments: [
    CleanupStatus?.none,
    CleanupStatus(state: .blocked, reason: "the worktree has uncommitted files"),
    CleanupStatus(state: .removed),
  ])
  func offersNoCleanUpUnlessEveryCheckPassed(_ cleanup: CleanupStatus?) {
    #expect(!SessionMenu.actions(for: cleanupSession(cleanup), selectionCount: nil).contains(.cleanUp))
  }
}

@Suite struct SessionMenuOrder {
  @Test func ordersEveryActionNonDestructiveFirstAndDeleteLast() {
    var s = cleanupSession(CleanupStatus(state: .ready))
    s.live = true
    s.queued = true

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil)
        == [.snooze, .copyLink, .notes, .pause, .startNow, .stop, .divider, .cleanUp, expectedDelete(s)])
  }

  @Test func separatesStopFromDeleteWithADivider() {
    let s = liveWork()

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil) == [
        .highlight, .snooze, .copyLink, .notes, .pause, .stop, .divider, expectedDelete(s),
      ])
  }

  @Test func showsPauseStopAndDeleteTheConversationButNoSnoozeForALiveChat() {
    #expect(
      SessionMenu.actions(for: chatItem("c1", group: "g1"), selectionCount: nil).filter { $0 != .rename } == [
        .copyLink, .notes, .pause, .stop, .divider, .delete("Delete the conversation…"),
      ])
  }

  @Test func showsPauseAndDeleteForAManagerConversationThatIsNotRunning() {
    #expect(
      SessionMenu.actions(for: ofKind(.manager, live: false), selectionCount: nil).filter { $0 != .rename } == [
        .copyLink, .notes, .pause, .divider, .delete("Delete the conversation…"),
      ])
  }

  @Test func separatesCleanUpAndDeleteFromSnoozeAndPauseWithADivider() {
    let s = cleanupSession(CleanupStatus(state: .ready))

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil) == [
        .snooze, .copyLink, .notes, .pause, .divider, .cleanUp, expectedDelete(s),
      ])
  }

  /// A session marked Done whose worktree the cleanup removed shows no Snooze and no Pause, so only Copy Link
  /// precedes the divider.
  @Test func keepsTheDividerAfterCopyLinkWhenNoOtherItemPrecedesTheDelete() {
    var s = cleanupSession(CleanupStatus(state: .removed))
    s.markedDone = true

    #expect(SessionMenu.actions(for: s, selectionCount: nil) == [.copyLink, .notes, .divider, expectedDelete(s)])
  }

  @Test func separatesDeleteOfAPausedSessionWithADivider() {
    var s = liveWork()
    s.pause = paused

    #expect(
      SessionMenu.actions(for: s, selectionCount: nil) == [
        .highlight, .snooze, .copyLink, .notes, .resume, .divider, expectedDelete(s),
      ])
  }

  @Test func offersHighlightFirstForAWorkSessionThatIsNotDone() {
    #expect(SessionMenu.actions(for: liveWork(), selectionCount: nil).first == .highlight)
  }

  @Test func offersHighlightToRemoveAHighlightOnADoneSession() {
    var s = stoppedWork(.done)
    s.highlighted = true

    #expect(SessionMenu.actions(for: s, selectionCount: nil).first == .highlight)
  }

  @Test func offersNoHighlightForADoneSessionOrAChat() {
    #expect(!SessionMenu.actions(for: stoppedWork(.done), selectionCount: nil).contains(.highlight))
    #expect(!SessionMenu.actions(for: chatItem("c1", group: "g1"), selectionCount: nil).contains(.highlight))
  }

  @Test func offersNoSnoozeForASessionMarkedDone() {
    var s = stoppedWork()
    s.markedDone = true

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(.snooze))
  }

  @Test func offersNoPauseWithoutTerminals() {
    var s = cleanupSession(CleanupStatus(state: .removed))
    s.live = false

    #expect(!SessionMenu.actions(for: s, selectionCount: nil).contains(.pause))
  }

  /// The menu shapes that the rows show, from sessions that differ in kind, liveness, pause, queue, and cleanup.
  static let shapes: [(String, SessionSummary, Int?)] = {
    var queuedChat = chatItem("c1", group: "g1")
    queuedChat.live = false
    queuedChat.queued = true
    var pausedWork = liveWork()
    pausedWork.pause = paused
    var liveCleanup = cleanupSession(CleanupStatus(state: .ready))
    liveCleanup.live = true
    var pausedManager = ofKind(.manager)
    pausedManager.pause = paused
    return [
      ("live work", liveWork(), nil),
      ("stopped work", stoppedWork(), nil),
      ("paused work", pausedWork, nil),
      ("merged done", mergedWork(), nil),
      ("ready cleanup", cleanupSession(CleanupStatus(state: .ready)), nil),
      ("live ready cleanup", liveCleanup, nil),
      ("multi-selected", liveWork(), 4),
      ("live chat", chatItem("c1", group: "g1"), nil),
      ("queued chat", queuedChat, nil),
      ("stopped manager", ofKind(.manager, live: false), nil),
      ("live manager", ofKind(.manager), nil),
      ("paused manager", pausedManager, nil),
      ("multi-selected manager", ofKind(.manager), 2),
      ("live operator", ofKind(.operator), nil),
    ]
  }()

  @Test(arguments: shapes.indices)
  func offersCopyLinkOnceInEveryShape(_ i: Int) {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)

    #expect(actions.filter { $0 == .copyLink }.count == 1, "\(Self.shapes[i].0)")
  }

  /// The sidebar's note icon shows only on a session with notes. The menu is how the user adds the first note.
  @Test(arguments: shapes.indices)
  func offersNotesOnceBeforeTheDividerInEveryShape(_ i: Int) throws {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)

    #expect(actions.filter { $0 == .notes }.count == 1, "\(Self.shapes[i].0)")
    let notes = try #require(actions.firstIndex(of: .notes), "\(Self.shapes[i].0)")
    #expect(notes < (actions.firstIndex(of: .divider) ?? actions.endIndex), "\(Self.shapes[i].0)")
  }

  @Test(arguments: shapes.indices)
  func endsWithNoDivider(_ i: Int) {
    let (_, s, count) = Self.shapes[i]

    #expect(SessionMenu.actions(for: s, selectionCount: count).last != .divider)
  }

  @Test(arguments: shapes.indices)
  func placesEachDividerDirectlyBeforeADestructiveAction(_ i: Int) {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)

    for (at, action) in actions.enumerated() where action == .divider {
      #expect(at + 1 < actions.count && isDestructive(actions[at + 1]), "\(Self.shapes[i].0)")
    }
  }

  @Test(arguments: shapes.indices)
  func placesNoDestructiveActionBeforeTheDivider(_ i: Int) {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)
    let firstDestructive = actions.firstIndex(where: isDestructive)

    #expect(firstDestructive.map { $0 > 0 && actions[$0 - 1] == .divider } ?? true, "\(Self.shapes[i].0)")
  }

  @Test(arguments: shapes.indices)
  func showsOneDividerExactlyWhenADestructiveActionShows(_ i: Int) {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)

    #expect(
      actions.filter { $0 == .divider }.count == (actions.contains(where: isDestructive) ? 1 : 0),
      "\(Self.shapes[i].0)")
  }

  @Test(arguments: shapes.indices)
  func putsDeleteLastWhenItShows(_ i: Int) {
    let actions = SessionMenu.actions(for: Self.shapes[i].1, selectionCount: Self.shapes[i].2)
    let deletes = actions.indices.filter { isDelete(actions[$0]) || isDeleteSelection(actions[$0]) }

    #expect(deletes.allSatisfy { $0 == actions.count - 1 }, "\(Self.shapes[i].0)")
  }
}

/// A row's Delete sends `rm-queue` with the scope whose rule the session meets, so sbd accepts any work session.
@MainActor
@Suite struct DeletingAnySession {
  @Test func scopesADoneSessionToDone() {
    #expect(BoardModel.deleteScope(notedSession([], state: .done)) == .done)
  }

  @Test(arguments: startedStates.filter { $0 != .done })
  func scopesASessionThatIsNotDoneToWork(_ state: AttentionState) {
    #expect(BoardModel.deleteScope(notedSession([], state: state)) == .work)
  }

  /// `done` is the rule of `isRemovableDone`, which a Done session that is not a work session fails.
  @Test(arguments: [SessionKind.manager, .chat, .operator])
  func scopesADoneSessionThatIsNotWorkToWork(_ kind: SessionKind) {
    var s = notedSession([], state: .done)
    s.kind = kind

    #expect(BoardModel.deleteScope(s) == .work)
  }

  @Test func scopesADoneFollowupThatWaitsToStartToWork() {
    var s = notedSession([], state: .done)
    s.followup = Followup(prompt: "p")

    #expect(BoardModel.deleteScope(s) == .work)
  }

  @Test func deletesANeedsYouSessionWithTheWorkScope() async {
    let s = notedSession(
      [todoFixture("n3", "tell Alex in #flags"), todoFixture("n4", "bump the SDK")], state: .needsYou)

    let sent = await firstRequest { $0.deleteSession(s, resolve: ["n3", "n4"]) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["scope"] == "work")
  }

  @Test func deletesANeedsYouSessionByItsId() async {
    let s = notedSession([], state: .needsYou)

    let sent = await firstRequest { $0.deleteSession(s) }

    #expect(sent.args["targets"] == ["s1"])
  }

  @Test func deletesANeedsYouSessionWithTheShownTodos() async {
    let s = notedSession(
      [todoFixture("n3", "tell Alex in #flags"), todoFixture("n4", "bump the SDK")], state: .needsYou)

    let sent = await firstRequest { $0.deleteSession(s, resolve: TodoDeletion(s).ids) }

    #expect(sent.args["resolve"] == ["n3", "n4"])
  }

  @Test func deletesADoneSessionWithTheDoneScope() async {
    let s = notedSession([], state: .done)

    let sent = await firstRequest { $0.deleteSession(s) }

    #expect(sent.op == "rm-queue")
    #expect(sent.args["scope"] == "done")
  }
}
