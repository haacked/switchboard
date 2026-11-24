import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPScopedToolTests: MCPToolServerSuite {
  @Test func aScopedToolsListLeavesOutTheToolsThatSpanGroups() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let names = try mcp.toolNames()

    let expected = MCPToolServerTests.allTools.subtracting(MCPToolServerTests.unscopedOnly)
      .subtracting(MCPToolServerTests.managerOnly)
    #expect(names.count == expected.count)
    #expect(Set(names) == expected)
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

  // MARK: Artifacts

  /// A scoped server's `list_groups` carries its group's artifacts and no other group's.
  @Test func aScopedListGroupsCarriesOnlyTheScopesArtifacts() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let outsidePage = "https://claude.ai/artifact/OutsidePage"
    try sbd.postArtifactHook(s.member.id)
    try sbd.postArtifactHook(
      s.outside.id, input: ["file_path": "/tmp/outside.html"],
      response: Instance.artifactResponse(
        url: outsidePage, artifactId: "55555555-1111-2222-3333-444444444444", title: "Outside"))
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("list_groups")

    let groups = try #require(result.json?["groups"]?.array)
    #expect(groups.compactMap { $0["id"]?.string } == [s.group.id])
    #expect(groups.first?["artifacts"]?.array?.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(!result.text.contains(outsidePage))
  }

  // MARK: Group artifact links

  @Test func aScopedAddGroupArtifactDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("add_group_artifact", ["url": .string("\(artifactPageURL)#top")])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["id"]?.string == s.group.id)
    let links = result.json?["links"]?.array ?? []
    #expect(links.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(links.compactMap { $0["by"]?.string } == ["claude"])
    #expect(result.json?["artifacts"]?.array?.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(try sbd.groupLinks(s.other.id).isEmpty)
  }

  @Test func aScopedAddGroupArtifactRefusesAnotherGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let mcp = try MCPClient(sbd, group: s.group.id)

    for how in Naming.allCases {
      let result = try mcp.call(
        "add_group_artifact", ["group": .string(name(s.other.id, s.other.name, how)), "url": .string(artifactPageURL)])
      #expect(result.isError, "\(how)")
    }

    #expect(try sbd.groupLinks(s.other.id).isEmpty)
    #expect(try sbd.groupLinks(s.group.id).isEmpty)
  }

  @Test func aScopedRemoveGroupArtifactDefaultsToTheScopesGroup() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let id = try sbd.addGroupLink(group: s.group.id, url: artifactPageURL, by: .claude)
    let mcp = try MCPClient(sbd, group: s.group.id)

    let result = try mcp.call("remove_group_artifact", ["link": .string(id)])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["id"]?.string == s.group.id)
    let links = result.json?["links"]?.array ?? []
    #expect(links.isEmpty)
  }

  /// Without `group`, the scope's group is the one asked, and it has no link with another group's id.
  @Test func aScopedRemoveGroupArtifactRefusesAnotherGroupsLink() throws {
    let sbd = try Instance()
    let s = try scope(sbd)
    let theirs = try sbd.addGroupLink(group: s.other.id, url: artifactPageURL, by: .claude)
    let mcp = try MCPClient(sbd, group: s.group.id)

    for how in Naming.allCases {
      let result = try mcp.call(
        "remove_group_artifact", ["group": .string(name(s.other.id, s.other.name, how)), "link": .string(theirs)])
      #expect(result.isError, "\(how)")
    }
    let unnamed = try mcp.call("remove_group_artifact", ["link": .string(theirs)])

    #expect(unnamed.isError)
    #expect(try sbd.groupLinks(s.other.id).map(\.id) == [theirs])
  }
}
