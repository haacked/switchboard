import Foundation
import Testing

@testable import SwitchboardCore

extension MergeBlockerTests {
  /// `Attention.mergeBlocker` names the first ready-to-merge condition that a
  /// PR fails.
  @Suite struct Classifier {
    /// A PR and its dependencies that pass every condition.
    enum Passing: String, CaseIterable, Sendable {
      case ready, defaultBranchUnknown, reviewRequestsUnread, approvedWithAReviewRequestOpen, needsNoReview
      case needsNoReviewAndRequestsUnread
      case resolvedDependency, deployedDependency, closedDependency

      func facts() throws -> SessionFacts {
        var dependencies: [Dependency] = []
        let pr = MergeBlockerTests.readyPR { pr in
          switch self {
          case .ready: break
          case .defaultBranchUnknown:
            pr.defaultBranch = nil
            pr.base = "release"
          case .reviewRequestsUnread: pr.reviewRequests = nil
          case .approvedWithAReviewRequestOpen: pr.reviewRequests = ["bob"]
          case .needsNoReview: pr.reviewDecision = nil
          case .needsNoReviewAndRequestsUnread:
            pr.reviewDecision = nil
            pr.reviewRequests = nil
          case .resolvedDependency: dependencies = [MergeBlockerTests.mergedDependency]
          case .deployedDependency:
            dependencies = [
              Dependency(via: .body, repo: "acme/widgets", number: 7, deploy: true, state: .merged, deployed: true)
            ]
          case .closedDependency: dependencies = [MergeBlockerTests.closedDependency]
          }
        }
        return try prFacts(pr, then: [try dependenciesEvent(3, dependencies)])
      }
    }

    /// A PR that fails one condition.
    enum Blocked: String, CaseIterable, Sendable {
      case draft, conflicting, checksFailed, checksErrored, checksPending, checksExpected
      case mergeabilityUnknown, mergeabilityUnread, noChecks
      case checksNeutral, checksSkipped, checksEmpty, checksLowercaseSuccess
      case otherBase, defaultBranchInAnotherCase
      case staleChangeRequest, decisionUnread, reviewRequired, changesRequestedDecision, reviewRequested

      func apply(_ pr: inout PullRequest) {
        switch self {
        case .draft: pr.draft = true
        case .conflicting: pr.mergeable = .conflicting
        case .checksFailed: pr.checks = "FAILURE"
        case .checksErrored: pr.checks = "ERROR"
        case .checksPending: pr.checks = "PENDING"
        case .checksExpected: pr.checks = "EXPECTED"
        case .mergeabilityUnknown: pr.mergeable = .unknown
        case .mergeabilityUnread: pr.mergeable = nil
        case .noChecks: pr.checks = nil
        case .checksNeutral: pr.checks = "NEUTRAL"
        case .checksSkipped: pr.checks = "SKIPPED"
        case .checksEmpty: pr.checks = ""
        case .checksLowercaseSuccess: pr.checks = "success"
        case .otherBase: pr.base = "release"
        case .defaultBranchInAnotherCase: pr.base = "Main"
        case .staleChangeRequest: MergeBlockerTests.addStaleChangeRequest(&pr)
        case .decisionUnread: MergeBlockerTests.leaveDecisionUnread(&pr)
        case .reviewRequired: pr.reviewDecision = .reviewRequired
        case .changesRequestedDecision: pr.reviewDecision = .changesRequested
        case .reviewRequested: MergeBlockerTests.requestReviewFromBob(&pr)
        }
      }

      var blocker: MergeBlocker {
        switch self {
        case .draft: .draft
        case .conflicting: .conflict
        case .checksFailed, .checksErrored: .checksFailed
        case .checksPending, .checksExpected: .checksRunning
        case .mergeabilityUnknown: .mergeabilityUnknown
        case .mergeabilityUnread: .mergeabilityUnread
        case .noChecks: .noChecks
        case .checksNeutral: .checksNotPassed("NEUTRAL")
        case .checksSkipped: .checksNotPassed("SKIPPED")
        case .checksEmpty: .checksNotPassed("")
        case .checksLowercaseSuccess: .checksNotPassed("success")
        case .otherBase: .base("release", defaultBranch: "main")
        case .defaultBranchInAnotherCase: .base("Main", defaultBranch: "main")
        case .staleChangeRequest: .review(.changesRequested)
        case .decisionUnread: .review(.decisionUnread)
        case .reviewRequired, .changesRequestedDecision: .review(.required)
        case .reviewRequested: .review(.requested)
        }
      }

      func facts() throws -> SessionFacts { try prFacts(MergeBlockerTests.readyPR(apply)) }
    }

    /// Two failing conditions, where the earlier condition in the precedence
    /// names the blocker.
    enum Precedence: String, CaseIterable, Sendable {
      case draftBeforeConflict, conflictBeforeDependency, dependencyBeforeQueue, queueBeforeFailedChecks
      case failedChecksBeforeBase, failedChecksBeforeReview, mergeabilityUnknownBeforeNoChecks
      case failedChecksBeforeMergeabilityUnknown, runningChecksBeforeMergeabilityUnknown, baseBeforeMergeabilityUnknown
      case baseBeforeReview, baseBeforeRunningChecks, reviewBeforeRunningChecks, reviewBeforeMergeabilityUnknown
      case baseBeforeNoChecks, reviewBeforeNoChecks, mergeabilityUnreadBeforeNoChecks, reviewBeforeMergeabilityUnread
      case baseBeforeChecksNotPassed

      func facts() throws -> SessionFacts {
        var dependencies: [Dependency] = []
        let pr = MergeBlockerTests.readyPR { pr in
          switch self {
          case .draftBeforeConflict:
            pr.draft = true
            pr.mergeable = .conflicting
          case .conflictBeforeDependency:
            pr.mergeable = .conflicting
            dependencies = [MergeBlockerTests.holdingDependency]
          case .dependencyBeforeQueue:
            pr.queue = .unknown
            dependencies = [MergeBlockerTests.holdingDependency]
          case .queueBeforeFailedChecks:
            pr.queue = .unknown
            pr.checks = "FAILURE"
          case .failedChecksBeforeBase:
            pr.checks = "FAILURE"
            pr.base = "release"
          case .failedChecksBeforeReview:
            pr.checks = "FAILURE"
            MergeBlockerTests.requestReviewFromBob(&pr)
          case .mergeabilityUnknownBeforeNoChecks:
            pr.mergeable = .unknown
            pr.checks = nil
          case .failedChecksBeforeMergeabilityUnknown:
            pr.checks = "FAILURE"
            pr.mergeable = .unknown
          case .runningChecksBeforeMergeabilityUnknown:
            pr.checks = "PENDING"
            pr.mergeable = .unknown
          case .baseBeforeMergeabilityUnknown:
            pr.mergeable = .unknown
            pr.base = "release"
          case .baseBeforeReview:
            pr.base = "release"
            MergeBlockerTests.requestReviewFromBob(&pr)
          case .baseBeforeRunningChecks:
            pr.base = "release"
            pr.checks = "PENDING"
          case .reviewBeforeRunningChecks:
            MergeBlockerTests.requestReviewFromBob(&pr)
            pr.checks = "PENDING"
          case .reviewBeforeMergeabilityUnknown:
            MergeBlockerTests.addStaleChangeRequest(&pr)
            pr.mergeable = .unknown
          case .baseBeforeNoChecks:
            pr.base = "release"
            pr.checks = nil
          case .reviewBeforeNoChecks:
            MergeBlockerTests.leaveDecisionUnread(&pr)
            pr.checks = nil
          case .mergeabilityUnreadBeforeNoChecks:
            pr.mergeable = nil
            pr.checks = nil
          case .reviewBeforeMergeabilityUnread:
            pr.reviewDecision = .reviewRequired
            pr.mergeable = nil
          case .baseBeforeChecksNotPassed:
            pr.base = "release"
            pr.checks = "NEUTRAL"
          }
        }
        return try prFacts(pr, then: [try dependenciesEvent(3, dependencies)])
      }

      var blocker: MergeBlocker {
        switch self {
        case .draftBeforeConflict: .draft
        case .conflictBeforeDependency: .conflict
        case .dependencyBeforeQueue: .dependency
        case .queueBeforeFailedChecks: .queue(.unknown)
        case .failedChecksBeforeBase, .failedChecksBeforeReview, .failedChecksBeforeMergeabilityUnknown: .checksFailed
        case .runningChecksBeforeMergeabilityUnknown: .checksRunning
        case .mergeabilityUnknownBeforeNoChecks: .mergeabilityUnknown
        case .baseBeforeMergeabilityUnknown, .baseBeforeReview, .baseBeforeRunningChecks, .baseBeforeNoChecks,
          .baseBeforeChecksNotPassed:
          .base("release", defaultBranch: "main")
        case .reviewBeforeRunningChecks: .review(.requested)
        case .reviewBeforeMergeabilityUnknown: .review(.changesRequested)
        case .reviewBeforeNoChecks: .review(.decisionUnread)
        case .reviewBeforeMergeabilityUnread: .review(.required)
        case .mergeabilityUnreadBeforeNoChecks: .mergeabilityUnread
        }
      }
    }

    static let holdingDependencies = [
      MergeBlockerTests.holdingDependency,
      Dependency(via: .body, repo: "acme/widgets", number: 7, state: nil),
      Dependency(via: .stack, repo: "acme/widgets", number: 7, state: .open),
      Dependency(via: .body, repo: "acme/widgets", number: 7, deploy: true, state: .merged, deployed: false),
    ]

    private func blocker(_ f: SessionFacts) throws -> MergeBlocker? {
      Attention.mergeBlocker(try #require(f.pr), f)
    }

    @Test(arguments: Passing.allCases)
    func prThatPassesEveryConditionHasNoBlocker(_ row: Passing) throws {
      #expect(try blocker(try row.facts()) == nil)
    }

    @Test(arguments: Blocked.allCases)
    func prThatFailsOneConditionNamesIt(_ row: Blocked) throws {
      #expect(try blocker(try row.facts()) == row.blocker)
    }

    @Test(arguments: TrunkQueueState.allCases)
    func prWithATrunkQueueStateNamesTheQueue(_ state: TrunkQueueState) throws {
      let f = try prFacts(MergeBlockerTests.readyPR { $0.queue = state })

      #expect(try blocker(f) == .queue(state))
    }

    @Test(arguments: holdingDependencies)
    func prThatADependencyHoldsNamesTheDependency(_ dependency: Dependency) throws {
      let f = try prFacts(MergeBlockerTests.readyPR(), then: [try dependenciesEvent(3, [dependency])])

      #expect(try blocker(f) == .dependency)
    }

    @Test func prWithAResolvedAndAHoldingDependencyNamesTheDependency() throws {
      let resolved = Dependency(via: .body, repo: "acme/widgets", number: 6, state: .merged)
      let f = try prFacts(
        MergeBlockerTests.readyPR(), then: [try dependenciesEvent(3, [resolved, MergeBlockerTests.holdingDependency])])

      #expect(try blocker(f) == .dependency)
    }

    @Test(arguments: Precedence.allCases)
    func prThatFailsTwoConditionsNamesTheEarlierOne(_ row: Precedence) throws {
      #expect(try blocker(try row.facts()) == row.blocker)
    }

    /// The classifier finds no blocker exactly for the inputs that
    /// `oldGuard` passes.
    @Test func classifierFindsNoBlockerExactlyWhenTheOldGuardPassed() {
      var mismatches: [String] = []

      for (pr, dependencies) in MergeBlockerTests.guardInputs() {
        let clear = Attention.mergeBlocker(pr, MergeBlockerTests.facts(pr, dependencies)) == nil
        if clear != MergeBlockerTests.oldGuard(pr, dependencies) {
          mismatches.append("\(pr) \(dependencies)")
        }
      }

      #expect(mismatches.isEmpty, "\(mismatches.count) inputs disagree, first: \(mismatches.first ?? "")")
    }
  }
}
