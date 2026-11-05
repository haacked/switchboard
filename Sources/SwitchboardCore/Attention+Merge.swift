import Foundation

/// How sbd lands a PR in its repository.
public enum MergeMethod: String, Codable, Sendable {
  /// `gh pr merge --merge`.
  case merge
  /// `gh pr merge`, which adds the PR to GitHub's merge queue.
  case mergeQueue = "merge_queue"
  /// A `/trunk merge` comment, which adds the PR to Trunk's queue.
  case trunk
  /// The poller has not read both whether the repository keeps a `.trunk`
  /// folder and whether the base branch has a merge queue.
  case unknown

  public var enqueues: Bool { self == .mergeQueue || self == .trunk }

  /// The button's word for landing the PR this way.
  public var verb: String { enqueues ? "Enqueue" : "Merge" }
}

/// A merge that sbd ran or the user dismissed, as a `merge` event recorded it.
public struct MergeAttempt: Codable, Equatable, Sendable {
  public enum Result: String, Codable, Sendable {
    case merged
    /// A queue took the PR: gh added it to GitHub's merge queue, or sbd
    /// commented `/trunk merge`.
    case enqueued
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

  /// Whether the PR's repo merges through Trunk's queue, as its `.trunk`
  /// folder, a trunk-io comment, or a Trunk queue state shows.
  var usesTrunk: Bool {
    pr?.trunkConfig == true || pr?.queue != nil || prComments.contains { $0.author == TrunkComments.author }
  }

  /// The time that Ready to merge sorts by: the PR's newest approval, or
  /// when sbd first saw the PR open and not a draft.
  public var readyToMergeSince: Int64? { pr?.approvedAt.flatMap(Transcript.milliseconds) ?? readySince }

  /// How sbd lands the PR. A merge needs the poller to have read that the
  /// repository has no `.trunk` folder and its base branch no merge queue,
  /// because a merge that goes around a queue can't be undone.
  public var mergeMethod: MergeMethod {
    if usesTrunk { return .trunk }
    if pr?.mergeQueue == true { return .mergeQueue }
    if pr?.trunkConfig == false && pr?.mergeQueue == false { return .merge }
    return .unknown
  }
}

extension Attention {
  /// Ready to merge when the PR targets the default branch, is not a draft,
  /// GitHub reports no conflict, the checks passed, review is satisfied,
  /// Trunk has not taken it, and no dependency holds it. `openPR` calls it
  /// after its blocking rules, its merged and dismissed attempts, and its
  /// GitHub merge queue rule, so the PR is open, outside GitHub's queue, and
  /// the session is idle. A repository whose merge method sbd can't tell
  /// gets no Merge or Enqueue option.
  static func readyToMerge(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, !pr.draft, pr.mergeable == .mergeable, pr.checks == "SUCCESS",
      pr.defaultBranch == nil || pr.base == pr.defaultBranch, pr.reviewSatisfied, pr.queue == nil,
      !facts.dependencies.contains(where: \.holds)
    else { return nil }
    let method = facts.mergeMethod
    var reason = "#\(pr.number) is ready to merge\(approvedBy(pr))"
    var options = [TriageOption(label: "Dismiss", action: .dismiss)]
    if method == .unknown {
      reason += "; can't tell how \(pr.repo) merges, so merge it on GitHub"
    } else {
      options.insert(TriageOption(label: "\(method.verb) #\(pr.number)", action: .merge, recommended: true), at: 0)
    }
    return Verdict(
      state: .readyToMerge, reason: oneLine(reason, max: 200), kind: .approval, options: options,
      callouts: facts.mergeError.map { [Callout(kind: .warning, title: "The last merge failed", body: $0)] } ?? [])
  }
}
