import Foundation

extension Attention {
  /// Done when the PR merged or closed and the folder is clean or gone. A
  /// folder whose count failed for another reason is not known to be clean,
  /// so it fires no rule. Needs you
  /// when the folder has uncommitted changes and no turn runs. An open wait
  /// or a wait's outcome comes first, because a session can wait on its
  /// merged PR's deploy.
  static func finishedPR(_ session: Session, _ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state != .open, waitVerdict(session, facts) == nil else { return nil }
    let what = "#\(pr.number) \(pr.state == .merged ? "merged" : "closed")"
    if let cleanup = facts.cleanup, cleanup.state == .removed {
      let removed = cleanup.reason.map { "worktree removed, \($0)" } ?? "worktree and branch removed"
      return Verdict(state: .done, reason: "\(what); \(removed)")
    }
    if facts.folderGone { return Verdict(state: .done, reason: "\(what); its folder is gone") }
    guard let dirty = facts.dirty else { return nil }
    if dirty == 0 {
      let next = facts.cleanup?.state == .ready ? "ready for `sb cleanup`" : "archive the worktree"
      return Verdict(state: .done, reason: "\(what); \(next)\(facts.turnRunning ? " once it stops" : "")")
    }
    if facts.turnRunning { return nil }
    return Verdict(state: .needsYou, reason: "\(what); commit or discard the uncommitted changes", kind: .review)
  }

  /// The rules for an open PR of a session whose turn has ended: a merged
  /// base, a conflict, requested changes, a removal from Trunk's queue, a
  /// failed Depot job outside Trunk's queue, a PR ready to merge, and an
  /// approval.
  static func openPR(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state == .open else { return nil }
    let n = "#\(pr.number)"
    // sbd merged the PR, and the poller has not read the merge yet.
    if facts.currentMerge?.result == .merged {
      return Verdict(state: .waiting, reason: "\(n) merged; GitHub has not reported it yet")
    }
    if let base = pr.mergedBase {
      return Verdict(state: .needsYou, reason: "retarget \(n); its base #\(base) merged")
    }
    if pr.mergeable == .conflicting {
      return Verdict(state: .needsYou, reason: oneLine("rebase; \(n) conflicts with \(pr.base)"))
    }
    // A push after the review moves the head commit, and the PR then waits
    // for the reviewer.
    let current = pr.verdicts.filter {
      $0.state == "CHANGES_REQUESTED" && ($0.commit == nil || $0.commit == pr.headSha)
    }
    .map(\.author).sorted()
    if !current.isEmpty {
      return Verdict(
        state: .needsYou, reason: oneLine("address the changes that \(names(current)) requested on \(n)"))
    }
    if pr.changesRequestedBy.isEmpty && pr.reviewDecision == .changesRequested {
      return Verdict(state: .needsYou, reason: "address the requested changes on \(n)")
    }
    if pr.queue == .removed {
      let label = pr.queueLabel.map { " (\($0))" } ?? ""
      return Verdict(state: .needsYou, reason: "find out why Trunk removed \(n) from its queue\(label)")
    }
    // A failed Depot job blocks the merge. Trunk adds a PR to its queue only
    // after its required checks pass, so a failed job on a queued PR is one
    // that the merge does not need.
    if pr.queue?.isQueued != true, let run = pr.depotFailure {
      let reason = "fix Depot CI on \(n): "
      return Verdict(state: .needsYou, reason: reason + run.failureSummary(max: 70 - reason.count))
    }
    // The user dismissed the merge card of this head commit.
    if facts.currentMerge?.result == .dismissed { return nil }
    if let v = readyToMerge(facts) { return v }
    // A PR that waits on another can't merge yet.
    guard pr.isApproved, !facts.dependencies.contains(where: \.holds) else { return nil }
    switch pr.queue {
    case nil:
      return Verdict(
        state: .needsYou, reason: oneLine("\(facts.usesTrunk ? "enqueue" : "merge") \(n)\(approvedBy(pr))"))
    case .unknown:
      return Verdict(state: .needsYou, reason: "check whether Trunk queued \(n); its queue status did not load")
    default:
      return nil
    }
  }

  /// Waiting while an open PR needs only the review that GitHub still asks
  /// for. Each condition keeps a case in Needs you that someone must act on.
  /// It does not rely on `openPR` running first.
  static func awaitingReview(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state == .open, !pr.draft, let reviewers = pr.reviewRequests, !reviewers.isEmpty,
      !pr.isApproved, pr.mergeable != .conflicting, pr.mergedBase == nil, pr.queue == nil,
      !pr.ciFailed, classify(facts.lastReply ?? "") == .other
    else { return nil }
    return Verdict(state: .waiting, reason: oneLine("review of #\(pr.number) by \(names(reviewers))"))
  }

  /// Whether an open, ready PR needs the user after a review wait ended or
  /// when none began: a check failed, or GitHub asks nobody for a review, so
  /// nobody is reviewing it. A PR in Trunk's queue is excluded, because
  /// Trunk acts on it. A PR event does not count as session activity, so
  /// without this the idle time would move the session to Stale.
  static func needsPRAction(_ facts: SessionFacts) -> Bool {
    guard let pr = facts.pr, pr.state == .open, !pr.draft, pr.queue?.isQueued != true else { return false }
    return pr.ciFailed || (pr.reviewRequests == [] && pr.queue == nil)
  }

  static func names(_ logins: [String]) -> String { logins.joined(separator: " and ") }

  /// ", approved by X and Y", or nothing when nobody approved the PR.
  static func approvedBy(_ pr: PullRequest) -> String {
    pr.approvers.isEmpty ? "" : ", approved by \(names(pr.approvers))"
  }
}
