import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The model's blocking requests go to the client it was built with, never to the sbd that `SB_HOME` names.
@MainActor
@Suite struct BoardModelClient {
  enum Request: CaseIterable { case importable, importSessions }

  @Test(arguments: Request.allCases) func aBlockingRequestGoesToTheInjectedClient(_ request: Request) async {
    _ = NSApplication.shared
    let client = offlineClient()
    let model = BoardModel(client: client)

    let error: String? = await Task.detached { [model] in
      switch request {
      case .importable:
        if case .failure(let error) = model.importable(all: false, repo: nil) { "\(error)" } else { nil }
      case .importSessions:
        if case .failure(let error) = model.importSessions(["a"], stop: []) { "\(error)" } else { nil }
      }
    }.value

    #expect(error?.contains(client.home.socket) == true, "\(error ?? "no error")")
  }
}
