import Foundation
import SwitchboardCore
import Testing

// A `try` inside `#expect` fails to compile in these closures. Each check therefore binds the thrown value first.

/// `sb parent <session> --clear` unlinks a session from the session that started it, and `sb parent <session>
/// <parent>` moves it to another parent. The parent stops hearing what changed in it. The MCP tool `set_parent` sends
/// the same request.
@Suite(.blocking(timeLimit: .seconds(120))) struct ParentLinkTests: MCPToolServerSuite {
  let family = ManagerTests()

  /// An idle parent `p` and a child `kid` that `p` started.
  func parentAndChild(_ sbd: Instance) throws -> (parent: SessionSummary, kid: SessionSummary) {
    let parent = try idle(sbd, name: "p")
    let kid = try family.child(sbd, of: parent.id, name: "kid")
    try #require(kid.parent == parent.id, "the setup started kid outside p")
    return (parent, kid)
  }

  /// The `unlinked` and `linked` events of the session, oldest first.
  func linkEvents(_ sbd: Instance, _ id: String) throws -> [Event] {
    try sbd.events(id).filter { $0.kind == "unlinked" || $0.kind == "linked" }
  }

  // MARK: Unlinking

  @Test func unlinkClearsTheParentInLsAndGet() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)

    try sbd.sb("parent", kid.id, "--clear")

    let actual1 = try sbd.listed(kid.id)["parent"]
    #expect(actual1 == nil)
    let actual2 = try sbd.getJSON(kid.id)["parent"]
    #expect(actual2 == nil)
  }

  @Test func unlinkJSONPrintsTheSummaryWithoutAParent() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)

    let got = try #require(JSON.parse(try sbd.sb("parent", kid.id, "--clear", "--json")))

    #expect(got["id"]?.string == kid.id)
    #expect(got["parent"] == nil, "\(got)")
  }

  @Test func unlinkRecordsUnlinkedOnTheChildByYou() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    try sbd.sb("parent", kid.id, "--clear")

    let events = try sbd.events(kid.id, kind: "unlinked")
    #expect(events.count == 1)
    #expect(events.first?.data["parent"]?.string == parent.id)
    #expect(events.first?.data["by"] == "you")
  }

  @Test func unlinkRecordsUnlinkedOnTheParentByYou() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    try sbd.sb("parent", kid.id, "--clear")

    let events = try sbd.events(parent.id, kind: "unlinked")
    #expect(events.count == 1)
    #expect(events.first?.data["child"]?.string == kid.id)
    #expect(events.first?.data["by"] == "you")
  }

  @Test func anUnlinkThatClaudeRunsInAnotherSessionRecordsByClaude() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")

    try sbd.sb(["parent", kid.id, "--clear"], env: inside(other.id))

    let actual3 = try sbd.get(kid.id).parent
    #expect(actual3 == nil)
    let actual4 = try sbd.events(kid.id, kind: "unlinked").first?.data["by"]
    #expect(actual4 == "claude")
    let actual5 = try sbd.events(parent.id, kind: "unlinked").first?.data["by"]
    #expect(actual5 == "claude")
  }

  /// The child keeps its group, account, host, waits, notes, and PR.
  @Test func unlinkKeepsTheChildsGroupAccountHostWaitsAndNotes() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    _ = try addGroup(sbd, "Flags")
    try sbd.sb("group", "move", kid.id, "--to", "Flags")
    try sbd.sb("note", kid.id, "stacked on #1190")
    try sbd.sb("wait", kid.id, "the design review")
    let before = try sbd.get(kid.id)
    try #require(before.group != nil)
    try #require(!before.notes.isEmpty)
    try #require(!before.waits.isEmpty)

    try sbd.sb("parent", kid.id, "--clear")

    let after = try sbd.get(kid.id)
    #expect(after.group == before.group)
    #expect(after.account == before.account)
    #expect(after.host == before.host)
    #expect(after.waits == before.waits)
    #expect(after.notes == before.notes)
    #expect(after.pr == before.pr)
  }

  /// A `session` wait on the parent that targets the child keeps resolving after the unlink.
  @Test func unlinkKeepsTheParentsWaitOnTheChild() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    try sbd.sb("wait", parent.id, "--kind", "session", "--target", kid.id, "--state", "done")
    let before = try sbd.get(parent.id).waits
    try #require(before.contains { $0.kind == .session && $0.session?.id == kid.id })

    try sbd.sb("parent", kid.id, "--clear")

    let actual6 = try sbd.get(parent.id).waits
    #expect(actual6 == before)
  }

  /// Neither event is activity, so neither moves the child's state or its last activity.
  @Test func unlinkIsNotActivity() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    let before = try sbd.waitFor(kid.id, "kid's first reply") { $0.lastReply == "Done: hello" && $0.state == .needsYou }

    try sbd.sb("parent", kid.id, "--clear")

    let after = try sbd.get(kid.id)
    #expect(after.lastActivity == before.lastActivity)
    #expect(after.state == before.state)
    #expect(after.since == before.since)
  }

  // MARK: What the parent hears

  @Test(arguments: DigestTests.Parent.allCases) func anUnlinkedChildLeavesTheParentsDigest(
    _ kind: DigestTests.Parent
  ) throws {
    let sbd = try Instance()
    let digest = DigestTests()
    let m = try digest.parent(sbd, kind)
    let kid = try digest.child(sbd, of: m, name: "kid", prompt: "one")
    let kept = try digest.child(sbd, of: m, name: "kept", prompt: "one")
    for child in [kid, kept] {
      try sbd.waitFor(child.id, "\(child.name)'s reply") { $0.lastReply == "Done: one" && $0.state == .needsYou }
    }
    try sbd.sb("parent", kid.id, "--clear")
    let before = digest.contexts(sbd, m).count

    try digest.prompt(sbd, m, "what changed")

    let given = digest.contexts(sbd, m).dropFirst(before).joined(separator: "\n")
    #expect(given.contains("kept (\(kept.id))"), "the digest left out the linked child: \(given)")
    #expect(!given.contains(kid.id), "\(given)")
  }

  // MARK: Moving

  @Test func parentMovesASessionToAnotherParent() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")

    try sbd.sb("parent", kid.id, other.id)

    let actual8 = try sbd.get(kid.id).parent
    #expect(actual8 == other.id)
  }

  @Test func aMoveRecordsUnlinkedAndLinkedOnEachEnd() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")

    try sbd.sb("parent", kid.id, other.id)

    let onKid = try linkEvents(sbd, kid.id)
    #expect(onKid.map(\.kind) == ["unlinked", "linked"])
    #expect(onKid.map { $0.data["parent"]?.string } == [parent.id, other.id])
    let actual9 = try linkEvents(sbd, parent.id).map(\.kind)
    #expect(actual9 == ["unlinked"])
    let actual10 = try linkEvents(sbd, other.id).map(\.kind)
    #expect(actual10 == ["linked"])
    let actual11 = try linkEvents(sbd, other.id).first?.data["child"]?.string
    #expect(actual11 == kid.id)
  }

  @Test func relinkingToTheOldParentRestoresIt() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")
    try sbd.sb("parent", kid.id, other.id)

    try sbd.sb("parent", kid.id, parent.id)

    let actual12 = try sbd.get(kid.id).parent
    #expect(actual12 == parent.id)
    let onKid = try linkEvents(sbd, kid.id)
    #expect(onKid.map(\.kind) == ["unlinked", "linked", "unlinked", "linked"])
    #expect(onKid.map { $0.data["parent"]?.string } == [parent.id, other.id, other.id, parent.id])
  }

  @Test func relinkingAfterAClearRestoresTheParent() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    try sbd.sb("parent", kid.id, "--clear")

    try sbd.sb("parent", kid.id, parent.id)

    let actual13 = try sbd.get(kid.id).parent
    #expect(actual13 == parent.id)
    let actual14 = try linkEvents(sbd, kid.id).map(\.kind)
    #expect(actual14 == ["unlinked", "linked"])
  }

  // MARK: Refusals

  @Test func parentRefusesItsOwnSession() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    let r = try sbd.run(["parent", kid.id, "--clear"], env: inside(kid.id))

    #expect(r.status != 0, "\(text(r))")
    #expect(r.stderr.contains("kid can't change its own parent"), "\(text(r))")
    let actual15 = try sbd.get(kid.id).parent
    #expect(actual15 == parent.id)
    let check16 = try sbd.events(kid.id, kind: "unlinked").isEmpty
    #expect(check16)
  }

  /// The positive control for the refusal above: the parent's claude may unlink its child.
  @Test func theParentsClaudeCanUnlinkItsChild() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    try sbd.sb(["parent", kid.id, "--clear"], env: inside(parent.id))

    let actual17 = try sbd.get(kid.id).parent
    #expect(actual17 == nil)
  }

  @Test func parentRefusesACycle() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    let r = try sbd.run("parent", parent.id, kid.id)

    #expect(r.status != 0, "\(text(r))")
    #expect(r.stderr.contains("kid is already under p"), "\(text(r))")
    let actual18 = try sbd.get(parent.id).parent
    #expect(actual18 == nil)
    let check19 = try linkEvents(sbd, parent.id).isEmpty
    #expect(check19)
  }

  @Test func parentClearOfASessionWithNoParentFails() throws {
    let sbd = try Instance()
    let (parent, _) = try parentAndChild(sbd)

    let r = try sbd.run("parent", parent.id, "--clear")

    #expect(r.status != 0, "\(text(r))")
    #expect(r.stderr.contains("p has no parent"), "\(text(r))")
  }

  @Test func parentRefusesAFollowup() throws {
    let sbd = try Instance()
    let parent = try idle(sbd, name: "p")
    let followup = try decode(
      SessionSummary.self,
      sbd.sb("followup", "add", "--json", "--repo", "o/r", "--parent", parent.id, "look at the cache"))
    try #require(followup.parent == parent.id, "the setup gave the follow-up no parent")

    let r = try sbd.run("parent", followup.id, "--clear")

    #expect(r.status != 0, "\(text(r))")
    #expect(r.stderr.contains("is a follow-up, and its parent is the session that captured it"), "\(text(r))")
  }

  // MARK: Show

  @Test func parentShowPrintsTheParent() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    let shown = try sbd.sb("parent", kid.id)

    #expect(shown.trimmingCharacters(in: .newlines) == "kid (\(kid.id)): parent p (\(parent.id))")
  }

  @Test func parentShowPrintsThatASessionHasNoParent() throws {
    let sbd = try Instance()
    let (parent, _) = try parentAndChild(sbd)

    let shown = try sbd.sb("parent", parent.id)

    #expect(shown.trimmingCharacters(in: .newlines) == "p (\(parent.id)) has no parent")
  }

  @Test func parentShowJSONPrintsTheGetSummary() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)

    let got = try #require(JSON.parse(try sbd.sb("parent", kid.id, "--json")))

    #expect(got["id"]?.string == kid.id)
    #expect(got["parent"]?.string == parent.id)
  }

  @Test func parentSetPrintsTheSameLineAsTheShowForm() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")

    let printed = try sbd.sb("parent", kid.id, other.id)

    #expect(printed.trimmingCharacters(in: .newlines) == "kid (\(kid.id)): parent other (\(other.id))")
  }

  @Test func parentClearPrintsThatTheSessionHasNoParent() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)

    let printed = try sbd.sb("parent", kid.id, "--clear")

    #expect(printed.trimmingCharacters(in: .newlines) == "kid (\(kid.id)) has no parent")
  }

  // MARK: MCP set_parent

  @Test func theManagerUnlinksASessionWithSetParentAsClaude() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("set_parent", ["session": .string(kid.id), "clear": true])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["id"]?.string == kid.id, "\(result.text)")
    #expect(result.json?["parent"] == nil, "\(result.text)")
    let actual20 = try sbd.get(kid.id).parent
    #expect(actual20 == nil)
    let actual21 = try sbd.events(kid.id, kind: "unlinked").first?.data["by"]
    #expect(actual21 == "claude")
  }

  @Test func theManagerMovesASessionWithSetParent() throws {
    let sbd = try Instance()
    let (_, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call("set_parent", ["session": .string(kid.id), "parent": .string(other.name)])

    #expect(!result.isError, "\(result.text)")
    let actual22 = try sbd.get(kid.id).parent
    #expect(actual22 == other.id)
  }

  /// An empty `parent` still counts as a parent, so it doesn't turn the request into a plain clear.
  @Test(arguments: [false, true])
  func setParentWithBothAParentAndClearIsRefused(emptyParent: Bool) throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    let other = try idle(sbd, name: "other")
    let mcp = try MCPClient(sbd, env: inside(try managerID(sbd)))

    let result = try mcp.call(
      "set_parent", ["session": .string(kid.id), "parent": .string(emptyParent ? "" : other.name), "clear": true])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("not both"), "\(result.text)")
    let actual23 = try sbd.get(kid.id).parent
    #expect(actual23 == parent.id)
  }

  @Test func aSessionCantChangeItsOwnParentThroughMCP() throws {
    let sbd = try Instance()
    let (parent, kid) = try parentAndChild(sbd)
    let mcp = try MCPClient(sbd, env: inside(kid.id))

    let result = try mcp.call("set_parent", ["session": .string(kid.id), "clear": true])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("can't change its own parent"), "\(result.text)")
    let actual24 = try sbd.get(kid.id).parent
    #expect(actual24 == parent.id)
  }

  // MARK: A server scoped to group Flags

  @Test(arguments: Outsider.allCases)
  func aScopedServerRefusesToUnlinkASessionOutsideItsGroup(_ who: Outsider) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let target = who.session(s)
    // A parent, so that only the scope can refuse the clear.
    try sbd.sb("parent", target.id, s.member.id)
    let mcp = try scopedClient(sbd, s, chat: try sbd.chatOf("Flags"))

    let result = try mcp.call("set_parent", ["session": .string(target.id), "clear": true])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not in group"), "\(result.text)")
    let actual25 = try sbd.get(target.id).parent
    #expect(actual25 == s.member.id)
  }

  @Test(arguments: Outsider.allCases)
  func aScopedServerRefusesToMoveAMemberUnderASessionOutsideItsGroup(_ who: Outsider) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try scopedClient(sbd, s, chat: try sbd.chatOf("Flags"))

    let result = try mcp.call("set_parent", ["session": .string(s.member.id), "parent": .string(who.session(s).id)])

    #expect(result.isError, "\(result.text)")
    #expect(result.text.contains("is not in group"), "\(result.text)")
    let actual26 = try sbd.get(s.member.id).parent
    #expect(actual26 == nil)
  }

  /// The positive control: a scoped server unlinks a member of its group.
  @Test func aScopedServerUnlinksAMember() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    try sbd.sb("parent", s.member.id, s.loose.id)
    let mcp = try scopedClient(sbd, s, chat: try sbd.chatOf("Flags"))

    let result = try mcp.call("set_parent", ["session": .string(s.member.id), "clear": true])

    #expect(!result.isError, "\(result.text)")
    let actual27 = try sbd.get(s.member.id).parent
    #expect(actual27 == nil)
  }

  // MARK: sbd's own check of the scope

  /// The MCP server resolves refs in its own scope first, so only a direct request reaches sbd's check.
  @Test func sbdRefusesAScopedClearOfASessionOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let chat = try sbd.chatOf("Flags")
    try sbd.sb("parent", s.outside.id, s.member.id)

    let error = failure(
      sbd, "parent",
      [
        "session": .string(s.outside.id), "clear": true, "by": "claude", "scope": .string(s.group.id),
        "caller": .string(chat),
      ])

    #expect(error.contains("is not in group"), "\(error)")
    let actual28 = try sbd.get(s.outside.id).parent
    #expect(actual28 == s.member.id)
  }

  @Test func sbdRefusesAScopedMoveUnderASessionOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let chat = try sbd.chatOf("Flags")

    let error = failure(
      sbd, "parent",
      [
        "session": .string(s.member.id), "parent": .string(s.outside.id), "by": "claude",
        "scope": .string(s.group.id), "caller": .string(chat),
      ])

    #expect(error.contains("is not in group"), "\(error)")
    let actual29 = try sbd.get(s.member.id).parent
    #expect(actual29 == nil)
  }
}
