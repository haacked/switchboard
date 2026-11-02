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

  init(_ session: SessionSummary, folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
    guard session.repo != nil else { return }
    guard folderExists(session.cwd) else {
      worktreeNote = "the folder is gone"
      branchNote = "the folder is gone"
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
