import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A work session with `reason` and, when `column` is not nil, a placement in that column.
private func boardCard(
  _ column: BoardColumn?, state: AttentionState = .waiting, reason: String = "Running the flag tests",
  line: String? = nil, holder: BoardHolder? = nil, back: BoardMove? = nil
) -> SessionSummary {
  var s = needsItem("s1", state: state)
  s.reason = reason
  s.board = column.map { BoardPlacement(column: $0, since: 0, line: line, holder: holder, back: back) }
  return s
}

@Suite struct BoardModelCardTests {
  // MARK: The column line

  @Suite struct ColumnLine {
    /// `place` takes no reason, so it leaves the In progress line nil and the card shows the session's reason.
    @Test func anInProgressCardShowsTheSessionsReason() {
      let s = boardCard(.inProgress, state: .working, reason: "Writing the migration")

      #expect(s.boardLine == "Writing the migration")
    }

    /// `MergeBoard.column` puts a session without a placement in In progress.
    @Test func aCardWithoutAPlacementShowsTheSessionsReason() {
      let s = boardCard(nil, state: .notStarted, reason: "Waiting to start")

      #expect(s.boardLine == "Waiting to start")
    }

    @Test(arguments: [
      (BoardColumn.waiting, "CI running"),
      (.inReview, "waits on alice, CI running"),
      (.approved, "approved by bob"),
      (.merging, "Trunk testing: running the queue's tests"),
    ])
    func aPRColumnCardShowsThePlacementsLineNotTheReason(_ column: BoardColumn, _ line: String) {
      let s = boardCard(column, reason: "Something Claude said", line: line)

      #expect(s.boardLine == line)
    }

    /// A Waiting card can wait on nothing that `place` names, and a Done card has no line.
    @Test(arguments: [BoardColumn.waiting, .done])
    func aCardWhosePlacementHasNoLineShowsTheSessionsReason(_ column: BoardColumn) {
      let s = boardCard(column, reason: "Asked which flag to remove", line: nil)

      #expect(s.boardLine == "Asked which flag to remove")
    }

    @Test func anInProgressCardIgnoresAnyPlacementLine() {
      let s = boardCard(.inProgress, state: .working, reason: "Writing the migration", line: "stale line")

      #expect(s.boardLine == "Writing the migration")
    }
  }

  // MARK: The holder badge

  @Suite struct HolderBadge {
    @Test(arguments: [
      (BoardHolder.you, "you"),
      (.machine, "a machine"),
      (.session, "another session"),
    ])
    func eachHolderReadsAsThePlanNamesIt(_ holder: BoardHolder, _ words: String) {
      #expect(holder.badgeTitle.lowercased() == words)
    }

    @Test func aWaitingCardShowsItsHolder() {
      #expect(boardCard(.waiting, holder: .machine).holderBadge == .machine)
    }

    @Test func aWaitingCardWithoutAHolderShowsNoBadge() {
      #expect(boardCard(.waiting, holder: nil).holderBadge == nil)
    }

    /// sbd sets a holder only on Waiting. A holder on another column would be a stale or wrong one.
    @Test(arguments: [BoardColumn.inProgress, .inReview, .approved, .merging, .done])
    func aCardOutsideWaitingShowsNoBadge(_ column: BoardColumn) {
      #expect(boardCard(column, holder: .you).holderBadge == nil)
    }

    @Test func aCardWithoutAPlacementShowsNoBadge() {
      #expect(boardCard(nil).holderBadge == nil)
    }
  }

  // MARK: The "back from" note

  @Suite struct BackNote {
    @Test(arguments: [
      (BoardColumn.merging, "CI failed", "back from Merging: CI failed"),
      (.approved, "new commits", "back from Approved: new commits"),
      (.inReview, "changes requested by alex", "back from In review: changes requested by alex"),
      (
        .merging, "removed from the queue (Cancelled): flaky test",
        "back from Merging: removed from the queue (Cancelled): flaky test"
      ),
    ])
    func readsBackFromTheColumnTitleAndTheReason(_ from: BoardColumn, _ reason: String, _ note: String) {
      let s = boardCard(.waiting, back: BoardMove(from: from, reason: reason, at: 0))

      #expect(s.backNote == note)
    }

    /// `back` can stand in any column, such as a PR whose session started a turn after the move.
    @Test(arguments: BoardColumn.allCases)
    func showsInEveryColumn(_ column: BoardColumn) {
      let s = boardCard(column, back: BoardMove(from: .approved, reason: "new commits", at: 0))

      #expect(s.backNote == "back from Approved: new commits")
    }

    @Test func aCardWithoutAMoveBackHasNoNote() {
      #expect(boardCard(.waiting, back: nil).backNote == nil)
    }

    @Test func aCardWithoutAPlacementHasNoNote() {
      #expect(boardCard(nil).backNote == nil)
    }
  }

  // MARK: The Needs you edge

  @Suite struct NeedsYouEdge {
    @Test(arguments: AttentionState.allCases)
    func onlyANeedsYouSessionGetsTheEdge(_ state: AttentionState) {
      #expect(boardCard(.waiting, state: state).hasNeedsYouEdge == (state == .needsYou))
    }

    /// Needs you does not move a card, so the edge shows in whatever column holds it.
    @Test(arguments: BoardColumn.allCases)
    func aNeedsYouCardGetsTheEdgeInEveryColumn(_ column: BoardColumn) {
      #expect(boardCard(column, state: .needsYou).hasNeedsYouEdge)
    }

    @Test func aNeedsYouCardWithoutAPlacementGetsTheEdge() {
      #expect(boardCard(nil, state: .needsYou).hasNeedsYouEdge)
    }

    /// `Attention.shown` moves an acknowledged verdict to Waiting, so the user already answered it.
    @Test func anAcknowledgedCardInWaitingGetsNoEdge() {
      var s = boardCard(.waiting, state: .waiting, holder: .you)
      s.acknowledged = true

      #expect(!s.hasNeedsYouEdge)
    }
  }
}
