import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let paused = Pause(by: .you, since: 0)

private func liveWork() -> SessionSummary { needsItem("s1") }

private func stoppedWork() -> SessionSummary {
  var s = needsItem("s1")
  s.live = false
  return s
}

private func ofKind(_ kind: SessionKind, live: Bool = true) -> SessionSummary {
  var s = needsItem("s1")
  s.kind = kind
  s.live = live
  return s
}

private func removal(_ state: Removal.State) -> Removal {
  var r = Removal(requested: 0, notBefore: 0, worktree: true, branch: false, remoteBranch: false, resolve: [])
  r.state = state
  return r
}

/// A session in the worktree of branch haacked/fix whose PR is in `state`.
private func worktreeWithPR(state: String, status: String) -> SessionSummary {
  var s = notedSession([])
  s.pr = try! JSONDecoder().decode(
    PRSummary.self,
    from: Data(
      """
      {"number":7,"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"Fix","state":"\(state)","status":"\(status)"}
      """.utf8))
  return s
}

private func isRun(_ a: SessionAction) -> Bool {
  if case .run = a { return true }
  return false
}

/// The input shapes of the plan's Risks 3 and 4, each with the run control that the header's old `if`/`else if`
/// chain chose for it: paused, else live, else queued, else stopped.
private enum Shapes {
  static let all: [(name: String, session: SessionSummary, run: SessionRunControl)] = {
    var pausedLive = liveWork()
    pausedLive.pause = paused
    var pausedStopped = stoppedWork()
    pausedStopped.pause = paused
    var pausedQueuedStopped = stoppedWork()
    pausedQueuedStopped.pause = paused
    pausedQueuedStopped.queued = true
    var queuedStopped = stoppedWork()
    queuedStopped.queued = true
    var queuedLive = liveWork()
    queuedLive.queued = true
    var notQueuedStopped = stoppedWork()
    notQueuedStopped.queued = false
    var removedFolder = cleanupSession(CleanupStatus(state: .removed))
    removedFolder.live = false
    var pausedRemovedFolder = removedFolder
    pausedRemovedFolder.pause = paused
    var markedDone = stoppedWork()
    markedDone.markedDone = true
    var failedRemoval = stoppedWork()
    failedRemoval.removal = removal(.failed)
    var queuedRemoval = stoppedWork()
    queuedRemoval.removal = removal(.queued)
    var runningRemoval = liveWork()
    runningRemoval.removal = removal(.running)
    var pausedManager = ofKind(.manager)
    pausedManager.pause = paused
    return [
      ("paused and live", pausedLive, .resumePaused),
      ("paused and stopped", pausedStopped, .resumePaused),
      ("paused, queued, and stopped", pausedQueuedStopped, .resumePaused),
      ("paused without terminals", pausedRemovedFolder, .resumePaused),
      ("live", liveWork(), .stop),
      ("queued and stopped", queuedStopped, .startNow),
      ("queued and live", queuedLive, .stop),
      ("stopped in a folder with no repo, queued is nil", stoppedWork(), .restart),
      ("stopped and queued is false", notQueuedStopped, .restart),
      ("stopped without terminals", removedFolder, .restart),
      ("marked done", markedDone, .restart),
      ("cleanup ready", cleanupSession(CleanupStatus(state: .ready)), .restart),
      ("cleanup blocked", cleanupSession(CleanupStatus(state: .blocked, reason: "uncommitted files")), .restart),
      ("worktree with no PR", notedSession([]), .restart),
      ("worktree with a merged PR", worktreeWithPR(state: "MERGED", status: "Merged"), .restart),
      ("worktree with an open PR", worktreeWithPR(state: "OPEN", status: "Review required"), .restart),
      ("failed removal", failedRemoval, .restart),
      ("queued removal", queuedRemoval, .restart),
      ("running removal", runningRemoval, .stop),
      ("live manager", ofKind(.manager), .stop),
      ("stopped manager", ofKind(.manager, live: false), .restart),
      ("paused manager", pausedManager, .resumePaused),
      ("live chat", chatItem("c1", group: "g1"), .stop),
      ("live operator", operatorItem(), .stop),
      ("stopped operator", ofKind(.operator, live: false), .restart),
    ]
  }()
}

/// The header's one button that starts or stops claude, chosen in the order of the old header: paused, then live,
/// then queued, then stopped.
@Suite struct SessionActionsRunControl {
  @Test(arguments: Shapes.all.indices)
  func choosesTheSameRunControlAsTheOldHeader(_ i: Int) {
    let (name, s, expected) = Shapes.all[i]

    #expect(SessionRunControl.of(s) == expected, "\(name)")
  }

  @Test func resumesAPausedSessionEvenWhileClaudeRuns() {
    var s = liveWork()
    s.pause = paused

    #expect(SessionRunControl.of(s) == .resumePaused)
  }

  @Test func stopsALiveSessionEvenWhenItIsQueued() {
    var s = liveWork()
    s.queued = true

    #expect(SessionRunControl.of(s) == .stop)
  }

  @Test func startsAQueuedSessionThatIsNotRunningNow() {
    var s = stoppedWork()
    s.queued = true

    #expect(SessionRunControl.of(s) == .startNow)
  }

  @Test(arguments: [Bool?.none, false])
  func restartsAStoppedSessionThatIsNotQueued(_ queued: Bool?) {
    var s = stoppedWork()
    s.queued = queued

    #expect(SessionRunControl.of(s) == .restart)
  }

  @Test(arguments: Shapes.all.indices)
  func listsTheRunControlFirstAndOnce(_ i: Int) {
    let (name, s, expected) = Shapes.all[i]

    let actions = SessionActions.list(for: s)

    #expect(actions.first == .run(expected), "\(name)")
    #expect(actions.filter(isRun).count == 1, "\(name)")
  }
}

/// Pause shows exactly when the session can pause: it is not paused and it has terminals.
@Suite struct SessionActionsPause {
  @Test func offersPauseForALiveSession() {
    #expect(SessionActions.list(for: liveWork()).contains(.pause))
  }

  @Test func offersPauseForAStoppedSessionWithTerminals() {
    #expect(SessionActions.list(for: stoppedWork()).contains(.pause))
  }

  @Test func offersNoPauseForAPausedSession() {
    var s = liveWork()
    s.pause = paused

    #expect(!SessionActions.list(for: s).contains(.pause))
  }

  /// The cleanup removed the folder, so the session has no terminals.
  @Test func offersNoPauseWithoutTerminals() {
    var s = cleanupSession(CleanupStatus(state: .removed))
    s.live = false

    #expect(!SessionActions.list(for: s).contains(.pause))
  }

  /// A session with no folder runs no claude.
  @Test func offersNoPauseForASessionWithNoFolder() {
    var s = stoppedWork()
    s.cwd = ""

    #expect(!SessionActions.list(for: s).contains(.pause))
  }

  @Test(arguments: [SessionKind.work, .manager, .chat, .operator])
  func offersPauseForALiveSessionOfAnyKind(_ kind: SessionKind) {
    #expect(SessionActions.list(for: ofKind(kind)).contains(.pause))
  }

  @Test func placesPauseDirectlyAfterTheRunControl() {
    let actions = SessionActions.list(for: liveWork())

    #expect(actions.firstIndex(of: .pause) == 1)
  }
}

@Suite struct SessionActionsDone {
  @Test func offersMarkDoneForASessionNotMarkedDone() {
    #expect(SessionActions.list(for: liveWork()).contains(.done(marked: false)))
  }

  @Test func offersMarkNotDoneForASessionMarkedDone() {
    var s = liveWork()
    s.markedDone = true

    #expect(SessionActions.list(for: s).contains(.done(marked: true)))
  }

  @Test(arguments: Shapes.all.indices)
  func offersDoneOnceInEveryShape(_ i: Int) {
    let (name, s, _) = Shapes.all[i]

    let dones = SessionActions.list(for: s).filter { if case .done = $0 { true } else { false } }

    #expect(dones == [.done(marked: s.markedDone)], "\(name)")
  }
}

/// Clean Up shows only when every check of the cleanup passed.
@Suite struct SessionActionsCleanUp {
  @Test func offersCleanUpWhenTheCleanupIsReady() {
    #expect(SessionActions.list(for: cleanupSession(CleanupStatus(state: .ready))).contains(.cleanUp))
  }

  @Test(arguments: [
    CleanupStatus?.none,
    CleanupStatus(state: .blocked, reason: "the worktree has uncommitted files"),
    CleanupStatus(state: .removed),
  ])
  func offersNoCleanUpUnlessTheCleanupIsReady(_ cleanup: CleanupStatus?) {
    #expect(!SessionActions.list(for: cleanupSession(cleanup)).contains(.cleanUp))
  }

  @Test func placesCleanUpAfterTheSidePanelAndBeforeDelete() {
    let actions = SessionActions.list(for: cleanupSession(CleanupStatus(state: .ready)))

    #expect(Array(actions.suffix(3)) == [.sidePanel, .cleanUp, .delete])
  }
}

/// The header's trash showed for every session that a session view shows. Delete, Notes, and the side panel toggle
/// stay unconditional, whatever the session's kind, state, or removal.
@Suite struct SessionActionsAlwaysOffered {
  @Test(arguments: Shapes.all.indices)
  func offersDeleteLastInEveryShape(_ i: Int) {
    let (name, s, _) = Shapes.all[i]

    let actions = SessionActions.list(for: s)

    #expect(actions.last == .delete, "\(name)")
    #expect(actions.filter { $0 == .delete }.count == 1, "\(name)")
  }

  @Test(arguments: Shapes.all.indices)
  func offersNotesOnceInEveryShape(_ i: Int) {
    let (name, s, _) = Shapes.all[i]

    #expect(SessionActions.list(for: s).filter { $0 == .notes }.count == 1, "\(name)")
  }

  @Test(arguments: Shapes.all.indices)
  func offersTheSidePanelOnceInEveryShape(_ i: Int) {
    let (name, s, _) = Shapes.all[i]

    #expect(SessionActions.list(for: s).filter { $0 == .sidePanel }.count == 1, "\(name)")
  }

  /// `SessionMenu` offers no Delete for a chat, the Operator, or a session with a removal. The header's trash does,
  /// and this change keeps it that way.
  @Test(
    arguments: [SessionKind.work, .manager, .chat, .operator],
    [Removal.State?.none, .queued, .running, .failed])
  func offersDeleteForEveryKindAndRemovalState(_ kind: SessionKind, _ state: Removal.State?) {
    var s = ofKind(kind)
    s.removal = state.map(removal)

    #expect(SessionActions.list(for: s).last == .delete, "\(kind) \(String(describing: state))")
  }

  @Test(arguments: [true, false])
  func offersDeleteForAManagerConversationWhetherOrNotClaudeRuns(_ live: Bool) {
    #expect(SessionActions.list(for: ofKind(.manager, live: live)).contains(.delete))
  }

  @Test func offersDeleteForAWorktreeSessionWhoseFolderTheCleanupRemoved() {
    var s = cleanupSession(CleanupStatus(state: .removed))
    s.live = false

    #expect(SessionActions.list(for: s).contains(.delete))
  }
}

/// The whole list for the shapes that show each optional action, in the header's order: run, pause, done, notes,
/// side panel, clean up, delete.
@Suite struct SessionActionsOrder {
  @Test func listsEveryActionOfALiveSession() {
    #expect(
      SessionActions.list(for: liveWork()) == [
        .run(.stop), .pause, .done(marked: false), .notes, .sidePanel, .delete,
      ])
  }

  @Test func listsEveryActionOfAPausedSession() {
    var s = liveWork()
    s.pause = paused

    #expect(
      SessionActions.list(for: s) == [.run(.resumePaused), .done(marked: false), .notes, .sidePanel, .delete])
  }

  @Test func listsEveryActionOfAQueuedSession() {
    var s = stoppedWork()
    s.queued = true

    #expect(
      SessionActions.list(for: s) == [
        .run(.startNow), .pause, .done(marked: false), .notes, .sidePanel, .delete,
      ])
  }

  @Test func listsEveryActionOfASessionWhoseCleanupIsReady() {
    var s = cleanupSession(CleanupStatus(state: .ready))
    s.markedDone = true

    #expect(
      SessionActions.list(for: s) == [
        .run(.restart), .pause, .done(marked: true), .notes, .sidePanel, .cleanUp, .delete,
      ])
  }

  @Test func listsEveryActionOfASessionWithoutTerminals() {
    var s = cleanupSession(CleanupStatus(state: .removed))
    s.live = false

    #expect(
      SessionActions.list(for: s) == [.run(.restart), .done(marked: false), .notes, .sidePanel, .delete])
  }
}
