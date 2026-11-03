import Foundation

/// The rules for a session whose open PR waits on other PRs. They follow the
/// Held group of `/sessions`, which sbd shows as Waiting.
extension Attention {
  /// Needs you when a dependency closed unmerged. Waiting when the PR
  /// conflicts with a stack base whose session's turn runs, because the base
  /// may still move.
  static func blockedPR(_ facts: SessionFacts, stateOf: (String) -> AttentionState?) -> Verdict? {
    guard let pr = facts.pr, pr.state == .open else { return nil }
    if let closed = facts.dependencies.first(where: \.closed) {
      return Verdict(
        state: .needsYou, reason: oneLine("decide what replaces \(closed.label(from: pr.repo)), which closed unmerged"))
    }
    guard pr.mergeable == .conflicting,
      let base = facts.dependencies.first(where: {
        $0.via == .stack && $0.holds && $0.session.flatMap(stateOf) == .working
      })
    else { return nil }
    return Verdict(state: .waiting, reason: oneLine("rebase onto \(base.label(from: pr.repo)) once its turn ends"))
  }

  /// Waiting while a dependency holds the open PR and the last reply neither
  /// asks nor offers anything.
  static func heldPR(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.state == .open, let dependency = facts.dependencies.first(where: \.holds),
      classify(facts.lastReply ?? "") == .other
    else { return nil }
    let label = dependency.label(from: pr.repo)
    return Verdict(
      state: .waiting,
      reason: oneLine(dependency.state == .merged ? "waits on the deploy of \(label)" : "waits on \(label)"))
  }
}
