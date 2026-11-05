import Foundation

/// A merge that sbd ran or the user dismissed, as a `merge` event recorded it.
public struct MergeAttempt: Codable, Equatable, Sendable {
  public enum Result: String, Codable, Sendable {
    case merged
    case failed
    case dismissed
  }

  /// The PR's head commit when the attempt ran.
  public var head: String
  public var result: Result
  /// gh's error when the merge failed.
  public var error: String?

  public init(head: String, result: Result, error: String? = nil) {
    self.head = head
    self.result = result
    self.error = error
  }
}

extension SessionFacts {
  /// The last merge attempt at the PR's current head commit. A push makes
  /// earlier attempts irrelevant.
  public var currentMerge: MergeAttempt? {
    guard let merge, merge.head == pr?.headSha else { return nil }
    return merge
  }

  /// gh's error from a failed merge of the PR's current head commit.
  public var mergeError: String? {
    guard let merge = currentMerge, merge.result == .failed else { return nil }
    return merge.error
  }

  /// Whether the PR's repo merges through Trunk's queue. A repo without Trunk
  /// has no trunk-io comments.
  var usesTrunk: Bool { prComments.contains { $0.author == TrunkComments.author } }
}

extension Attention {
  /// Ready to merge when the PR targets the default branch, is not a draft,
  /// GitHub reports no conflict, the checks passed, no review is required,
  /// requested, or outstanding, the repo merges without Trunk, and no
  /// dependency holds it. `openPR` calls it after its blocking rules and its
  /// merged and dismissed attempts, so the PR is open and the session is idle.
  static func readyToMerge(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, !pr.draft, pr.mergeable == .mergeable, pr.checks == "SUCCESS",
      pr.defaultBranch == nil || pr.base == pr.defaultBranch,
      pr.reviewDecision != .reviewRequired, pr.reviewDecision != .changesRequested, pr.changesRequestedBy.isEmpty,
      pr.reviewRequests?.isEmpty ?? true, pr.queue == nil, !facts.usesTrunk,
      !facts.dependencies.contains(where: \.holds)
    else { return nil }
    return Verdict(
      state: .readyToMerge, reason: oneLine("#\(pr.number) is ready to merge\(approvedBy(pr))"), kind: .approval)
  }
}
