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
    if usesTrunk { return .trunk }
    if pr?.mergeQueue == true { return .mergeQueue }
    if pr?.trunkConfig == false && pr?.mergeQueue == false { return .merge }
    return .unknown
  }
}

extension Attention {
  /// Ready to merge exactly when `mergeBlocker` finds no blocker. `openPR`
  /// calls it after its blocking rules, its merged attempt, and its
  /// GitHub merge queue rule, so the PR is open, outside GitHub's queue, and
  /// the session is idle. A repository whose merge method sbd can't tell
  /// gets no Merge or Enqueue option.
  static func readyToMerge(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, mergeBlocker(pr, facts) == nil else { return nil }
    let method = facts.mergeMethod
    var reason = "#\(pr.number) is ready to merge\(approvedBy(pr))"
    var options = [TriageOption(label: "Acknowledge", action: .dismiss)]
    if method == .unknown {
      reason += "; can't tell how \(pr.repo) merges, so merge it on GitHub"
    } else {
      options.insert(TriageOption(label: "\(method.verb) #\(pr.number)", action: .merge, recommended: true), at: 0)
    }
    var verdict = Verdict(
      state: .readyToMerge, reason: oneLine(reason, max: 200), kind: .approval, options: options,
      callouts: facts.mergeError.map { [Callout(kind: .warning, title: "The last merge failed", body: $0)] } ?? [])
    verdict.addMergeSummary(facts)
    return verdict
  }

  /// Whether the session's PR is at a merge decision: the rule for its open
  /// PR is Ready to merge. The poller reads the PR's merge details only then.
  public static func atMergeDecision(_ facts: SessionFacts) -> Bool {
    openPR(facts)?.summarizesPR == true
  }

  /// The merge card's Summary and the callouts that should give the user
  /// pause. The Summary says what the PR does, from the model's brief at the
  /// PR's head or else the description's gist, then the PR's size, approvals,
  /// and checks. Only Ready to merge builds it, so the PR's checks passed.
  /// Text from the PR is escaped, because the card draws the Summary as
  /// Markdown and anyone who can open a PR wrote it.
  static func mergeSummary(_ facts: SessionFacts) -> (text: String, callouts: [Callout]) {
    guard let pr = facts.pr else { return ("", []) }
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
    let text = [prose, parts.joined(separator: " ")].compactMap { $0 }.map(MarkdownText.escaped)
      .joined(separator: "\n\n")
    return (text, pauseCallouts(pr))
  }

  /// The warnings for a PR that is otherwise ready: code owners whose
  /// review is still missing, open review threads, and gaps in the test plan.
  static func pauseCallouts(_ pr: PullRequest) -> [Callout] {
    var callouts: [Callout] = []
    if let status = CodeOwnerStatus(pr), !status.satisfied {
      let waiting = status.groups.filter { !$0.approved }.map { $0.owners.joined(separator: " or ") }
      callouts.append(
        Callout(
          kind: .warning, title: "Code owner review still required",
          body: MarkdownText.escaped(waiting.joined(separator: "; "))))
    } else if let requests = pr.codeOwnerRequests, !requests.isEmpty {
      callouts.append(
        Callout(
          kind: .warning, title: "Code owners still requested",
          body: MarkdownText.escaped(requests.joined(separator: ", "))))
    }
    if let d = pr.mergeDetails {
      let open = d.openThreads
      let threads = "\(open) open review \(open == 1 ? "thread" : "threads")"
      if d.threadsRead < d.threads {
        callouts.append(
          Callout(
            kind: .warning, title: open == 0 ? "Not every review thread was read" : "At least \(threads)",
            body: "#\(pr.number) has \(d.threads) review threads, and sbd read \(d.threadsRead)."))
      } else if open > 0 {
        callouts.append(Callout(kind: .warning, title: threads))
      }
      if !d.testGaps.isEmpty {
        callouts.append(
          Callout(
            kind: .warning, title: "The test plan has gaps",
            body: d.testGaps.map { "- " + MarkdownText.escaped($0) }.joined(separator: "\n")))
      }
    }
    return callouts
  }
}

extension Verdict {
  /// Makes this the Ready to merge verdict's card: its summary says what the
  /// PR does, and the pause callouts follow its own.
  mutating func addMergeSummary(_ facts: SessionFacts) {
    let merge = Attention.mergeSummary(facts)
    summary = merge.text
    callouts += merge.callouts
    summarizesPR = true
  }
}
