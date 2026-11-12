import Foundation
import Testing

@testable import SwitchboardCore

/// The suites nest under one name, so `--filter MergeBlockerTests` runs them all.
@Suite struct MergeBlockerTests {}

extension MergeBlockerTests {
  /// The ready PR, approved by alice and with no review request open.
  static func readyPR(_ edit: (inout PullRequest) -> Void = { _ in }) -> PullRequest {
    var pr = SwitchboardCoreTests.readyPR(
      reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], reviewRequests: [])
    edit(&pr)
    return pr
  }

  static func requestReviewFromBob(_ pr: inout PullRequest) {
    pr.reviewDecision = nil
    pr.reviewRequests = ["bob"]
  }

  static func leaveDecisionUnread(_ pr: inout PullRequest) {
    pr.reviewDecision = nil
    pr.reviewDecisionRead = nil
  }

  static func addStaleChangeRequest(_ pr: inout PullRequest) {
    pr.verdicts.append(sampleVerdict("carol", "CHANGES_REQUESTED", on: "older"))
  }

  static let holdingDependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .open)
  static let mergedDependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .merged)
  static let closedDependency = Dependency(via: .body, repo: "acme/widgets", number: 7, state: .closed)

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
      addStaleChangeRequest,
      leaveDecisionUnread,
      requestReviewFromBob,
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
    let dependencySets: [[Dependency]] = [[], [holdingDependency], [mergedDependency], [closedDependency]]
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
      case baseWithReviewRequested, reviewRequestedFromACodeOwnerTeam
      case baseWithNoChecks, reviewRequestedWithMergeabilityUnknown, mergeabilityUnreadWithNoChecks
      case staleChangeRequestWithRunningChecks

      func apply(_ pr: inout PullRequest) {
        switch self {
        case .noChecks: pr.checks = nil
        case .mergeabilityUnread: pr.mergeable = nil
        case .base: pr.base = "release"
        case .decisionUnread: MergeBlockerTests.leaveDecisionUnread(&pr)
        case .reviewRequested: MergeBlockerTests.requestReviewFromBob(&pr)
        case .staleChangeRequest: MergeBlockerTests.addStaleChangeRequest(&pr)
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
          MergeBlockerTests.requestReviewFromBob(&pr)
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
        case .baseWithReviewRequested:
          pr.base = "release"
          MergeBlockerTests.requestReviewFromBob(&pr)
        case .reviewRequestedFromACodeOwnerTeam:
          pr.reviewDecision = nil
          pr.codeOwnerRequests = ["@acme/owners"]
          pr.reviewRequests = ["owners", "bob"]
        case .baseWithNoChecks:
          pr.base = "release"
          pr.checks = nil
        case .reviewRequestedWithMergeabilityUnknown:
          MergeBlockerTests.requestReviewFromBob(&pr)
          pr.mergeable = .unknown
        case .mergeabilityUnreadWithNoChecks:
          pr.mergeable = nil
          pr.checks = nil
        case .staleChangeRequestWithRunningChecks:
          MergeBlockerTests.addStaleChangeRequest(&pr)
          pr.checks = "PENDING"
        }
      }

      static let targetsRelease = "#42 targets release, not main; approved by alice"
      static let reviewRequestedFromBob = "review requested from bob on #42; approved by alice; #42 needs no review"

      var expected: Verdict {
        switch self {
        case .noChecks: Verdict(state: .needsYou, reason: "no checks ran on #42; approved by alice")
        case .mergeabilityUnread, .mergeabilityUnreadWithNoChecks:
          Verdict(state: .waiting, reason: "sbd has not read whether #42 can merge; #42 approved")
        case .base, .baseWithRunningChecks, .mergeabilityUnknownWithBase, .baseWithReviewRequested, .baseWithNoChecks:
          Verdict(state: .needsYou, reason: Self.targetsRelease)
        case .decisionUnread:
          Verdict(
            state: .waiting, reason: "can't merge #42 yet; approved by alice; #42: GitHub's review rule not read yet")
        case .reviewRequested, .reviewRequestedWithRunningChecks, .reviewRequestedWithMergeabilityUnknown:
          Verdict(state: .waiting, reason: Self.reviewRequestedFromBob)
        case .staleChangeRequest, .staleChangeRequestWithRunningChecks:
          Verdict(state: .waiting, reason: "#42 waits on carol to review again; approved by alice; #42 approved")
        case .unrecognizedChecks: Verdict(state: .needsYou, reason: "checks on #42 report neutral; approved by alice")
        case .queueUnknownWithFailedChecks:
          Verdict(state: .needsYou, reason: "check whether Trunk queued #42; its queue status did not load")
        case .mergeabilityUnknownWithNoChecks:
          Verdict(state: .waiting, reason: "GitHub is still checking whether #42 can merge; #42 approved")
        case .runningChecksWithMergeabilityUnknown:
          Verdict(state: .waiting, reason: "checks running on #42; #42 approved")
        case .baseWithFailedChecks, .failedChecksWithMergeabilityUnknown:
          Verdict(state: .needsYou, reason: "fix the checks on #42; approved by alice")
        case .holdingDependencyWithFailedChecks: Verdict(state: .waiting, reason: "waits on #7; #42 approved")
        case .trunkSubmittedWithFailedChecks:
          Verdict(state: .needsYou, reason: "read its last reply and decide what's next")
        case .reviewRequestedFromACodeOwnerTeam:
          Verdict(
            state: .waiting,
            reason: "review requested from @acme/owners and bob on #42; approved by alice; #42 needs no review")
        }
      }

      /// Whether the approved rule gives the verdict for a blocker that only
      /// says what blocks the merge: no checks, an unread mergeability, a
      /// non-default base, a review gap, or a checks value outside the known
      /// ones.
      var namesTheBlockerOnly: Bool {
        switch self {
        case .noChecks, .mergeabilityUnread, .base, .decisionUnread, .reviewRequested, .staleChangeRequest,
          .unrecognizedChecks, .baseWithRunningChecks, .reviewRequestedWithRunningChecks, .mergeabilityUnknownWithBase,
          .baseWithReviewRequested, .reviewRequestedFromACodeOwnerTeam, .baseWithNoChecks,
          .reviewRequestedWithMergeabilityUnknown, .mergeabilityUnreadWithNoChecks,
          .staleChangeRequestWithRunningChecks:
          true
        case .queueUnknownWithFailedChecks, .mergeabilityUnknownWithNoChecks, .baseWithFailedChecks,
          .holdingDependencyWithFailedChecks, .trunkSubmittedWithFailedChecks, .runningChecksWithMergeabilityUnknown,
          .failedChecksWithMergeabilityUnknown:
          false
        }
      }

      func facts() throws -> SessionFacts {
        let dependencies = self == .holdingDependencyWithFailedChecks ? [MergeBlockerTests.holdingDependency] : []
        return try prFacts(MergeBlockerTests.readyPR(apply), then: [try dependenciesEvent(3, dependencies)])
      }
    }

    private func verdict(_ f: SessionFacts) -> Verdict { Attention.evaluate(session(), f, now: 10) }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeHasTheVerdict(_ row: Row) throws {
      #expect(verdict(try row.facts()) == row.expected)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeDoesNotSummarizeThePR(_ row: Row) throws {
      #expect(!verdict(try row.facts()).summarizesPR)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeHasNoSummary(_ row: Row) throws {
      #expect(verdict(try row.facts()).summary == nil)
    }

    @Test(arguments: Row.allCases)
    func approvedPRThatCantMergeIsNotAtAMergeDecision(_ row: Row) throws {
      #expect(!Attention.atMergeDecision(try row.facts()))
    }

    @Test(arguments: Row.allCases.filter(\.namesTheBlockerOnly))
    func approvedPRThatCantMergeOffersNoOption(_ row: Row) throws {
      #expect(verdict(try row.facts()).options.isEmpty)
    }

    @Test(arguments: Row.allCases.filter(\.namesTheBlockerOnly))
    func approvedPRThatCantMergeHasNoCallout(_ row: Row) throws {
      #expect(verdict(try row.facts()).callouts.isEmpty)
    }

    @Test func readyPRIsReadyToMerge() throws {
      let f = try prFacts(MergeBlockerTests.readyPR())
      let v = verdict(f)

      #expect(v.state == .readyToMerge)
      #expect(v.summarizesPR)
      #expect(Attention.atMergeDecision(f))
    }

    /// `BoardColumn.reviewers` keeps the code owner form of a team that both
    /// lists name. The code owner row relies on it.
    @Test func codeOwnerRowAsksTheTeamOnce() throws {
      let f = try Row.reviewRequestedFromACodeOwnerTeam.facts()

      #expect(BoardColumn.reviewers(f) == ["@acme/owners", "bob"])
    }

    @Test func staleChangeRequestsNameEachReviewer() throws {
      let pr = MergeBlockerTests.readyPR {
        $0.verdicts += [
          sampleVerdict("dave", "CHANGES_REQUESTED", on: "older"),
          sampleVerdict("carol", "CHANGES_REQUESTED", on: "older"),
        ]
      }

      #expect(
        verdict(try prFacts(pr))
          == Verdict(
            state: .waiting, reason: "#42 waits on carol and dave to review again; approved by alice; #42 approved"))
    }

    @Test(arguments: [("SKIPPED", "skipped"), ("STALE", "stale")])
    func checksOutsideTheKnownValuesNameTheValue(_ checks: String, _ shown: String) throws {
      let f = try prFacts(MergeBlockerTests.readyPR { $0.checks = checks })

      #expect(
        verdict(f) == Verdict(state: .needsYou, reason: "checks on #42 report \(shown); approved by alice"))
    }

    /// `oneLine` cuts the reason at 70 characters, so a long list of
    /// approvers loses its tail and the blocker stays whole.
    @Test func longApproverListKeepsTheBlocker() throws {
      let pr = MergeBlockerTests.readyPR {
        $0.base = "release"
        $0.verdicts = ["alice", "bob", "carol", "dave", "erin"].map { sampleVerdict($0, "APPROVED") }
      }

      let reason = verdict(try prFacts(pr)).reason

      #expect(reason == "#42 targets release, not main; approved by alice and bob and carol an…")
    }
  }
}

extension MergeBlockerTests {
  /// The verdict that the approved rule returns for each blocker, before
  /// `Attention.evaluate` appends why the PR is not in Ready for review.
  /// These cover the shapes that `evaluate` can't reach.
  @Suite struct ApprovedRuleRawReason {
    private func raw(_ blocker: MergeBlocker, _ edit: (inout PullRequest) -> Void = { _ in }) throws -> Verdict {
      let f = try prFacts(MergeBlockerTests.readyPR(edit))
      let pr = try #require(f.pr)
      return try #require(Attention.approvedNotReady(blocker, pr, f))
    }

    /// `PullRequest.status` reads GitHub's REVIEW_REQUIRED decision first,
    /// so an approved PR never has this gap.
    @Test func requiredReviewWaitsOnIt() throws {
      #expect(
        try raw(.review(.required))
          == Verdict(state: .waiting, reason: "#42 waits on a required review; approved by alice"))
    }

    @Test func reviewRequestWithoutANamedReviewerNamesNobody() throws {
      let v = try raw(.review(.requested)) {
        $0.reviewDecision = nil
        $0.reviewRequests = []
      }

      #expect(v == Verdict(state: .waiting, reason: "review requested on #42; approved by alice"))
    }

    enum Unapproved: String, CaseIterable, Sendable {
      case noChecks, mergeabilityUnread, base, checksNotPassed, changesRequested, decisionUnread, required, requested

      var blocked: Classifier.Blocked {
        switch self {
        case .noChecks: .noChecks
        case .mergeabilityUnread: .mergeabilityUnread
        case .base: .otherBase
        case .checksNotPassed: .checksNeutral
        case .changesRequested: .staleChangeRequest
        case .decisionUnread: .decisionUnread
        case .required: .reviewRequired
        case .requested: .reviewRequested
        }
      }

      func apply(_ pr: inout PullRequest) {
        pr.verdicts = []
        blocked.apply(&pr)
      }

      var expected: Verdict {
        switch self {
        case .noChecks: Verdict(state: .needsYou, reason: "no checks ran on #42")
        case .mergeabilityUnread: Verdict(state: .waiting, reason: "sbd has not read whether #42 can merge")
        case .base: Verdict(state: .needsYou, reason: "#42 targets release, not main")
        case .checksNotPassed: Verdict(state: .needsYou, reason: "checks on #42 report neutral")
        case .changesRequested: Verdict(state: .waiting, reason: "#42 waits on carol to review again")
        case .decisionUnread: Verdict(state: .waiting, reason: "can't merge #42 yet")
        case .required: Verdict(state: .waiting, reason: "#42 waits on a required review")
        case .requested: Verdict(state: .waiting, reason: "review requested from bob on #42")
        }
      }
    }

    /// A PR that GitHub approved without an APPROVED verdict names no
    /// approver, so its reason ends at the blocker.
    @Test(arguments: Unapproved.allCases)
    func reasonWithoutAnApproverEndsAtTheBlocker(_ row: Unapproved) throws {
      #expect(try raw(row.blocked.blocker, row.apply) == row.expected)
    }
  }
}
