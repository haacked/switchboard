import Foundation
import Testing

@testable import SwitchboardCore

private let repo = "haacked/switchboard"
private let group = "g49tj7"

private func gate(target: Int = 3, repo gateRepo: String = repo, group gateGroup: String = group) -> Schedule.Gate {
  Schedule.Gate(group: gateGroup, repo: gateRepo, target: target, template: "Run /go on {url}", rubric: "Bugs first")
}

/// A started work session in the gate's group and repository that counts as active, unless an argument changes that.
/// `repositoryRead` defaults to whether the row has a repository, so a nil repository means sbd hasn't read it.
private func row(
  _ id: String = "s1", state: AttentionState = .working, kind: SessionKind = .work, group rowGroup: String? = group,
  repository: String? = repo, repositoryRead: Bool? = nil, markedDone: Bool = false, paused: Bool = false,
  removing: Bool = false, unreadHost: Bool = false, prMerged: Bool = false, hasMergeAction: Bool = false,
  hasRemovalAction: Bool = false, started: Bool = true, startWaitingForSlot: Bool = false
) -> QueueStatus.Row {
  QueueStatus.Row(
    id: id, name: "session \(id)", kind: kind, group: rowGroup, repository: repository,
    repositoryRead: repositoryRead ?? (repository != nil), markedDone: markedDone, paused: paused, removing: removing,
    state: state, unreadHost: unreadHost, prMerged: prMerged, hasMergeAction: hasMergeAction,
    hasRemovalAction: hasRemovalAction, started: started, startWaitingForSlot: startWaitingForSlot)
}

private func queueStatus(_ rows: [QueueStatus.Row], target: Int = 3) -> QueueStatus {
  QueueStatus.compute(rows, gate: gate(target: target))
}

private func isOpen(_ decision: QueueStatus.Decision) -> Bool {
  if case .open = decision { return true }
  return false
}

private func reasons(_ decision: QueueStatus.Decision) -> [String] {
  if case .open(let reasons) = decision { return reasons }
  return []
}

/// Rows that neither count nor open the gate, so the decision is `topup(target)`.
private func isIgnored(_ r: QueueStatus.Row) -> Bool {
  let s = queueStatus([r], target: 3)
  return s.counted.isEmpty && s.unknown.isEmpty && s.needsAttention.isEmpty && s.decision == .topup(k: 3)
}

/// The suites nest under one name, so `--filter QueueStatusTests` runs them all.
@Suite struct QueueStatusTests {}

// MARK: - Counted

extension QueueStatusTests {
  @Suite struct Counted {
    /// Ready to merge counts only with a merge action wait, so it gets one here.
    @Test(arguments: [
      AttentionState.stale, .canContinue, .waiting, .working, .readyForReview, .readyToMerge,
    ])
    func aStartedWorkRowInEachActiveStateCounts(_ state: AttentionState) {
      let s = queueStatus([row(state: state, hasMergeAction: true)])

      #expect(s.counted.map(\.id) == ["s1"], "\(state)")
    }

    @Test(arguments: [AttentionState.stale, .canContinue, .waiting, .working, .readyForReview])
    func aStartedWorkRowInEachActiveStateLeavesTheGateClosedAtTarget(_ state: AttentionState) {
      let s = queueStatus([row(state: state)], target: 1)

      #expect(s.decision == .gated, "\(state)")
    }

    @Test func needsYouDoesNotCount() {
      let s = queueStatus([row(state: .needsYou)])

      #expect(s.counted.isEmpty)
      #expect(!isOpen(s.decision))
    }

    @Test func notStartedDoesNotCount() {
      #expect(queueStatus([row(state: .notStarted)]).counted.isEmpty)
    }

    @Test func doneWithARemovalActionDoesNotCount() {
      #expect(queueStatus([row(state: .done, hasRemovalAction: true)]).counted.isEmpty)
    }

    @Test func aRowMarkedDoneDoesNotCount() {
      #expect(queueStatus([row(state: .working, markedDone: true)]).counted.isEmpty)
    }

    @Test func aPausedRowDoesNotCount() {
      #expect(queueStatus([row(state: .working, paused: true)]).counted.isEmpty)
    }

    @Test func aRowBeingRemovedDoesNotCount() {
      #expect(queueStatus([row(state: .working, removing: true)]).counted.isEmpty)
    }

    @Test func aMergedPRWithARemovalActionDoesNotCount() {
      #expect(queueStatus([row(state: .waiting, prMerged: true, hasRemovalAction: true)]).counted.isEmpty)
    }

    /// A start whose message waits behind the live cap has no first prompt yet, so it reads Needs you until a slot
    /// frees.
    @Test(arguments: [AttentionState.needsYou, .notStarted])
    func aStartWaitingForASlotCounts(_ state: AttentionState) {
      let s = queueStatus([row(state: state, startWaitingForSlot: true)], target: 1)

      #expect(s.counted.map(\.id) == ["s1"], "\(state)")
      #expect(s.decision == .gated, "\(state)")
    }

    @Test func aStartWaitingForASlotMarkedDonePausedRemovedOrMergedDoesNotCount() {
      let rows = [
        row("a", state: .needsYou, markedDone: true, startWaitingForSlot: true),
        row("b", state: .needsYou, paused: true, startWaitingForSlot: true),
        row("c", state: .needsYou, removing: true, startWaitingForSlot: true),
        row("d", state: .needsYou, prMerged: true, hasRemovalAction: true, startWaitingForSlot: true),
      ]

      #expect(queueStatus(rows).counted.isEmpty)
    }

    @Test func eachActiveRowCountsOnce() {
      let s = queueStatus([row("a"), row("b", state: .waiting), row("c", state: .needsYou)], target: 5)

      #expect(Set(s.counted.map(\.id)) == ["a", "b"])
    }
  }
}

// MARK: - Rows that are not rows

extension QueueStatusTests {
  /// Only started work sessions in the gate's group are rows, and only rows in the gate's repository count.
  @Suite struct NotRows {
    @Test func aRowInAnotherRepositoryIsIgnored() {
      #expect(isIgnored(row(repository: "haacked/dotfiles")))
    }

    @Test func aRowInAnotherGroupIsIgnored() {
      #expect(isIgnored(row(group: "zz11aa")))
    }

    @Test func aRowInNoGroupIsIgnored() {
      #expect(isIgnored(row(group: nil)))
    }

    @Test func aFollowupThatHasNotStartedIsIgnored() {
      #expect(isIgnored(row(state: .notStarted, started: false)))
    }

    /// A follow-up that hasn't started has no repository read and may have no connected host, yet it is not a row.
    @Test func aFollowupThatHasNotStartedWithAnUnknownRepositoryAndAnUnreadHostDoesNotOpenTheGate() {
      #expect(isIgnored(row(state: .notStarted, repository: nil, unreadHost: true, started: false)))
    }

    @Test(arguments: [SessionKind.manager, .chat, .operator])
    func aRowOfAnotherKindIsIgnoredWhenActive(_ kind: SessionKind) {
      #expect(isIgnored(row(state: .working, kind: kind)), "\(kind)")
    }

    @Test(arguments: [SessionKind.manager, .chat, .operator])
    func aRowOfAnotherKindIsIgnoredWhenReadyToMergeWithoutAMergeAction(_ kind: SessionKind) {
      #expect(isIgnored(row(state: .readyToMerge, kind: kind)), "\(kind)")
    }

    @Test(arguments: [SessionKind.manager, .chat, .operator])
    func aRowOfAnotherKindIsIgnoredWhenItsRepositoryIsUnknown(_ kind: SessionKind) {
      #expect(isIgnored(row(kind: kind, repository: nil)), "\(kind)")
    }

    @Test(arguments: [SessionKind.manager, .chat, .operator])
    func aRowOfAnotherKindIsIgnoredWhenItsHostIsUnread(_ kind: SessionKind) {
      #expect(isIgnored(row(kind: kind, unreadHost: true)), "\(kind)")
    }

    @Test func aRowInAnotherGroupIsIgnoredWhenItsRepositoryIsUnknown() {
      #expect(isIgnored(row(group: "zz11aa", repository: nil)))
    }

    @Test func aRowInAnotherGroupIsIgnoredWhenItsHostIsUnread() {
      #expect(isIgnored(row(group: "zz11aa", unreadHost: true)))
    }

    @Test func aRowInAnotherGroupIsIgnoredWhenReadyToMergeWithoutAMergeAction() {
      #expect(isIgnored(row(state: .readyToMerge, group: "zz11aa")))
    }

    @Test func aReadyToMergeRowInAnotherRepositoryDoesNotOpenTheGate() {
      #expect(isIgnored(row(state: .readyToMerge, repository: "haacked/dotfiles")))
    }

    @Test func aDoneRowInAnotherRepositoryDoesNotOpenTheGate() {
      #expect(isIgnored(row(state: .done, repository: "haacked/dotfiles")))
    }

    @Test func aMergedRowInAnotherRepositoryDoesNotOpenTheGate() {
      #expect(isIgnored(row(state: .waiting, repository: "haacked/dotfiles", prMerged: true)))
    }
  }
}

// MARK: - Unknown

extension QueueStatusTests {
  @Suite struct Unknown {
    @Test func aRowWhoseRepositoryIsUnknownOpensTheGate() {
      let s = queueStatus([row(repository: nil)])

      #expect(isOpen(s.decision))
    }

    @Test func aRowWhoseRepositoryIsUnknownIsListedAsUnknown() {
      #expect(queueStatus([row(repository: nil)]).unknown.map(\.id) == ["s1"])
    }

    @Test func aRowWhoseRepositoryIsUnknownDoesNotCount() {
      #expect(queueStatus([row(repository: nil)]).counted.isEmpty)
    }

    @Test func aReadRowWithNoRepositoryIsUnknownOnlyUntilSbdReadsIt() {
      #expect(queueStatus([row(repository: nil, repositoryRead: false)]).unknown.map(\.id) == ["s1"])
      #expect(isIgnored(row(repository: nil, repositoryRead: true)))
    }

    /// A session whose checkout isn't on GitHub can't be in the gate's repository, so it doesn't hold the gate open.
    @Test func aReadRowOffGitHubLeavesAFullQueueGated() {
      let rows = [row("a"), row("b"), row("c"), row("d", repository: nil, repositoryRead: true)]

      #expect(queueStatus(rows, target: 3).decision == .gated)
    }

    @Test(arguments: ["", "switchboard", "haacked/switchboard/extra"])
    func aRowWhoseRepositoryIsNotOwnerSlashNameOpensTheGate(_ bad: String) {
      let s = queueStatus([row(repository: bad)])

      #expect(isOpen(s.decision), "\(bad)")
      #expect(s.unknown.map(\.id) == ["s1"], "\(bad)")
    }

    @Test func aRowWithAnUnreadHostOpensTheGate() {
      #expect(isOpen(queueStatus([row(unreadHost: true)]).decision))
    }

    @Test func aRowWithAnUnreadHostIsListedAsUnknown() {
      #expect(queueStatus([row(unreadHost: true)]).unknown.map(\.id) == ["s1"])
    }

    /// Decision 35 lists an unread host as unknown without a repository condition: the stored repository may be stale.
    @Test func aRowWithAnUnreadHostInAnotherRepositoryOpensTheGate() {
      #expect(isOpen(queueStatus([row(repository: "haacked/dotfiles", unreadHost: true)]).decision))
    }

    @Test(arguments: [AttentionState.needsYou, .done, .notStarted, .working, .readyToMerge])
    func anUnknownRowOpensTheGateWhateverItsState(_ state: AttentionState) {
      #expect(isOpen(queueStatus([row(state: state, repository: nil, hasMergeAction: true)]).decision), "\(state)")
    }

    @Test func anUnknownRowOpensTheGateWhenTheQueueIsFull() {
      let rows = [row("a"), row("b"), row("c"), row("d", repository: nil)]

      #expect(isOpen(queueStatus(rows, target: 3).decision))
    }

    @Test func anUnknownRowOpensTheGateWhenTheQueueIsShort() {
      #expect(isOpen(queueStatus([row("a"), row("b", unreadHost: true)], target: 3).decision))
    }

    @Test func theReasonsNameTheUnknownRow() {
      let reasons = reasons(queueStatus([row("x7", repository: nil)]).decision)

      #expect(reasons.contains { $0.contains("session x7") })
    }
  }
}

// MARK: - Needs attention

extension QueueStatusTests {
  @Suite struct NeedsAttention {
    @Test func readyToMergeWithoutAMergeActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .readyToMerge)]).decision))
    }

    @Test func readyToMergeWithoutAMergeActionIsListedAsNeedingAttention() {
      #expect(queueStatus([row(state: .readyToMerge)]).needsAttention.map(\.id) == ["s1"])
    }

    @Test func readyToMergeWithAMergeActionCounts() {
      let s = queueStatus([row(state: .readyToMerge, hasMergeAction: true)])

      #expect(s.counted.map(\.id) == ["s1"])
      #expect(!isOpen(s.decision))
    }

    /// A removal wait does not merge the PR, so it does not stand in for a merge action.
    @Test func readyToMergeWithOnlyARemovalActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .readyToMerge, hasRemovalAction: true)]).decision))
    }

    @Test func doneWithoutARemovalActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .done)]).decision))
    }

    @Test func doneWithoutARemovalActionIsListedAsNeedingAttention() {
      #expect(queueStatus([row(state: .done)]).needsAttention.map(\.id) == ["s1"])
    }

    /// A merge wait does not remove the worktree, so it does not stand in for a removal action.
    @Test func doneWithOnlyAMergeActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .done, hasMergeAction: true)]).decision))
    }

    @Test func doneWithARemovalActionDoesNotOpenTheGate() {
      let s = queueStatus([row(state: .done, hasRemovalAction: true)])

      #expect(!isOpen(s.decision))
      #expect(s.needsAttention.isEmpty)
    }

    @Test(arguments: [AttentionState.waiting, .working, .readyForReview, .canContinue, .stale, .needsYou])
    func aMergedPRWithoutARemovalActionOpensTheGate(_ state: AttentionState) {
      #expect(isOpen(queueStatus([row(state: state, prMerged: true)]).decision), "\(state)")
    }

    @Test func aMergedPRWithOnlyAMergeActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .waiting, prMerged: true, hasMergeAction: true)]).decision))
    }

    @Test func aMergedPRWithARemovalActionDoesNotOpenTheGate() {
      let s = queueStatus([row(state: .waiting, prMerged: true, hasRemovalAction: true)])

      #expect(!isOpen(s.decision))
      #expect(s.needsAttention.isEmpty)
    }

    /// A row the user marked done still has a worktree to remove after its PR merged.
    @Test func aRowMarkedDoneWhosePRMergedWithoutARemovalActionOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .done, markedDone: true, prMerged: true)]).decision))
    }

    /// Decision 35 doesn't say that GitHub names compare without case. A case-sensitive compare would ignore this row,
    /// and the gate would skip the merge that the row needs (Risk 8).
    @Test func readyToMergeInTheGatesRepositoryWrittenInAnotherCaseOpensTheGate() {
      #expect(isOpen(queueStatus([row(state: .readyToMerge, repository: "Haacked/Switchboard")]).decision))
    }

    @Test func anActiveRowInTheGatesRepositoryWrittenInAnotherCaseCounts() {
      #expect(queueStatus([row(repository: "Haacked/Switchboard")]).counted.map(\.id) == ["s1"])
    }

    @Test func theReasonsNameTheRowThatNeedsAttention() {
      let reasons = reasons(queueStatus([row("m3", state: .readyToMerge)]).decision)

      #expect(reasons.contains { $0.contains("session m3") })
    }
  }
}

// MARK: - Decision

extension QueueStatusTests {
  @Suite struct GateDecision {
    @Test func activeEqualToTargetIsGated() {
      #expect(queueStatus([row("a"), row("b"), row("c")], target: 3).decision == .gated)
    }

    @Test func activeAboveTargetIsGated() {
      #expect(queueStatus([row("a"), row("b"), row("c"), row("d")], target: 3).decision == .gated)
    }

    @Test func shortByTwoTopsUpTwo() {
      #expect(queueStatus([row("a"), row("b"), row("c")], target: 5).decision == .topup(k: 2))
    }

    @Test func noRowsTopsUpToTheTarget() {
      #expect(queueStatus([], target: 4).decision == .topup(k: 4))
    }

    @Test func uncountedRowsDoNotReduceTheTopUp() {
      let rows = [
        row("a"), row("b", state: .needsYou), row("c", paused: true), row("d", repository: "haacked/dotfiles"),
      ]

      #expect(queueStatus(rows, target: 3).decision == .topup(k: 2))
    }

    @Test func shortAndANeedsAttentionRowOpensTheGate() {
      #expect(isOpen(queueStatus([row("a"), row("b", state: .readyToMerge)], target: 5).decision))
    }

    @Test func fullAndANeedsAttentionRowOpensTheGate() {
      let rows = [row("a"), row("b"), row("c"), row("d", state: .done)]

      #expect(isOpen(queueStatus(rows, target: 3).decision))
    }

    @Test func fullAndAnUnknownRowOpensTheGate() {
      let rows = [row("a"), row("b"), row("c"), row("d", unreadHost: true)]

      #expect(isOpen(queueStatus(rows, target: 3).decision))
    }

    @Test func oneNeedsAttentionRowAmongManyActiveRowsOpensTheGate() {
      let rows = (0..<10).map { row("a\($0)") } + [row("m", state: .readyToMerge)]

      #expect(isOpen(queueStatus(rows, target: 3).decision))
    }

    @Test func theDecisionListsAReasonForEachUnknownAndNeedsAttentionRow() {
      let rows = [row("u", repository: nil), row("m", state: .readyToMerge), row("d", state: .done)]

      #expect(reasons(queueStatus(rows).decision).count == 3)
    }
  }
}

// MARK: - Lines

extension QueueStatusTests {
  @Suite struct Lines {
    @Test func theLinesGiveTheActiveCountAgainstTheTarget() {
      let lines = queueStatus([row("a"), row("b")], target: 5).lines

      #expect(lines.joined(separator: "\n").contains("2/5"))
    }

    @Test func theLinesNameARowThatNeedsAttention() {
      let lines = queueStatus([row("m3", state: .readyToMerge)]).lines

      #expect(lines.joined(separator: "\n").contains("session m3"))
    }

    @Test func theLinesNameAnUnknownRow() {
      let lines = queueStatus([row("u9", repository: nil)]).lines

      #expect(lines.joined(separator: "\n").contains("session u9"))
    }
  }
}

// MARK: - The re-check before each start

extension QueueStatusTests {
  @Suite struct StartRefusal {
    @Test func aShortGroupAllowsAStart() {
      #expect(QueueStatus.startRefusal([row("a")], gate: gate(target: 2), started: []) == nil)
    }

    @Test func theSessionsThatTheTopupStartedCountTowardTheTarget() {
      let refusal = QueueStatus.startRefusal([row("a")], gate: gate(target: 2), started: ["new"])

      #expect(refusal == "the group has its target of 2 active sessions")
    }

    @Test func aStartedSessionCountsOnceWhenItsRowCountsToo() {
      #expect(QueueStatus.startRefusal([row("new")], gate: gate(target: 2), started: ["new"]) == nil)
    }

    /// sbd reads the repository of a session after it starts, so its row is unknown at first.
    @Test func anUnknownRowOfAStartedSessionDoesNotRefuse() {
      let unread = row("new", state: .needsYou, repository: nil)

      #expect(QueueStatus.startRefusal([unread], gate: gate(target: 2), started: ["new"]) == nil)
    }

    @Test func anUnknownRowRefuses() {
      let refusal = QueueStatus.startRefusal([row("a", unreadHost: true)], gate: gate(target: 2), started: [])

      #expect(refusal?.hasPrefix("the gate opened: ") == true, "\(String(describing: refusal))")
    }

    @Test func aRowThatNeedsAttentionRefuses() {
      let refusal = QueueStatus.startRefusal([row("a", state: .done)], gate: gate(target: 2), started: [])

      #expect(refusal?.hasPrefix("the gate opened: ") == true, "\(String(describing: refusal))")
    }
  }
}
