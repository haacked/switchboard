import Foundation
import Testing

@testable import SwitchboardCore

/// The suites nest under one name, so `--filter MergeBlockerTests` runs them all.
@Suite struct MergeBlockerTests {}

extension MergeBlockerTests {
  /// A PR that every ready-to-merge condition passes: approved by alice, its
  /// checks passed, no review request open, and a repository that the poller
  /// read has no `.trunk` folder and a base branch without a merge queue.
  static func readyPR(_ edit: (inout PullRequest) -> Void = { _ in }) -> PullRequest {
    var pr = samplePR(
      reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], checks: "SUCCESS",
      reviewRequests: [], reviewDecisionRead: true)
    pr.trunkConfig = false
    pr.mergeQueue = false
    edit(&pr)
    return pr
  }

  static let holdingDependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open)

  /// The Ready to merge guard from main at a190b4b.
  static func oldGuard(_ pr: PullRequest, _ dependencies: [Dependency]) -> Bool {
    !pr.draft && pr.mergeable == .mergeable && pr.checks == "SUCCESS"
      && (pr.defaultBranch == nil || pr.base == pr.defaultBranch) && pr.reviewSatisfied && pr.queue == nil
      && !dependencies.contains(where: \.holds)
  }

  /// Every combination of the inputs that the Ready to merge guard reads.
  static func guardInputs() -> [(pr: PullRequest, dependencies: [Dependency])] {
    let reviews: [(inout PullRequest) -> Void] = [
      { _ in },
      { $0.reviewRequests = nil },
      { $0.reviewRequests = ["bob"] },
      { $0.verdicts.append(sampleVerdict("carol", "CHANGES_REQUESTED", on: "older")) },
      {
        $0.reviewDecision = nil
        $0.reviewDecisionRead = nil
      },
      {
        $0.reviewDecision = nil
        $0.reviewRequests = ["bob"]
      },
      { $0.reviewDecision = nil },
      {
        $0.reviewDecision = nil
        $0.reviewRequests = nil
      },
      { $0.reviewDecision = .reviewRequired },
      { $0.reviewDecision = .changesRequested },
    ]
    let bases: [(base: String, defaultBranch: String?)] = [("main", "main"), ("release", "main"), ("release", nil)]
    let checks: [String?] = ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED", nil, "NEUTRAL", "success"]
    let mergeables: [Mergeable?] = [.mergeable, .conflicting, .unknown, nil]
    let queues: [TrunkQueueState?] = [nil, .unknown, .queued, .removed, .merged]
    let dependencySets: [[Dependency]] = [
      [], [holdingDependency], [Dependency(via: .body, repo: "acme/widgets", number: 7, state: .merged)],
      [Dependency(via: .body, repo: "acme/widgets", number: 7, state: .closed)],
    ]
    var inputs: [(pr: PullRequest, dependencies: [Dependency])] = []
    for draft in [false, true] {
      for mergeable in mergeables {
        for check in checks {
          for base in bases {
            for review in reviews {
              for queue in queues {
                let pr = readyPR {
                  $0.draft = draft
                  $0.mergeable = mergeable
                  $0.checks = check
                  $0.base = base.base
                  $0.defaultBranch = base.defaultBranch
                  $0.queue = queue
                  review(&$0)
                }
                for dependencies in dependencySets { inputs.append((pr, dependencies)) }
              }
            }
          }
        }
      }
    }
    return inputs
  }

  static func facts(_ pr: PullRequest, _ dependencies: [Dependency]) -> SessionFacts {
    var f = SessionFacts()
    f.pr = pr
    f.dependencies = dependencies
    return f
  }
}

extension MergeBlockerTests {
  /// What `Attention.evaluate` shows for a PR that review approved and that
  /// can't merge yet.
  @Suite struct ApprovedRule {
    enum Row: String, CaseIterable, Sendable {
      case noChecks, mergeabilityUnread, base, decisionUnread, reviewRequested, staleChangeRequest
      case unrecognizedChecks
      case queueUnknownWithFailedChecks, mergeabilityUnknownWithNoChecks, baseWithRunningChecks
      case baseWithFailedChecks, reviewRequestedWithRunningChecks, holdingDependencyWithFailedChecks
      case trunkSubmittedWithFailedChecks
      case runningChecksWithMergeabilityUnknown, failedChecksWithMergeabilityUnknown, mergeabilityUnknownWithBase

      func apply(_ pr: inout PullRequest) {
        switch self {
        case .noChecks: pr.checks = nil
        case .mergeabilityUnread: pr.mergeable = nil
        case .base: pr.base = "release"
        case .decisionUnread:
          pr.reviewDecision = nil
          pr.reviewDecisionRead = nil
        case .reviewRequested:
          pr.reviewDecision = nil
          pr.reviewRequests = ["bob"]
        case .staleChangeRequest: pr.verdicts.append(sampleVerdict("carol", "CHANGES_REQUESTED", on: "older"))
        case .unrecognizedChecks: pr.checks = "NEUTRAL"
        case .queueUnknownWithFailedChecks:
          pr.queue = .unknown
          pr.checks = "FAILURE"
        case .mergeabilityUnknownWithNoChecks:
          pr.mergeable = .unknown
          pr.checks = nil
        case .baseWithRunningChecks:
          pr.base = "release"
          pr.checks = "PENDING"
        case .baseWithFailedChecks:
          pr.base = "release"
          pr.checks = "FAILURE"
        case .reviewRequestedWithRunningChecks:
          pr.reviewDecision = nil
          pr.reviewRequests = ["bob"]
          pr.checks = "PENDING"
        case .holdingDependencyWithFailedChecks: pr.checks = "FAILURE"
        case .trunkSubmittedWithFailedChecks:
          pr.queue = .submitted
          pr.checks = "FAILURE"
        case .runningChecksWithMergeabilityUnknown:
          pr.checks = "PENDING"
          pr.mergeable = .unknown
        case .failedChecksWithMergeabilityUnknown:
          pr.checks = "FAILURE"
          pr.mergeable = .unknown
        case .mergeabilityUnknownWithBase:
          pr.mergeable = .unknown
          pr.base = "release"
        }
      }

      var state: AttentionState {
        switch self {
        case .mergeabilityUnknownWithNoChecks, .baseWithRunningChecks, .reviewRequestedWithRunningChecks,
          .holdingDependencyWithFailedChecks, .runningChecksWithMergeabilityUnknown, .mergeabilityUnknownWithBase:
          .waiting
        default: .needsYou
        }
      }

      var reason: String {
        switch self {
        case .noChecks, .mergeabilityUnread, .base, .decisionUnread, .reviewRequested, .staleChangeRequest,
          .unrecognizedChecks:
          "merge #42, approved by alice"
        case .queueUnknownWithFailedChecks: "check whether Trunk queued #42; its queue status did not load"
        case .mergeabilityUnknownWithNoChecks, .mergeabilityUnknownWithBase:
          "GitHub is still checking whether #42 can merge; #42 approved"
        case .baseWithRunningChecks, .runningChecksWithMergeabilityUnknown: "checks running on #42; #42 approved"
        case .baseWithFailedChecks, .failedChecksWithMergeabilityUnknown: "fix the checks on #42; approved by alice"
        case .reviewRequestedWithRunningChecks: "checks running on #42; #42 needs no review"
        case .holdingDependencyWithFailedChecks: "waits on #7; #42 approved"
        case .trunkSubmittedWithFailedChecks: "read its last reply and decide what's next"
        }
      }

      /// The rows that reach the approved rule's fallthrough, which asks the
      /// user to merge.
      var summarizesPR: Bool { reason == "merge #42, approved by alice" }

      func facts() throws -> SessionFacts {
        let dependencies = self == .holdingDependencyWithFailedChecks ? [MergeBlockerTests.holdingDependency] : []
        return try prFacts(MergeBlockerTests.readyPR(apply), then: [try dependenciesEvent(3, dependencies)])
      }
    }

    private func verdict(_ f: SessionFacts) -> Verdict { Attention.evaluate(session(), f, now: 10) }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeHasTheState(_ row: Row) throws {
      #expect(verdict(try row.facts()).state == row.state)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeHasTheReason(_ row: Row) throws {
      #expect(verdict(try row.facts()).reason == row.reason)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeSummarizesThePROnlyAtTheFallthrough(_ row: Row) throws {
      #expect(verdict(try row.facts()).summarizesPR == row.summarizesPR)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeIsAtAMergeDecisionOnlyAtTheFallthrough(_ row: Row) throws {
      #expect(Attention.atMergeDecision(try row.facts()) == row.summarizesPR)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeIsNotReadyToMerge(_ row: Row) throws {
      #expect(Attention.readyToMerge(try row.facts()) == nil)
    }

    @Test func readyPRIsReadyToMerge() throws {
      let f = try prFacts(MergeBlockerTests.readyPR())

      #expect(verdict(f).state == .readyToMerge)
    }
  }
}

extension MergeBlockerTests {
  /// Ready to merge gives a verdict exactly for the inputs that `oldGuard`
  /// passes.
  @Suite struct ReadyToMergeParity {
    @Test func readyToMergeSelectsExactlyThePRsThatTheOldGuardSelected() {
      var mismatches: [String] = []

      for (pr, dependencies) in MergeBlockerTests.guardInputs() {
        let ready = Attention.readyToMerge(MergeBlockerTests.facts(pr, dependencies)) != nil
        if ready != MergeBlockerTests.oldGuard(pr, dependencies) {
          mismatches.append("\(pr) \(dependencies)")
        }
      }

      #expect(mismatches.isEmpty, "\(mismatches.count) inputs disagree, first: \(mismatches.first ?? "")")
    }
  }
}
