import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelSelection {
  func summary(_ id: String, state: AttentionState = .needsYou) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.triage = TriageItem(title: "Pick one", kind: .decision, summary: "", source: .summary)
    return s
  }

  func model(_ ids: [String]) -> BoardModel {
    // apply() sets the Dock badge, which needs NSApp.
    _ = NSApplication.shared
    let model = BoardModel()
    model.apply(.success(ids.map { summary($0) }), followups: nil)
    return model
  }

  @Test func clearsASelectionWhoseSessionWasRemoved() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    #expect(model.selection == nil)
  }

  @Test func keepsASelectionWhoseSessionRemains() {
    let model = model(["a", "b"])
    model.selection = "a"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "a")
  }

  @Test func keepsASelectionThatNoRefreshHasListedYet() {
    // `create` selects the new session before a refresh lists it.
    let model = model(["a"])
    model.selection = "new"
    model.apply(.success([summary("a")]), followups: nil)
    #expect(model.selection == "new")
  }

  @Test func nextNeedingYouWithAStaleSelectionActsAsWithNone() {
    let model = model(["a", "b"])
    model.show(board: false)
    model.selection = "a"
    model.apply(.success([summary("b")]), followups: nil)
    let jumps = model.queueJumps
    model.selectNextNeedingYou()
    #expect(model.selection == nil)
    #expect(model.queueJumps == jumps + 1)
  }
}
