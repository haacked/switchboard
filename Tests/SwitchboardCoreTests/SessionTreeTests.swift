import Testing

@testable import SwitchboardCore

@Suite struct SessionTreeTests {
  func summary(_ id: String, parent: String? = nil, state: AttentionState = .working) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.parent = parent
    return s
  }

  func layout(_ sessions: [SessionSummary]) -> [String] {
    SessionTree.rows(sessions).map { String(repeating: ">", count: $0.depth) + $0.session.id }
  }

  @Test func putsChildrenUnderTheirParent() {
    let list = [
      summary("a"), summary("x"), summary("b", parent: "a"), summary("c", parent: "b"), summary("d", parent: "a"),
    ]
    #expect(layout(list) == ["a", ">b", ">>c", ">d", "x"])
  }

  @Test func aChildWhoseParentIsNotListedStaysAtTheTop() {
    #expect(layout([summary("b", parent: "gone"), summary("a")]) == ["b", "a"])
  }

  @Test func aFollowupStaysAtTheTop() {
    var f = summary("f", parent: "a")
    f.followup = Followup(prompt: "p")
    #expect(layout([summary("a"), f]) == ["a", "f"])
  }

  @Test func sessionsThatNameEachOtherStillAppearOnce() {
    #expect(layout([summary("a", parent: "b"), summary("b", parent: "a")]) == ["a", ">b"])
    #expect(layout([summary("a", parent: "a")]) == ["a"])
  }
}
