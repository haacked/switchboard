import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPScopedToolTests: MCPToolServerSuite {
  @Test func aScopedToolsListLeavesOutTheToolsThatSpanGroups() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let names = try mcp.toolNames()

    #expect(names.count == 15)
    #expect(Set(names) == MCPToolServerTests.allTools.subtracting(MCPToolServerTests.unscopedOnly))
  }

  /// The tools that a scope leaves out, with arguments that would succeed without one.
  enum GroupWideTool: String, CaseIterable {
    case addGroup = "add_group"
    case removeGroup = "remove_group"
    case suggestGroups = "suggest_groups"

    func args(_ s: Scope) -> [String: JSON] {
      switch self {
      case .addGroup: ["name": "Fresh", "sessions": [.string(s.member.id)]]
      case .removeGroup: ["group": .string(s.group.id)]
      case .suggestGroups: [:]
      }
    }
  }

  @Test(arguments: GroupWideTool.allCases) func aScopedServerRefusesAToolThatSpansGroups(_ tool: GroupWideTool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let before = try groupList(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(tool.rawValue, tool.args(s))

    #expect(result.isError)
    #expect(try groupList(sbd) == before)
  }

  @Test func aScopedSpawnLandsInTheGroupEvenWhenTheCallerIsInAnother() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(kid.parent == s.outside.id)
    #expect(try sbd.get(kid.id).group == s.group.id)
  }

  @Test func aScopedSpawnWithoutACallerLandsInTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let kid = try mcp.call("spawn", try spawnArgs(sbd, "kid")).decode(SessionSummary.self)

    #expect(try sbd.get(kid.id).group == s.group.id)
  }

  @Test func aSpawnThatNamesAnUnknownGroupMakesNoWorktree() throws {
    let sbd = try Instance()
    var args = try spawnArgs(sbd, "kid")
    args["group"] = "nosuch"
    let repo = try #require(args["repository"]?.string)

    #expect(throws: (any Error).self) { try sbd.client.call("spawn", args) }

    #expect(try sbd.client.sessions().isEmpty)
    #expect(try sbd.git(repo, "branch", "--list", "kid").isEmpty)
    #expect(try sbd.git(repo, "worktree", "list").split(separator: "\n").count == 1)
  }

  @Test func aScopedFollowupSpawnLandsInTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))
    // A follow-up keeps the repo's owner/name, so the repo needs a github.com remote.
    let repo = try Repos.create("\(sbd.home.path)/widgets", origin: "https://github.com/acme/widgets.git")
    let args: [String: JSON] = [
      "repository": .string(repo), "branch": "later", "prompt": "Clean up.", "followup": true,
    ]

    let later = try mcp.call("spawn", args).decode(SessionSummary.self)

    #expect(later.state == AttentionState.notStarted)
    #expect(later.parent == s.outside.id)
    #expect(try sbd.client.call("get", ["session": .string(later.id)], as: SessionSummary.self).group == s.group.id)
  }

  @Test func aScopedListGroupsReturnsOnlyTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [s.group.id])
    #expect(!groups.ungrouped.contains(s.loose.id))
    #expect(!groups.ungrouped.contains(s.outside.id))
  }

  @Test func aScopedSendGroupDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))

    let pending = try mcp.call("send_group", ["text": "Rebase on main."]).decode(GroupSend.self)

    #expect(pending.group == s.group.id)
    #expect(pending.targets.map(\.id) == [s.member.id])
    #expect(pending.pending != nil)
    #expect(!pending.sent)
    #expect(try sent(sbd, s.member.id).isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test(arguments: [false, true]) func aScopedSendGroupRefusesAnotherGroup(withTargets: Bool) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))
    var args: [String: JSON] = ["group": .string(s.other.name), "text": "Rebase on main."]
    if withTargets { args["targets"] = [.string(s.outside.id)] }

    let result = try mcp.call("send_group", args)

    #expect(result.isError)
    #expect(try sbd.cards().isEmpty)
    #expect(try sent(sbd, s.outside.id).isEmpty)
  }

  @Test func aScopedSendGroupRefusesToReadAnotherGroupsMessage() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let card = try openPending(
      MCPClient(sbd, env: inside(s.loose.id)), ["group": .string(s.other.name), "text": "Rebase on main."])
    let scoped = try MCPClient(sbd, group: s.group.id, env: inside(s.loose.id))

    let result = try scoped.call("send_group", ["pending": .number(Double(card)), "timeout": 0])

    #expect(result.isError)
    #expect(result.json?["targets"] == nil)
  }

  @Test func aScopedAddGroupNoteDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let noted = try mcp.call("add_group_note", ["text": "Ask Ana first."]).decode(GroupSummary.self)

    #expect(noted.id == s.group.id)
    #expect(noted.notes.map(\.text) == ["Ask Ana first."])
  }

  @Test(arguments: Naming.allCases) func aScopedAddGroupNoteRefusesAnotherGroup(_ how: Naming) throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "add_group_note", ["group": .string(name(s.other.id, s.other.name, how)), "text": "Ask Ana first."])

    #expect(result.isError)
    #expect(try groupList(sbd).groups.first { $0.id == s.other.id }?.notes.isEmpty == true)
  }

  @Test func aScopedSetWaitWithoutASessionWaitsOnACallerOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id, env: inside(s.outside.id))

    let waiting = try mcp.call("set_wait", ["note": "CI on #12"]).decode(SessionSummary.self)

    #expect(waiting.id == s.outside.id)
    #expect(try sbd.get(s.outside.id).waits.map(\.by) == [.claude])
  }

  @Test func aScopedSetWaitRefusesATargetOutsideTheGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call(
      "set_wait", ["session": .string(s.member.id), "kind": "session", "target": .string(s.outside.name)])

    #expect(result.isError)
    #expect(result.text.contains("is not in group"))
    #expect(try sbd.get(s.member.id).waits.isEmpty)
  }

  @Test func aScopedSetWaitWaitsOnAMemberTargetNamedByName() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let peer = try sbd.new(name: "peer")
    try sbd.sb("group", "move", peer.id, "--to", s.group.id)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("set_wait", ["session": .string(s.member.id), "kind": "session", "target": "peer"])

    #expect(!result.isError)
    #expect(try sbd.get(s.member.id).waits.compactMap(\.session?.id) == [peer.id])
  }
}
