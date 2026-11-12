import Foundation

/// The first condition that keeps a PR out of Ready to merge.
/// `Attention.mergeBlocker` returns nil for a PR that is ready to merge.
enum MergeBlocker: Equatable, Sendable {
  case draft, conflict, dependency
  case queue(TrunkQueueState)
  case checksFailed, checksRunning
  /// GitHub has not computed the mergeability yet.
  case mergeabilityUnknown
  /// The poll did not read the mergeability.
  case mergeabilityUnread
  case noChecks
  /// The checks rollup holds a value other than SUCCESS, FAILURE, ERROR,
  /// PENDING, or EXPECTED.
  case checksNotPassed(String)
  case base(String, defaultBranch: String)
  case review(ReviewGap)
}

/// Why review does not satisfy a PR.
enum ReviewGap: Equatable, Sendable {
  /// A reviewer's last verdict requests changes.
  case changesRequested
  /// The poll did not read GitHub's review decision.
  case decisionUnread
  /// GitHub's decision is REVIEW_REQUIRED or CHANGES_REQUESTED.
  case required
  /// GitHub did not approve the PR, and a review request is open.
  case requested
}

extension Attention {
  /// The first condition that `pr` fails, checked in a fixed order. nil
  /// means the PR is ready to merge: it is not
  /// a draft, GitHub reports it mergeable, its checks passed, it targets the
  /// default branch or the default branch is unknown, review is satisfied,
  /// Trunk reports no queue state for it, and no dependency holds it.
  static func mergeBlocker(_ pr: PullRequest, _ facts: SessionFacts) -> MergeBlocker? {
    if pr.draft { return .draft }
    if pr.mergeable == .conflicting { return .conflict }
    if facts.dependencies.contains(where: \.holds) { return .dependency }
    if let queue = pr.queue { return .queue(queue) }
    if pr.checksFailed { return .checksFailed }
    if pr.checksRunning { return .checksRunning }
    switch pr.mergeable {
    case .mergeable: break
    case .conflicting: return .conflict
    case .unknown: return .mergeabilityUnknown
    case nil: return .mergeabilityUnread
    }
    switch pr.checks {
    case "SUCCESS": break
    case nil: return .noChecks
    case let checks?: return .checksNotPassed(checks)
    }
    if let defaultBranch = pr.defaultBranch, pr.base != defaultBranch {
      return .base(pr.base, defaultBranch: defaultBranch)
    }
    if !pr.reviewSatisfied {
      if !pr.changesRequestedBy.isEmpty { return .review(.changesRequested) }
      switch pr.needsReview {
      case nil: return .review(.decisionUnread)
      case true?: return .review(.required)
      case false?: return .review(.requested)
      }
    }
    return nil
  }
}
