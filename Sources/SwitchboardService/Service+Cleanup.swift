import Foundation
import SwitchboardCore

extension Service {
  /// Removes the worktree and the local branch of a session whose PR merged,
  /// and keeps the session in Done. Every check of `checkCleanup` runs first,
  /// and a turn that is running also refuses, so a refusal changes nothing.
  /// The checks run again after claude stops and the panes close. A refusal
  /// at that point leaves the session, the folder, and the branch, with the
  /// panes closed.
  /// After the worktree is gone, the session records the cleanup whatever
  /// happens to the branch, because its folder is missing. A failed delete
  /// keeps the branch and throws.
  func cleanup(_ args: JSON) throws -> JSON {
    let (session, pr, sharedWith): (Session, PullRequest?, String?) = try queue.sync {
      let id = try lookup(args)
      guard !starting.contains(id) else { throw APIError("\(id) is starting") }
      let e = entries[id]!
      if e.facts.cleanup?.state == .removed { throw APIError("\(id) is already cleaned up") }
      try requireNoTurn(e)
      return (e.session, e.facts.pr, sharedSession(e.session))
    }
    let (repo, branch) = try checkCleanup(session, pr: pr, sharedWith: sharedWith)
    let fresh = buildSnapshot()
    try queue.sync {
      guard let e = entries[session.id], e.session.cwd == session.cwd, !starting.contains(session.id) else {
        throw APIError("\(session.id) changed while it was being cleaned up")
      }
      try requireNoTurn(e)
      install(fresh)
      if case .running(let pid) = claudeState(session.id) { kill(pid_t(pid), SIGTERM) }
      host.kill(paneName(session.id, .claude))
      host.kill(paneName(session.id, .shell))
    }
    // The panes could write to the folder until they closed. `worktree remove` deletes ignored files.
    _ = try checkCleanup(session, pr: pr, sharedWith: sharedWith)
    _ = try gitOutput(repo, ["worktree", "remove", session.cwd])
    var branchError: Error?
    do {
      try deleteMergedBranch(repo, branch, pr: pr)
    } catch {
      branchError = error
    }
    queue.sync {
      record(
        session.id, "cleanup",
        [
          "worktree": .string(session.cwd), "branch": .string(branch.name),
          "branch_removed": .bool(branchError == nil),
        ])
    }
    if let branchError {
      throw APIError("Removed the worktree of \(session.id), and kept \(branch.name): \(branchError)")
    }
    return ["cleaned": .string(session.id), "worktree": .string(session.cwd), "branch": .string(branch.name)]
  }

  /// The message of the first cleanup check that fails for the session with
  /// this PR, or nil when cleanup can run. The poller passes the PR it just
  /// read, because the session's facts may still hold the PR's earlier state.
  /// It runs git, so it runs off the state queue.
  func cleanupBlocker(_ id: String, pr: PullRequest) -> String? {
    let found: (Session, String?)? = queue.sync {
      entries[id].map { ($0.session, sharedSession($0.session)) }
    }
    guard let (session, sharedWith) = found else { return "\(id) is gone" }
    do {
      _ = try checkCleanup(session, pr: pr, sharedWith: sharedWith)
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Returns the repo and the branch with its tip, or throws unless the PR
  /// merged the session's branch, sbd made the session's worktree and its
  /// folder exists, and `checkWorktreeIsLossless` and `checkBranchIsMerged`
  /// pass. Those two refuse a shared, locked, or dirty worktree, ignored files
  /// that are not build output, and a branch whose tip is not the merged PR's
  /// head commit.
  private func checkCleanup(_ session: Session, pr: PullRequest?, sharedWith: String?) throws -> (
    repo: String, branch: (name: String, tip: String)
  ) {
    guard let pr, pr.state != .open else { throw APIError("\(session.id) has no merged PR.") }
    guard pr.state == .merged else {
      throw APIError("#\(pr.number) closed without merging, so its branch may hold the only copy of the work.")
    }
    guard session.repo != nil else {
      throw APIError("sbd didn't make the worktree of \(session.id) at \(session.cwd), so cleanup leaves it alone.")
    }
    guard FileManager.default.fileExists(atPath: session.cwd) else {
      throw APIError("\(session.cwd) is gone. `sb rm --worktree` removes the session and the worktree's record.")
    }
    let repo = try checkWorktreeIsLossless(
      session, mergedPR: true, sharedWith: sharedWith, onlyBuildOutputIgnored: true)
    return (repo, try checkBranchIsMerged(session, pr: pr))
  }

  /// Throws for a session whose worktree `sb cleanup` removed. tmux starts a
  /// pane whose folder is missing in the home folder.
  func refuseCleanedUp(_ id: String) throws {
    if entries[id]?.facts.cleanup?.state == .removed {
      throw APIError("\(id) was cleaned up, and its worktree is gone.")
    }
  }

  private func requireNoTurn(_ e: Entry) throws {
    if e.facts.turnRunning {
      throw APIError("\(e.session.id) is running a turn. Clean it up once the turn ends.")
    }
  }
}
