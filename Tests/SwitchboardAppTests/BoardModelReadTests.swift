import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelRead {
  @Test func readsTheFollowupsBeforeTheSessions() {
    var order: [String] = []
    _ = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      },
      followups: {
        order.append("followup-ls")
        return []
      })
    #expect(order == ["followup-ls", "ls"])
  }

  @Test func readsOnlyTheSessionsWithoutAFollowupRead() {
    var order: [String] = []
    let (_, more) = BoardModel.read(
      sessions: {
        order.append("ls")
        return []
      }, followups: nil)
    #expect(order == ["ls"])
    #expect(more == nil)
  }
}
