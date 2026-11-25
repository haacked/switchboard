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

  public var pastTense: String { enqueues ? "enqueued" : "merged" }
}

/// A merge that sbd ran, as a `merge` event recorded it.
public struct MergeAttempt: Codable, Equatable, Sendable {
  public enum Result: String, Codable, Sendable {
    case merged
    /// A queue took the PR: gh added it to GitHub's merge queue, or sbd
    /// commented `/trunk merge`.
    case enqueued
    case failed
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
    if pr.map({ GitLab.isMR($0.id) }) == true { return .merge }
    if usesTrunk { return .trunk }
    if pr?.mergeQueue == true { return .mergeQueue }
    if pr?.trunkConfig == false && pr?.mergeQueue == false { return .merge }
    return .unknown
  }
}

extension Attention {
  /// The Ready to merge verdict for a PR that has no merge blocker. The
  /// caller checks `mergeBlocker` first. A repository whose merge method sbd
  /// can't tell gets no Merge or Enqueue option. A row of the review that
  /// needs a look demotes the merge option to "anyway", which no key runs.
  static func readyToMerge(_ pr: PullRequest, _ facts: SessionFacts) -> Verdict {
    let method = facts.mergeMethod
    let review = MergeReview(pr)
    var reason = "#\(pr.number) is ready to merge\(approvedBy(pr))"
    var options = [TriageOption(label: "Acknowledge", action: .dismiss)]
    if method == .unknown {
      reason += "; can't tell how \(pr.repo) merges, so merge it on GitHub"
    } else if review.amber.isEmpty {
      options.insert(TriageOption(label: "\(method.verb) #\(pr.number)", action: .merge, recommended: true), at: 0)
    } else {
      options.insert(
        TriageOption(
          label: "\(method.verb) #\(pr.number) anyway", detail: "#\(pr.number) has open review items", action: .merge),
        at: 0)
    }
    return Verdict(
      state: .readyToMerge, reason: oneLine(reason, max: 200), kind: .approval, options: options,
      callouts: facts.mergeError.map { [Callout(kind: .warning, title: "The last merge failed", body: $0)] } ?? [],
      summary: mergeSummary(facts), summarizesPR: true, review: review)
  }

  /// Whether the session's PR is at a merge decision: the rule for its open
  /// PR is Ready to merge. The poller then reads the PR's merge details
  /// again after each status read.
  public static func atMergeDecision(_ facts: SessionFacts) -> Bool {
    openPR(facts)?.summarizesPR == true
  }

  /// The merge card's Summary. It says what the PR does, from the model's
  /// brief at the PR's head or else the description's gist, then the PR's
  /// size, approvals, and checks. Only Ready to merge builds it, so the PR's
  /// checks passed. Text from the PR is escaped, because the card draws the
  /// Summary as Markdown and anyone who can open a PR wrote it.
  static func mergeSummary(_ facts: SessionFacts) -> String {
    guard let pr = facts.pr else { return "" }
    let details = pr.mergeDetails
    var parts: [String] = []
    if let d = details {
      parts.append("\(d.changedFiles) \(d.changedFiles == 1 ? "file" : "files"), +\(d.additions) -\(d.deletions).")
    }
    parts.append(pr.approvers.isEmpty ? "No review required." : "Approved by \(names(pr.approvers)).")
    parts.append("Checks passed.")
    if facts.mergeMethod == .unknown {
      parts.append("sbd can't tell how \(pr.repo) merges, so merge it on GitHub.")
    }
    let prose = facts.currentMergeBrief?.text ?? details?.gist
    return [prose, parts.joined(separator: " ")].compactMap { $0 }.map(MarkdownText.escaped)
      .joined(separator: "\n\n")
  }
}
