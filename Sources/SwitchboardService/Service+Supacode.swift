import Foundation
import SwitchboardCore

/// Supacode locks the worktrees that `sb new` makes, and `git worktree
/// remove` refuses a locked worktree. sbd asks Supacode to delete such a
/// worktree instead, and never unlocks one or forces git.
extension Service {
  /// True when the reason that `git worktree list --porcelain -z` prints
  /// after `locked` is Supacode's JSON, whose `owner` is `supacode`.
  static func isSupacodeLock(_ reason: Substring) -> Bool {
    JSON.parse(reason.trimmingCharacters(in: .whitespaces))?["owner"]?.string == "supacode"
  }

  /// The supacode program, or throws when sbd can't find it.
  func supacodeExecutable() throws -> String {
    guard let path = findExecutable(config.supacode) else {
      throw APIError("Supacode locked the worktree, and sbd can't find \(config.supacode) to delete it.")
    }
    return path
  }

  /// Removes the linked worktree that git lists at `path`. A worktree that
  /// Supacode locked goes through `supacode worktree delete`, and any other
  /// through `git worktree remove`, which refuses every other lock. It reads
  /// the lock again, so it acts on the lock that git lists now. Supacode runs `git branch -D` on the
  /// worktree's branch when its `deleteBranchOnDeleteWorktree` setting is on.
  /// sbd's checks decide whether the branch goes, so a branch that Supacode
  /// deleted comes back at the tip and with the config that it had.
  func removeWorktree(_ repo: String, _ path: String) throws {
    guard let entry = try worktreeEntry(repo, at: path), entry.lockedBySupacode else {
      _ = try gitOutput(repo, ["worktree", "remove", path])
      return
    }
    let kept: (name: String, tip: String, config: [(String, String)])? = try {
      guard let name = entry.branch, let tip = entry.head else { return nil }
      return (name, tip, try branchConfig(repo, name))
    }()
    let result = try runCommand(
      try supacodeExecutable(), ["worktree", "delete", "--worktree", Self.supacodeID(entry.path), "--background"],
      timeout: 200)
    guard result.status == 0 else {
      let output = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
      throw APIError(
        "supacode couldn't delete the worktree \(entry.path): \(output.isEmpty ? "exit \(result.status)" : output)")
    }
    guard try worktreeEntry(repo, at: path) == nil else {
      throw APIError("supacode reported that it deleted \(entry.path), but git still lists the worktree.")
    }
    if let kept, !branchExists(repo, kept.name) {
      // The empty old value makes git refuse when the ref exists.
      _ = try gitOutput(repo, ["update-ref", "refs/heads/\(kept.name)", kept.tip, ""])
      for (key, value) in kept.config { _ = try? gitOutput(repo, ["config", "--local", "--add", key, value]) }
    }
  }

  /// The repo's own config entries for the branch, in the order git lists them.
  private func branchConfig(_ repo: String, _ branch: String) throws -> [(String, String)] {
    let prefix = "branch.\(branch)."
    return try gitOutput(repo, ["config", "--local", "-z", "--list"]).split(separator: "\0").compactMap { entry in
      let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = parts.first, key.hasPrefix(prefix) else { return nil }
      return (String(key), parts.count > 1 ? String(parts[1]) : "")
    }
  }

  /// Supacode's id for a worktree: its absolute path with a trailing slash, percent-encoded.
  static func supacodeID(_ path: String) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let folder = path.hasSuffix("/") ? path : path + "/"
    return folder.addingPercentEncoding(withAllowedCharacters: unreserved) ?? folder
  }

  /// The branch to delete with a worktree that Supacode locked, and its tip.
  /// It is nil, so the branch stays, unless origin/main contains the tip. A
  /// squash merge leaves the tip outside origin/main. Throws when the
  /// worktree doesn't have the session's branch checked out.
  func supacodeBranch(_ session: Session) throws -> (name: String, tip: String)? {
    let branch = try checkedOutBranch(session)
    return isInMain(session.cwd, branch.tip) ? branch : nil
  }

  /// Deletes the checked branch once the worktree is gone, by the rule that
  /// checked it: `deleteBranchInMain` when `supacodeBranch` checked it, and
  /// otherwise `deleteMergedBranch`. Returns false when the branch stays.
  func deleteBranch(
    _ repo: String, _ branch: (name: String, tip: String), pr: PullRequest?, inMain: Bool
  ) throws -> Bool {
    if inMain { return try deleteBranchInMain(repo, branch) }
    try deleteMergedBranch(repo, branch, pr: pr)
    return true
  }

  /// Deletes the branch that `supacodeBranch` returned, after the worktree is
  /// gone, when origin/main still contains its tip and no worktree has it
  /// checked out. Returns false when the branch stays.
  func deleteBranchInMain(_ repo: String, _ branch: (name: String, tip: String)) throws -> Bool {
    guard branchExists(repo, branch.name) else { throw APIError("\(branch.name) no longer exists.") }
    guard isInMain(repo, branch.tip) else { return false }
    try requireNotCheckedOut(repo, branch.name)
    try deleteBranchRef(repo, branch)
    return true
  }

  private func isInMain(_ dir: String, _ commit: String) -> Bool {
    (try? runCommand(git, ["-C", dir, "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"]))?.status == 0
  }
}
