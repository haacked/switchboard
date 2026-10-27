import Foundation

extension Attention {
  /// Done when the PR merged or closed and the folder is clean. Needs you
  /// when the folder has uncommitted changes and no turn runs. An open wait
  /// or a wait's outcome comes first, because a session can wait on its
  /// merged PR's deploy.
  static func finishedPR(_ session: Session, _ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state != .open, let dirty = facts.dirty, session.waits?.isEmpty ?? true,
      facts.waitOutcome == nil
    else { return nil }
    let what = "#\(pr.number) \(pr.state == .merged ? "merged" : "closed")"
    if dirty == 0 {
      return Verdict(state: .done, reason: "\(what); archive the worktree\(facts.turnRunning ? " once it stops" : "")")
    }
    if facts.turnRunning { return nil }
    return Verdict(state: .needsYou, reason: "\(what); commit or discard the uncommitted changes")
  }

  /// The rules for an open PR of a session whose turn has ended: a merged
  /// base, a conflict, requested changes, a removal from Trunk's queue, and an
  /// approval.
  static func openPR(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state == .open else { return nil }
    let n = "#\(pr.number)"
    if let base = pr.mergedBase {
      return Verdict(state: .needsYou, reason: "retarget \(n); its base #\(base) merged")
    }
    if pr.mergeable == "CONFLICTING" {
      return Verdict(state: .needsYou, reason: "rebase; \(n) conflicts with its base")
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
    if pr.changesRequestedBy.isEmpty && pr.reviewDecision == "CHANGES_REQUESTED" {
      return Verdict(state: .needsYou, reason: "address the requested changes on \(n)")
    }
    if pr.queue == TrunkQueueState.removed.rawValue {
      return Verdict(state: .needsYou, reason: "find out why Trunk removed \(n) from its queue")
    }
    guard pr.isApproved else { return nil }
    let by = pr.approvers.isEmpty ? "" : ", approved by \(names(pr.approvers))"
    switch pr.queue {
    case nil:
      // A repo without Trunk has no trunk-io comments, and its PRs merge directly.
      let trunk = facts.prComments.contains { $0.author == TrunkComments.author }
      return Verdict(state: .needsYou, reason: oneLine("\(trunk ? "enqueue" : "merge") \(n)\(by)"))
    case "unknown":
      return Verdict(state: .needsYou, reason: "check whether Trunk queued \(n); its queue status did not load")
    default:
      return nil
    }
  }

  static func names(_ logins: [String]) -> String { logins.joined(separator: " and ") }
}
