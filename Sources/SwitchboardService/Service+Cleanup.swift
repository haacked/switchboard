import Foundation
import SwitchboardCore

extension Service {
  /// Removes the worktree and the local branch of a session whose PR merged,
  /// and keeps the session in Done. Every check of `checkCleanup` runs first,
  /// and a turn that is running also refuses, so a refusal changes nothing.
  /// The checks run again after claude exits and the panes close. A claude
  /// that has not exited 5 s after SIGTERM refuses. Its pane stays open, so
  /// that a later cleanup finds it. A refusal at that point leaves the
  /// session, the folder, and the branch.
  /// After the worktree is gone, the session records the cleanup whatever
  /// happens to the branch, because its folder is missing. A failed delete
  /// keeps the branch and throws.
  func cleanup(_ args: JSON) throws -> JSON {
    let (session, pr, sharedWith): (Session, PullRequest?, String?) = try queue.sync {
      let id = try lookup(args)
      guard !starting.contains(id) else { throw APIError("\(id) is starting") }
      let e = entries[id]!
      if e.facts.cleanedUp != nil { throw APIError("\(id) is already cleaned up") }
      try requireNoTurn(e)
      return (e.session, e.facts.pr, sharedSession(e.session))
    }
    let (repo, branch) = try checkCleanup(session, pr: pr, sharedWith: sharedWith)
    let branchName = branch?.name ?? session.branch ?? ""
    let fresh = buildSnapshot()
    let claudePid: Int? = try queue.sync {
      guard let e = entries[session.id], e.session.cwd == session.cwd, !starting.contains(session.id) else {
        throw APIError("\(session.id) changed while it was being cleaned up")
      }
      try requireNoTurn(e)
      install(fresh)
      host.kill(paneName(session.id, .shell))
      guard case .running(let pid) = claudeState(session.id) else { return nil }
      kill(pid_t(pid), SIGTERM)
      return pid
    }
    // claude can write to the folder until it exits. `worktree remove` deletes ignored files.
    if let claudePid, !Processes.waitForExit([claudePid], seconds: 5).isEmpty {
      throw APIError("\(session.id)'s claude has not exited. Run `sb cleanup` again once it has.")
    }
    host.kill(paneName(session.id, .claude))
    _ = try checkCleanup(session, pr: pr, sharedWith: sharedWith)
    let supacodeRemoved = try removeWorktree(repo, session.cwd)
    var branchRemoved = false
    var branchError: Error?
    if let branch {
      do {
        if supacodeRemoved {
          branchRemoved = try deleteBranchInMain(repo, branch)
        } else {
          try deleteMergedBranch(repo, branch, pr: pr)
          branchRemoved = true
        }
      } catch {
        branchError = error
      }
    }
    queue.sync {
      record(
        session.id, "cleanup",
        [
          "worktree": .string(session.cwd), "branch": .string(branchName),
          "branch_removed": .bool(branchRemoved),
        ])
    }
    if let branchError {
      throw APIError("Removed the worktree of \(session.id), and kept \(branchName): \(branchError)")
    }
    return ["cleaned": .string(session.id), "worktree": .string(session.cwd), "branch": .string(branchName)]
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
  /// head commit. A worktree that Supacode locked passes the lock check, and
  /// its branch follows `supacodeBranch`, which may keep it.
  private func checkCleanup(_ session: Session, pr: PullRequest?, sharedWith: String?) throws -> (
    repo: String, branch: (name: String, tip: String)?
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
    let (repo, supacode) = try checkWorktreeIsLossless(
      session, mergedPR: true, sharedWith: sharedWith, onlyBuildOutputIgnored: true)
    return (repo, supacode ? try supacodeBranch(session) : try checkBranchIsMerged(session, pr: pr))
  }

  /// Throws for a follow-up that hasn't started, and for a session whose
  /// folder is gone. tmux starts a pane whose folder is missing in the home
  /// folder.
  func requireFolder(_ session: Session) throws {
    try refuseNotStarted(session)
    guard !FileManager.default.fileExists(atPath: session.cwd) else { return }
    if entries[session.id]?.facts.cleanedUp != nil {
      throw APIError("\(session.id) was cleaned up, and its worktree is gone.")
    }
    throw APIError("\(session.cwd) is gone, so \(session.id) can't start there.")
  }

  private func requireNoTurn(_ e: Entry) throws {
    if e.facts.turnRunning {
      throw APIError("\(e.session.id) is running a turn. Clean it up once the turn ends.")
    }
  }
}
