import SwiftUI
import SwitchboardCore

/// The Clean Up confirmation for a session whose cleanup checks passed.
struct CleanupOffer {
  var session: SessionSummary

  init?(_ s: SessionSummary) {
    guard Self.canCleanUp(s) else { return nil }
    session = s
  }

  static func canCleanUp(_ s: SessionSummary) -> Bool { s.cleanup?.state == .ready }

  var title: String { "Clean up \(session.name)?" }

  var message: String {
    let branchPart = session.branch.map { " and the local branch \($0)" } ?? ""
    return "This stops claude, closes both terminals, and deletes the worktree \(session.cwd)\(branchPart)."
      + " The session stays in Done with its transcript, and the remote branch stays."
      + " sbd checks again first. It refuses, and removes nothing, when a turn is running, the folder has a file that is not committed or build output, or the branch has a commit after the merge."
  }

  /// The failed check of a blocked cleanup. A removed cleanup needs no line,
  /// because the session's reason already says what cleanup removed.
  static func blockedNote(_ s: SessionSummary) -> String? {
    guard let cleanup = s.cleanup, cleanup.state == .blocked else { return nil }
    return "Cleanup blocked: \(cleanup.reason ?? "a check failed")"
  }
}

/// Asks to clean up a session whose cleanup is ready. The dialog is on ContentView.
struct CleanupButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    Button {
      model.confirmingCleanup = session.id
    } label: {
      Image(systemName: "sparkles")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(model.cleaningUp.contains(session.id))
    .accessibilityLabel("Clean up \(session.name): delete its worktree and local branch")
    .help("Clean up: delete the worktree and the local branch, and keep the session in Done…")
  }
}

/// A blocked cleanup's failed check, or nothing.
struct CleanupNote: View {
  let session: SessionSummary

  var body: some View {
    if let note = CleanupOffer.blockedNote(session) {
      Label {
        InlineText(plain: note, links: false)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .help(note)
    }
  }
}
