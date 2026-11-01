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

  @Test func findsARootAndEveryDescendant() {
    let list = [
      summary("m"), summary("x"), summary("c", parent: "b"), summary("b", parent: "m"), summary("y", parent: "x"),
    ]
    #expect(subtreeLayout("m", list) == ["m", ">b", ">>c"])
    #expect(SessionTree.subtree(of: "none", in: list).isEmpty)
  }

  func subtreeLayout(_ root: String, _ sessions: [SessionSummary]) -> [String] {
    SessionTree.subtree(of: root, in: sessions).map { String(repeating: ">", count: $0.depth) + $0.id }
  }

  @Test func aDoneChildLeavesTheSubtree() {
    let list = [summary("m"), summary("a", parent: "m", state: .done), summary("b", parent: "m")]
    #expect(subtreeLayout("m", list) == ["m", ">b"])
  }

  @Test func aDoneChildReturnsWhenItIsNoLongerDone() {
    let list = [summary("m"), summary("a", parent: "m", state: .needsYou), summary("b", parent: "m")]
    #expect(subtreeLayout("m", list) == ["m", ">a", ">b"])
  }

  @Test func childrenOfADoneChildStayUnderTheNearestListedAncestor() {
    let list = [
      summary("m"), summary("a", parent: "m", state: .done), summary("b", parent: "a"),
      summary("c", parent: "a", state: .done), summary("d", parent: "c"), summary("e", parent: "b"),
    ]
    #expect(subtreeLayout("m", list) == ["m", ">b", ">>e", ">d"])
  }

  @Test func aDoneRootStillHasARow() {
    let list = [summary("m", state: .done), summary("a", parent: "m", state: .done)]
    #expect(subtreeLayout("m", list) == ["m"])
  }

  @Test func doneSessionsThatNameEachOtherDoNotLoop() {
    let list = [summary("m", parent: "a"), summary("a", parent: "m", state: .done), summary("b", parent: "a")]
    #expect(subtreeLayout("m", list) == ["m", ">b"])
  }
}
