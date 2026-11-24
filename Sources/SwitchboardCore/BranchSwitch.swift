/// A work session keeps the branch it started on. Follow-up work belongs in a new session, so each PR has a
/// session that follows it through review and merge.
public enum BranchSwitch {
  /// The guidance that the default system prompt gives every agent.
  public static let guidance =
    "Keep the branch that your session started on for the session's whole life. When you need to work on a follow-up, start a new session on its own branch and worktree with the `spawn` tool or `sb spawn`. Don't check out another branch in your own folder. Each PR then has its own session to follow it through review and merge."

  /// The branch that a work session started on, when its folder has since checked out another branch and the
  /// session had a PR before. Nil otherwise. A session that started on `main` in an existing checkout and then
  /// made its feature branch had no PR before the checkout, so it gives nil.
  public static func startBranch(_ session: Session, _ facts: SessionFacts) -> String? {
    guard session.kind == .work, let start = session.branch, let live = facts.branch, live != start,
      !facts.earlierPRNumbers.isEmpty || facts.refusedPR != nil
    else { return nil }
    return start
  }
}

extension SessionFacts {
  /// The numbers of every PR that the session has had except its current one, in ascending order.
  public var earlierPRNumbers: [Int] {
    prNumbers.filter { $0 != pr?.number }.sorted()
  }
}

extension SessionSummary {
  /// The warning for a session whose folder moved off the branch it started on, or nil when it didn't.
  public var branchSwitchNote: String? {
    guard let startBranch, let branch else { return nil }
    return "Switched from \(startBranch) to \(branch). Start follow-up work in a new session."
  }
}
