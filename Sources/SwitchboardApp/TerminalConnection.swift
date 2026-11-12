import Foundation
import SwitchboardCore

/// A session view's connection to the session's two terminals. It opens the
/// session in sbd, which resumes a stopped claude and answers with the panes'
/// tmux targets.
@MainActor
final class TerminalConnection: ObservableObject {
  struct Delays {
    /// How long the selection rests before the connection opens the session.
    var rest: Duration = .milliseconds(800)
    var retry: Duration = .seconds(1)
  }

  @Published private(set) var terminals: Terminals?
  @Published private(set) var error: String?
  let delays: Delays

  init(delays: Delays = Delays()) { self.delays = delays }

  /// Runs until the terminals arrive, the tries run out, or the task is cancelled.
  func connect(_ id: String, model: BoardModel) async {
    // Opening a session resumes a stopped claude. The selection has to rest
    // first, so moving through the sidebar resumes nothing on the way.
    try? await Task.sleep(for: delays.rest)
    if Task.isCancelled { return }
    let send = model.send
    // The request can fail while sbd restarts, so it retries for 10 s.
    for _ in 0..<10 {
      let result = await Task.detached {
        Result { try Terminals(opened: send("open", ["session": .string(id), "terminals": true])) }
      }.value
      if Task.isCancelled { return }
      switch result {
      case .success(let terminals):
        self.terminals = terminals
        model.refresh(followups: true)
        return
      case .failure(let error):
        self.error = "\(error)"
      }
      try? await Task.sleep(for: delays.retry)
      if Task.isCancelled { return }
    }
  }
}
