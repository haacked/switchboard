import Foundation
import SwitchboardCore

/// Supacode locks the worktrees that `sb new` makes, and `git worktree
/// remove` refuses a locked worktree. sbd asks Supacode to delete such a
/// worktree instead, and never unlocks one or forces git.
extension Service {
  /// True when the reason that `git worktree list --porcelain` prints after
  /// `locked` is Supacode's JSON, whose `owner` is `supacode`. git quotes a
  /// reason that holds a quote and escapes the quotes inside it.
  static func isSupacodeLock(_ reason: Substring) -> Bool {
    var text = reason.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
      text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    }
    return JSON.parse(text)?["owner"]?.string == "supacode"
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
  /// through `git worktree remove`, which refuses every other lock. Returns
  /// true when Supacode removed it.
  func removeWorktree(_ repo: String, _ path: String) throws -> Bool {
    guard let entry = try worktreeEntry(repo, at: path), entry.lockedBySupacode else {
      _ = try gitOutput(repo, ["worktree", "remove", path])
      return false
    }
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
    return true
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
    guard let name = session.branch, try gitOutput(session.cwd, ["branch", "--show-current"]) == name else {
      throw APIError("\(session.cwd) doesn't have the branch of \(session.id) checked out.")
    }
    let tip = try gitOutput(session.cwd, ["rev-parse", "HEAD"])
    return isInMain(session.cwd, tip) ? (name, tip) : nil
  }

  /// Deletes the branch that `supacodeBranch` returned, after the worktree is
  /// gone, when origin/main still contains its tip and no worktree has it
  /// checked out. Returns false when the branch stays. A branch that Supacode
  /// already deleted counts as deleted. Passing the checked tip makes git
  /// refuse when a commit landed after the check.
  func deleteBranchInMain(_ repo: String, _ branch: (name: String, tip: String)) throws -> Bool {
    guard branchExists(repo, branch.name) else { return true }
    guard isInMain(repo, branch.tip) else { return false }
    guard !(try worktreeEntries(repo).contains { $0.branch == branch.name }) else {
      throw APIError("\(branch.name) is checked out in a worktree.")
    }
    _ = try gitOutput(repo, ["update-ref", "-d", "refs/heads/\(branch.name)", branch.tip])
    _ = try? gitOutput(repo, ["config", "--remove-section", "branch.\(branch.name)"])
    return true
  }

  private func isInMain(_ dir: String, _ commit: String) -> Bool {
    (try? runCommand(git, ["-C", dir, "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"]))?.status == 0
  }
}
