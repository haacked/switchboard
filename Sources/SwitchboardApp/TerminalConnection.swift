import Foundation
import SwitchboardCore

/// A session view's connection to the session's two terminals. It opens the
/// session in sbd, which resumes a stopped claude, and then asks sbd for the
/// panes' tmux targets.
@MainActor
final class TerminalConnection: ObservableObject {
  @Published private(set) var terminals: Terminals?
  @Published private(set) var error: String?

  /// Runs until the terminals arrive, the tries run out, or the task is cancelled.
  func connect(_ id: String, model: BoardModel) async {
    // Opening a session resumes a stopped claude. The selection has to rest
    // first, so moving through the sidebar resumes nothing on the way.
    try? await Task.sleep(nanoseconds: 800_000_000)
    if Task.isCancelled { return }
    model.open(id)
    // The terminals call can fail while sbd restarts, so it retries for 10 s.
    for _ in 0..<10 {
      switch await Task.detached(operation: { model.terminals(id) }).value {
      case .success(let terminals):
        self.terminals = terminals
        return
      case .failure(let error):
        self.error = "\(error)"
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      if Task.isCancelled { return }
    }
  }
}
