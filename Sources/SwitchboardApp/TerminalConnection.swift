import Foundation
import SwitchboardCore

/// A session view's connection to the session's two terminals. It opens the
/// session in sbd, which resumes a stopped claude and answers with the panes'
/// tmux targets.
@MainActor
final class TerminalConnection: ObservableObject {
  /// Opens a session in sbd and returns its terminals. It blocks.
  typealias Request = @Sendable (String) throws -> Terminals
  typealias Sleep = @Sendable (Duration) async throws -> Void

  /// The selection rests this long on a stopped session before the
  /// connection opens it. Moving through the sidebar therefore resumes no
  /// claude that it passes.
  static let stoppedRest: Duration = .milliseconds(800)
  /// The rest before opening a live session. sbd reads every process to
  /// answer an open. The terminal then attaches a tmux client. The rest is
  /// longer than the default key repeat interval of about 90 ms. A held arrow
  /// key therefore opens no session that it passes.
  static let liveRest: Duration = .milliseconds(150)
  static let retryWait: Duration = .seconds(1)

  /// What a connection tells its owner as it goes: it starts the request after the rest, the terminals
  /// arrived, or a try failed. The activity log times the wait from these.
  struct Observer {
    var opening: () -> Void = {}
    var opened: () -> Void = {}
    var failed: (Error) -> Void = { _ in }
  }

  @Published private(set) var terminals: Terminals?
  @Published private(set) var error: String?
  private let request: Request
  private let sleep: Sleep

  init(
    request: @escaping Request = { try Client().open($0) },
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
  ) {
    self.request = request
    self.sleep = sleep
  }

  /// Runs until the terminals arrive, the tries run out, or the task is cancelled.
  func connect(_ id: String, live: Bool, observer: Observer = Observer()) async {
    try? await sleep(live ? Self.liveRest : Self.stoppedRest)
    if Task.isCancelled { return }
    observer.opening()
    let request = request
    // The request can fail while sbd restarts, so it retries for 10 s.
    for _ in 0..<10 {
      let result = await Task.detached { Result { try request(id) } }.value
      if Task.isCancelled { return }
      switch result {
      case .success(let terminals):
        self.terminals = terminals
        observer.opened()
        return
      case .failure(let error):
        self.error = "\(error)"
        observer.failed(error)
      }
      try? await sleep(Self.retryWait)
      if Task.isCancelled { return }
    }
  }
}
