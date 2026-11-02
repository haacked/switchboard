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

  /// A linked worktree has a `.git` file, and a main checkout has a `.git` folder.
  static func hasGitFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  init(
    _ session: SessionSummary,
    folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isLinkedWorktree: (String) -> Bool = RemoveOptions.hasGitFile
  ) {
    guard session.repo != nil else { return }
    guard folderExists(session.cwd) else {
      worktreeNote = "the folder is gone"
      branchNote = "the folder is gone, so there is no worktree to remove first"
      return
    }
    guard isLinkedWorktree(session.cwd) else {
      worktreeNote = "this is the main checkout, not a worktree"
      branchNote = "this is the main checkout, not a worktree"
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
