import Foundation

extension Attention {
  /// Ready for review when the other rules leave the session Waiting and its
  /// PR is open, not a draft, not in Trunk's queue, not merged by sbd, and
  /// still needs a review. A session therefore stays in Needs you, Ready to
  /// merge, Claude can continue, or Working, and a PR whose review is
  /// satisfied stays in Waiting. The reason keeps a wait's or a dependency's
  /// line after the PR's.
  static func readyForReview(_ verdict: Verdict, _ facts: SessionFacts) -> Verdict? {
    guard verdict.state == .waiting, facts.pr?.reviewSatisfied != true, let line = readyPRLine(facts) else {
      return nil
    }
    return Verdict(state: .readyForReview, reason: oneLine("\(line); \(verdict.reason)", max: 200), kind: verdict.kind)
  }

  /// "#N title; review state, checks" for a PR that can be in Ready for
  /// review. Nil for a draft, a closed PR, a PR in Trunk's queue, or a PR
  /// that sbd merged.
  static func readyPRLine(_ facts: SessionFacts) -> String? {
    guard let pr = facts.pr, pr.ready, pr.queue?.isQueued != true, facts.currentMerge?.result != .merged
    else { return nil }
    let checks = pr.checks.map { "checks \($0.lowercased())" } ?? "no checks"
    let title = pr.title.isEmpty ? "" : " \(pr.title)"
    return "#\(pr.number)\(title); \(reviewState(pr)), \(checks)"
  }

  /// Who approved, who requested changes, and whose review GitHub still asks
  /// for. When nobody did any of these, whether GitHub requires a review.
  static func reviewState(_ pr: PullRequest) -> String {
    var parts: [String] = []
    if !pr.approvers.isEmpty { parts.append("approved by \(names(pr.approvers))") }
    if !pr.changesRequestedBy.isEmpty { parts.append("changes requested by \(names(pr.changesRequestedBy))") }
    if let requested = pr.reviewRequests, !requested.isEmpty {
      parts.append("review requested from \(names(requested))")
    }
    if parts.isEmpty { parts.append(pr.reviewDecision == .reviewRequired ? "review required" : "no review requested") }
    return parts.joined(separator: "; ")
  }
}
