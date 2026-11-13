import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPScopedSessionTests: MCPToolServerSuite {
  @Test(arguments: Naming.allCases) func aScopeNamesItsGroupByIdIdPrefixOrName(_ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: name(s.group.id, s.group.name, how))

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [s.group.id])
  }

  /// A scope that names no group, and one that names two.
  enum BadScope: CaseIterable { case unknown, sharedPrefix }

  @Test(arguments: BadScope.allCases) func aScopeThatNamesNoSingleGroupListsNoSessions(_ bad: BadScope) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let key = bad == .unknown ? "Nowhere" : s.group.id.commonPrefix(with: s.other.id)

    let result = try? MCPClient(sbd, group: key).call("list_sessions")

    #expect(result == nil || result?.isError == true)
  }

  @Test(arguments: Naming.allCases) func aScopedGetSessionRefusesAnOutsideSessionHoweverItIsNamed(_ how: Naming)
    throws
  {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("get_session", ["session": .string(name(s.outside.id, s.outside.name, how))])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
  }

  @Test func aScopedGetSessionRefusesAnUngroupedSession() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("get_session", ["session": .string(s.loose.id)])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
  }

  @Test func aScopedGetSessionReturnsAMember() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let got = try mcp.call("get_session", ["session": .string(s.member.name)]).decode(SessionSummary.self)

    #expect(got.id == s.member.id)
  }

  @Test func aScopedSendReachesAMemberNamedByName() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("send", ["session": .string(s.member.name), "text": "Rebase on main."])

    #expect(!result.isError)
    #expect(try sent(sbd, s.member.id) == ["Rebase on main."])
  }

  @Test func aScopedServerRefusesASessionThatLeftTheGroupAfterItStarted() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)
    try sbd.sb("group", "move", s.member.id, "--ungrouped")

    let result = try mcp.call("send", ["session": .string(s.member.id), "text": "hi"])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    #expect(try sent(sbd, s.member.id).isEmpty)
  }

  @Test func aScopedServerFailsOnceItsGroupIsRemoved() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)
    try sbd.sb("group", "rm", s.group.id)

    let result = try mcp.call("list_sessions")

    #expect(result.isError)
    #expect(result.text.contains("is gone"))
  }

  /// Each tool that names a session, with arguments that name `session`.
  enum SessionTool: String, CaseIterable {
    case getSession = "get_session"
    case readReply = "read_reply"
    case events
    case send
    case setWait = "set_wait"
    case clearWait = "clear_wait"
    case addNote = "add_note"
    case moveToGroup = "move_to_group"

    func args(_ session: String) -> [String: JSON] {
      switch self {
      case .getSession, .readReply, .events, .clearWait: ["session": .string(session)]
      case .send, .addNote: ["session": .string(session), "text": "Rebase on main."]
      case .setWait: ["session": .string(session), "note": "CI on #12"]
      case .moveToGroup: ["sessions": [.string(session)], "ungrouped": true]
      }
    }
  }

  @Test(arguments: SessionTool.allCases) func aScopedToolRefusesAnOutsideSessionAndLeavesItAlone(_ tool: SessionTool)
    throws
  {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(tool.rawValue, tool.args(s.outside.id))

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    let after = try sbd.get(s.outside.id)
    #expect(after.group == s.other.id)
    #expect(after.notes.isEmpty)
    #expect(after.waits.isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test func aScopedMoveRefusesAListThatHoldsAnOutsideSession() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "move_to_group", ["sessions": [.string(s.member.id), .string(s.outside.id)], "ungrouped": true])

    #expect(result.isError)
    #expect(try sbd.get(s.member.id).group == s.group.id)
    #expect(try sbd.get(s.outside.id).group == s.other.id)
  }

  @Test func aScopedMoveMovesAMemberToUngrouped() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let moved = try mcp.call("move_to_group", ["sessions": [.string(s.member.id)], "ungrouped": true]).decode(
      [SessionSummary].self)

    #expect(moved.map(\.group) == [nil])
    #expect(try sbd.get(s.member.id).group == nil)
  }

  @Test func aScopedMoveRefusesToMoveAMemberIntoAnotherGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("move_to_group", ["sessions": [.string(s.member.id)], "group": .string(s.other.id)])

    #expect(result.isError)
    #expect(try sbd.get(s.member.id).group == s.group.id)
  }

  @Test func aScopedListSessionsReturnsOnlyTheGroupsSessions() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let listed = try mcp.call("list_sessions").decode([SessionSummary].self)

    #expect(listed.map(\.id) == [s.member.id])
  }

  @Test func aScopedEventsReturnsOnlyTheGroupsEvents() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    try sbd.sb("send", s.member.id, "inside")
    try sbd.sb("send", s.outside.id, "outside")
    try sbd.sb("send", s.loose.id, "loose")
    let mcp = try MCPClient(sbd, group: s.group.id)

    let events = try mcp.call("events", ["since": 0, "limit": 10_000]).decode([Event].self)

    #expect(events.contains { $0.session == s.member.id && $0.kind == "sent" })
    #expect(events.allSatisfy { $0.session == s.member.id })
  }

  @Test func aScopedEventsMergesTheMembersAndKeepsTheOldestOrTheNewest() throws {
    let sbd = try Instance()
    // Idle sessions and notes, which sbd records before it answers, keep
    // events from arriving between the server's reads of each member.
    let first = try idle(sbd, name: "first")
    let second = try idle(sbd, name: "second")
    let outside = try idle(sbd, name: "outside")
    let group = try addGroup(sbd, "Flags", first.id, second.id)
    for text in ["one", "two"] {
      try sbd.sb("note", first.id, text)
      try sbd.sb("note", second.id, text)
    }
    try sbd.sb("note", outside.id, "outside")
    let mcp = try MCPClient(sbd, group: group.id)

    let all = try mcp.call("events", ["since": 0, "limit": 10_000]).decode([Event].self)
    let oldest = try mcp.call("events", ["since": 0, "limit": 2]).decode([Event].self)
    let newest = try mcp.call("events", ["limit": 2]).decode([Event].self)
    let groupIDs = try (sbd.events(first.id) + sbd.events(second.id)).map(\.id).sorted()

    #expect(Set(all.map(\.session)) == [first.id, second.id])
    #expect(all.map(\.id) == all.map(\.id).sorted())
    #expect(oldest.map(\.id) == Array(groupIDs.prefix(2)))
    #expect(newest.map(\.id) == Array(groupIDs.suffix(2)))
  }

  @Test(arguments: [false, true]) func aScopedEventsReadsANegativeLimitAsNoLimit(_ withSince: Bool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    try sbd.sb("send", s.member.id, "inside")
    let mcp = try MCPClient(sbd, group: s.group.id)
    var args: [String: JSON] = ["limit": -1]
    if withSince { args["since"] = 0 }

    let events = try mcp.call("events", args).decode([Event].self)

    #expect(events.contains { $0.session == s.member.id && $0.kind == "sent" })
  }

  @Test func aScopedTriageReturnsOnlyTheGroupsSessions() throws {
    let sbd = try Instance()
    let member = try idle(sbd, name: "member")
    let outside = try idle(sbd, name: "outside")
    let g = try addGroup(sbd, "Flags", member.id)
    _ = try sbd.waitFor("both in triage", fetch: { try triaged(sbd) }) { Set($0) == [member.id, outside.id] }
    let mcp = try MCPClient(sbd, group: g.id)

    let listed = try mcp.call("triage").decode([SessionSummary].self)

    #expect(listed.map(\.id) == [member.id])
  }
}
