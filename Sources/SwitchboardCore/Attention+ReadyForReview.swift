import Foundation

extension Attention {
  /// Ready for review when the other rules leave the session Waiting and its
  /// PR is open, not a draft, not in Trunk's queue, not merged by sbd, and
  /// needs a review that the base branch's rules ask for. A session therefore
  /// stays in Needs you, Ready to merge, Claude can continue, or Working. The
  /// reason keeps a wait's or a dependency's line after the PR's. A Waiting
  /// session whose PR needs no review stays Waiting, and its reason says why.
  static func readyForReview(_ verdict: Verdict, _ facts: SessionFacts) -> Verdict? {
    guard verdict.state == .waiting, let pr = readyPR(facts) else { return nil }
    guard let line = readyPRLine(facts) else {
      var out = verdict
      out.reason = oneLine("\(verdict.reason); \(whyNotReadyForReview(pr))", max: 200)
      return out
    }
    return Verdict(state: .readyForReview, reason: oneLine("\(line); \(verdict.reason)", max: 200), kind: verdict.kind)
  }

  /// The PR when it is open, not a draft, not in Trunk's queue, and not
  /// merged by sbd.
  static func readyPR(_ facts: SessionFacts) -> PullRequest? {
    guard let pr = facts.pr, pr.ready, pr.queue?.isQueued != true, facts.currentMerge?.result != .merged
    else { return nil }
    return pr
  }

  /// "#N title; review state, checks" for a PR that can be in Ready for
  /// review: a ready PR that needs a review. Nil for any other PR.
  static func readyPRLine(_ facts: SessionFacts) -> String? {
    guard let pr = readyPR(facts), pr.needsReview == true else { return nil }
    let checks = pr.checks.map { "checks \($0.lowercased())" } ?? "no checks"
    let title = pr.title.isEmpty ? "" : " \(pr.title)"
    return "#\(pr.number)\(title); \(reviewState(pr)), \(checks)"
  }

  /// Whether GitHub requires a review, then who approved, who requested
  /// changes, and whose review GitHub still asks for.
  static func reviewState(_ pr: PullRequest) -> String {
    var parts: [String] = []
    if pr.reviewDecision == .reviewRequired { parts.append("review required") }
    if !pr.approvers.isEmpty { parts.append("approved by \(names(pr.approvers))") }
    if !pr.changesRequestedBy.isEmpty {
      parts.append("changes requested by \(names(pr.changesRequestedBy))")
    } else if pr.reviewDecision == .changesRequested {
      parts.append("changes requested")
    }
    if let requested = pr.reviewRequests, !requested.isEmpty {
      parts.append("review requested from \(names(requested))")
    }
    return parts.joined(separator: "; ")
  }

  /// Why a ready PR is not in Ready for review.
  static func whyNotReadyForReview(_ pr: PullRequest) -> String {
    if pr.needsReview == nil { return "#\(pr.number): GitHub's review rule not read yet" }
    return pr.reviewDecision == .approved ? "#\(pr.number) approved" : "#\(pr.number) needs no review"
  }
}
