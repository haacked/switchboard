import Foundation
import SwitchboardCore

extension Service {
  /// Removes the worktree and the local branch of a session whose PR merged,
  /// and keeps the session in Done. Every check of `checkCleanup` runs first,
  /// and a turn that is running also refuses, so a refusal changes nothing.
  /// The checks run again after `finishPaneStop` returns, which waits for
  /// claude, the panes' processes, and every process with the folder open to
  /// exit. A refusal at that point leaves the session, the folder, and the
  /// branch.
  /// After the worktree is gone, the session records the cleanup whatever
  /// happens to the branch, because its folder is missing. A failed delete
  /// keeps the branch and throws. A caller inside the session is refused
  /// before anything stops, as `beginPaneStop` describes.
  func cleanup(_ args: JSON, caller: Caller) throws -> JSON {
    let command = "sb cleanup"
    let ancestry = try caller.ancestry(command: command)
    let (session, pr, sharedWith): (Session, PullRequest?, String?) = try queue.sync {
      let id = try lookup(args)
      guard !starting.contains(id) else { throw APIError("\(mention(id)) is starting") }
      let e = entries[id]!
      if e.facts.cleanedUp != nil { throw APIError("\(mention(id)) is already cleaned up") }
      try requireNoTurn(e)
      return (e.session, e.facts.pr, sharedSession(e.session))
    }
    let site = self.site(for: session)
    try awaitSite(site)
    var branchName = session.branch ?? ""
    var worktreeRemoved = false
    var branchRemoved = false
    var branchError: Error?
    do {
      // On a host, every check and every git command runs on one connection, and the scope's machine refuses
      // each command once one got no answer.
      try site.scoped("the cleanup of \(session.id)") { scope in
        let at = scope.site
        let (repo, branch, supacode, pr) = try checkCleanup(session, pr: pr, sharedWith: sharedWith, at: at)
        branchName = branch?.name ?? session.branch ?? ""
        let fresh = try freshSnapshot(of: session)
        let stop: PaneStop = try queue.sync {
          guard let e = entries[session.id], e.session.cwd == session.cwd, !starting.contains(session.id) else {
            throw APIError(
              "\(session.mention) changed while it was being cleaned up")
          }
          try requireNoTurn(e)
          install(fresh, of: session)
          try scope.require()
          return try beginPaneStop(session.id, ancestry: ancestry, command: command)
        }
        try finishPaneStop(session, stop, command: command)
        _ = try checkCleanup(session, pr: pr, sharedWith: sharedWith, at: at)
        try removeWorktree(repo, session.cwd, at: at)
        worktreeRemoved = true
        if let branch {
          do {
            branchRemoved = try deleteBranch(repo, branch, pr: pr, inMain: supacode, at: at)
          } catch {
            branchError = error
          }
        }
      }
    } catch  where worktreeRemoved {
      // The branch's step keeps its own error. Only the scope's final check reaches here: the link dropped or a host
      // command got no answer after the worktree was removed. The cleanup is still recorded.
      logLine("cleanup \(session.id): \(error)")
    }
    queue.sync {
      _ = record(
        session.id, "cleanup",
        [
          "worktree": .string(session.cwd), "branch": .string(branchName),
          "branch_removed": .bool(branchRemoved),
        ])
    }
    if let branchError {
      throw APIError(
        "Removed the worktree of \(session.mention), and kept \(branchName): \(branchError)"
      )
    }
    return ["cleaned": .string(session.id), "worktree": .string(session.cwd), "branch": .string(branchName)]
  }

  /// The message of the first cleanup check that fails for the session with
  /// this PR, or nil when cleanup can run. The poller passes the PR it just
  /// read, because the session's facts may still hold the PR's earlier state.
  /// It runs git, so it runs off the state queue. For a session on a host, it
  /// does not wait for the host, and a host that is not ready blocks cleanup.
  func cleanupBlocker(_ id: String, pr: PullRequest) -> String? {
    let (found, gone): ((Session, String?)?, String?) = queue.sync {
      guard let e = entries[id] else { return (nil, "\(mention(id)) is gone") }
      return ((e.session, sharedSession(e.session)), nil)
    }
    guard let (session, sharedWith) = found else { return gone }
    do {
      _ = try site(for: session).scoped("the cleanup check of \(id)") {
        try checkCleanup(session, pr: pr, sharedWith: sharedWith, at: $0.site)
      }
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Returns the repo, the branch with its tip, and the PR, or throws unless
  /// the PR merged the session's branch, sbd made the session's worktree and
  /// its folder exists, and `checkWorktreeIsLossless` and `checkBranchIsMerged`
  /// pass. Those two refuse a shared, locked, or dirty worktree, ignored files
  /// that are not build output, and a branch whose tip is not the merged PR's
  /// head commit. A worktree that Supacode locked passes the lock check, and
  /// its branch follows `supacodeBranch`, which may keep it. On a host, the PR
  /// counts only as `provenPR` finds it. The checks run git at `site`.
  private func checkCleanup(_ session: Session, pr: PullRequest?, sharedWith: String?, at site: any SessionSite)
    throws -> (repo: String, branch: (name: String, tip: String)?, supacode: Bool, pr: PullRequest)
  {
    guard let pr, pr.state != .open else {
      throw APIError("\(session.mention) has no merged PR.")
    }
    guard pr.state == .merged else {
      throw APIError("#\(pr.number) closed without merging, so its branch may hold the only copy of the work.")
    }
    guard session.repo != nil else {
      throw APIError(
        "sbd didn't make the worktree of \(session.mention) at \(session.cwd), so cleanup leaves it alone."
      )
    }
    guard try !folderIsGone(session.cwd, at: site) else {
      throw APIError("\(session.cwd) is gone. `sb rm --worktree` removes the session and the worktree's record.")
    }
    guard let proven = try provenPR(pr, of: session, in: session.cwd, at: site) else {
      throw APIError(
        "#\(pr.number) is not a PR of \(session.branch ?? "the branch") in the repo that \(session.cwd) pushes to, so it is no proof that the work merged."
      )
    }
    let (repo, supacode) = try checkWorktreeIsLossless(
      session, mergedPR: true, sharedWith: sharedWith, onlyBuildOutputIgnored: true, at: site)
    let branch =
      supacode
      ? try supacodeBranch(session, pr: proven, at: site) : try checkBranchIsMerged(session, pr: proven, at: site)
    return (repo, branch, supacode, proven)
  }

  /// Throws for a follow-up that hasn't started, and for a session whose
  /// folder is gone. tmux starts a pane whose folder is missing in the home
  /// folder. For a session on a host, it throws `HostUnread` unless the host answered the check, so a folder
  /// is reported gone only when the host said so.
  func requireFolder(_ session: Session) throws {
    try refuseNotStarted(session)
    let exists = try site(for: session).confirmed("the folder of \(session.id)") { $0.exists(session.cwd) }
    guard !exists else { return }
    if entries[session.id]?.facts.cleanedUp != nil {
      throw APIError("\(session.mention) was cleaned up, and its worktree is gone.")
    }
    throw APIError(
      "\(session.cwd) is gone, so \(session.mention) can't start there.")
  }

  private func requireNoTurn(_ e: Entry) throws {
    if e.facts.turnRunning {
      throw APIError(
        "\(e.session.mention) is running a turn. Clean it up once the turn ends.")
    }
  }
}
