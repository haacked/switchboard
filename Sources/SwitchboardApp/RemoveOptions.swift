import Foundation
import SwitchboardCore

/// The initial state of the remove dialog's checkboxes. A box that can do
/// nothing for the session starts unchecked and disabled, with its reason in
/// `worktreeNote` or `branchNote`. sbd still makes every safety check.
struct RemoveOptions: Equatable {
  var worktree = false
  var worktreeEnabled = false
  var worktreeNote: String?
  var branch = false
  var branchEnabled = false
  var branchNote: String?

  /// True when `path` is the top folder of a linked worktree: git's own folder differs from the folder that
  /// the worktrees share. A subfolder and a main checkout fail it, and so does any folder that git can't read.
  static func isLinkedWorktree(_ path: String) -> Bool {
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = [
      "-C", path, "rev-parse", "--show-prefix", "--path-format=absolute", "--git-dir", "--git-common-dir",
    ]
    let out = Pipe()
    git.standardOutput = out
    git.standardError = FileHandle.nullDevice
    guard (try? git.run()) != nil else { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    guard git.terminationStatus == 0, lines.count >= 3, lines[0].isEmpty else { return false }
    return URL(fileURLWithPath: String(lines[1])).resolvingSymlinksInPath()
      != URL(fileURLWithPath: String(lines[2])).resolvingSymlinksInPath()
  }

  /// Reads the folder off the main thread, because `git rev-parse` waits on the disk.
  static func load(
    _ session: SessionSummary,
    folderExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isLinkedWorktree: @escaping @Sendable (String) -> Bool = RemoveOptions.isLinkedWorktree
  ) async -> RemoveOptions {
    await Task.detached {
      RemoveOptions(session, folderExists: folderExists, isLinkedWorktree: isLinkedWorktree)
    }.value
  }

  init(
    _ session: SessionSummary,
    folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isLinkedWorktree: (String) -> Bool = RemoveOptions.isLinkedWorktree
  ) {
    guard session.repo != nil else { return }
    guard folderExists(session.cwd) else {
      worktreeNote = "the folder is gone"
      branchNote = "the folder is gone, so there is no worktree to remove first"
      return
    }
    guard isLinkedWorktree(session.cwd) else {
      worktreeNote = "this is not the top folder of a linked worktree"
      branchNote = "this is not the top folder of a linked worktree"
      return
    }
    worktree = true
    worktreeEnabled = true
    guard session.branch != nil else { return }
    guard session.pr?.state == .merged else {
      branchNote = "kept, the PR is not merged"
      return
    }
    branch = true
    branchEnabled = true
  }
}
