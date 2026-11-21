import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct MCPGroupToolTests: MCPToolServerSuite {
  @Test func addGroupCreatesAGroupWithItsSessionsAndNote() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let mcp = try MCPClient(sbd)

    let g = try mcp.call(
      "add_group", ["name": "Flags", "sessions": [.string(a.id)], "note": "Ship by Friday"]
    ).decode(GroupSummary.self)

    #expect(g.name == "Flags")
    #expect(g.sessions == [a.id])
    #expect(g.notes.map(\.text) == ["Ship by Friday"])
    #expect(try sbd.get(a.id).group == g.id)
  }

  @Test func listGroupsReturnsTheGroupList() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let loose = try sbd.new(name: "loose")
    let g = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd)

    let groups = try mcp.call("list_groups").decode(GroupList.self)

    #expect(groups.groups.map(\.id) == [g.id])
    #expect(groups.ungrouped == [loose.id])
  }

  @Test func moveToGroupMovesSessionsInAndOut() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags")
    let mcp = try MCPClient(sbd)

    let moved = try mcp.call("move_to_group", ["sessions": [.string(a.id)], "group": "Flags"]).decode(
      [SessionSummary].self)
    let out = try mcp.call("move_to_group", ["sessions": [.string(a.id)], "ungrouped": true]).decode(
      [SessionSummary].self)

    #expect(moved.map(\.group) == [g.id])
    #expect(out.map(\.group) == [nil])
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func addGroupNoteAddsANoteToTheGroup() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let mcp = try MCPClient(sbd)

    let noted = try mcp.call("add_group_note", ["group": "Flags", "text": "Ask Ana first."]).decode(
      GroupSummary.self)

    #expect(noted.id == g.id)
    #expect(try groupList(sbd).groups.first?.notes.map(\.text) == ["Ask Ana first."])
  }

  @Test func removeGroupDeletesTheGroupAndLeavesItsMembersUngrouped() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd)

    let removed = try mcp.call("remove_group", ["group": "Flags"])

    #expect(!removed.isError)
    #expect(removed.json?["removed"]?.string == g.id)
    #expect(try groupList(sbd).groups.isEmpty)
    #expect(try sbd.get(a.id).group == nil)
  }

  @Test func suggestGroupsListsTheSuggestionsAndAcceptCreatesTheGroup() throws {
    let sbd = try Instance()
    let repo = try sbd.makeRepo()
    let a = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/flag-evaluations-cache"], as: SessionSummary.self)
    let b = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/flag-evaluations-perf"], as: SessionSummary.self)
    let mcp = try MCPClient(sbd)

    let found = try mcp.call("suggest_groups").decode([GroupSuggestion].self)
    let first = try #require(found.first)
    let accepted = try mcp.call("suggest_groups", ["accept": .string(first.id)]).decode(GroupSummary.self)

    #expect(Set(first.sessions) == [a.id, b.id])
    #expect(Set(accepted.sessions) == [a.id, b.id])
    #expect(try sbd.get(a.id).group == accepted.id)
  }

  // MARK: Descriptions and links

  @Test func addGroupWithADescriptionIsByClaude() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let g = try mcp.call("add_group", ["name": "Flags", "description": "Ship the cache."]).decode(GroupSummary.self)

    #expect(g.description == "Ship the cache.")
    #expect(g.descriptionBy == .claude)
    let listed = try #require(try groupList(sbd).groups.first { $0.id == g.id })
    #expect(listed.description == "Ship the cache.")
    #expect(listed.descriptionBy == .claude)
  }

  @Test func addGroupWithoutADescriptionHasNoAuthor() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let g = try mcp.call("add_group", ["name": "Flags"]).decode(GroupSummary.self)

    #expect(g.description == nil)
    #expect(g.descriptionBy == nil)
  }

  @Test func addGroupRefusesADescriptionOverTheLimitAndMakesNoGroup() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)
    let text = String(repeating: "a", count: SessionGroup.descriptionLimit + 1)

    let result = try mcp.call("add_group", ["name": "Flags", "description": .string(text)])

    #expect(result.isError)
    #expect(try groupList(sbd).groups.isEmpty)
  }

  /// The links and the description's author of Flags, which the user linked and Claude described.
  func linkedAndDescribed(_ sbd: Instance) throws -> GroupSummary {
    let s = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags", s.id)
    try sbd.sb("group", "link", "add", "Flags", "https://example.com/rfc", "--title", "RFC")
    try sbd.sb(["group", "describe", "Flags", "Ship the cache."], env: inside(s.id))
    return g
  }

  @Test func listGroupsCarriesTheLinksAndTheDescriptionsAuthor() throws {
    let sbd = try Instance()
    let g = try linkedAndDescribed(sbd)
    let mcp = try MCPClient(sbd)

    let groups = try mcp.call("list_groups").decode(GroupList.self).groups

    let flags = try #require(groups.first { $0.id == g.id })
    #expect(flags.links?.map(\.url) == ["https://example.com/rfc"])
    #expect(flags.links?.map(\.title) == ["RFC"])
    #expect(flags.descriptionBy == .claude)
  }

  @Test func aScopedListGroupsCarriesTheSameLinksAndAuthorAsAnUnscopedOne() throws {
    let sbd = try Instance()
    let g = try linkedAndDescribed(sbd)

    let unscoped = try MCPClient(sbd).call("list_groups").decode(GroupList.self).groups
    let scoped = try MCPClient(sbd, group: g.id).call("list_groups").decode(GroupList.self).groups

    let all = try #require(unscoped.first { $0.id == g.id })
    let one = try #require(scoped.first)
    #expect(one.links == all.links)
    #expect(one.descriptionBy == all.descriptionBy)
  }

  // MARK: send_group

  func answer(_ sbd: Instance, _ session: String, _ card: Int64, allow: Bool) throws {
    _ = try sbd.client.call(
      "answer",
      ["session": .string(session), "card": .number(Double(card)), "behavior": .string(allow ? "allow" : "deny")])
  }

  @Test func sendGroupOpensAPendingCardAndSendsNothing() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try addGroup(sbd, "Flags", a.id, b.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    let pending = try result.decode(GroupSend.self)
    #expect(pending.group == g.id)
    #expect(!pending.sent)
    #expect(pending.decision == .pending)
    #expect(Set(pending.targets.map(\.id)) == [a.id, b.id])
    #expect(Set(pending.targets.map(\.name)) == ["alpha", "bravo"])
    let card = try #require(pending.pending)
    #expect(try sbd.get(caller.id).cards.map(\.id) == [card])
    #expect(try sbd.get(caller.id).cards.map(\.kind) == [.send])
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, b.id).isEmpty)
  }

  @Test func sendGroupTellsClaudeHowToReadTheDecision() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    let instruction = try #require(result.json?["instruction"]?.string)
    #expect(instruction.contains("Switchboard"))
    #expect(instruction.contains("pending"))
  }

  @Test func sendGroupWithPendingReportsPendingBeforeADecision() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let card = try openPending(mcp)

    let result = try mcp.call("send_group", ["pending": .number(Double(card)), "timeout": 0]).decode(GroupSend.self)

    #expect(result.pending == card)
    #expect(result.decision == .pending)
    #expect(!result.sent)
  }

  @Test(arguments: [true, false]) func sendGroupWithPendingReportsTheDecisionAfterAnAnswer(allow: Bool) throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try addGroup(sbd, "Flags", a.id, b.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let card = try openPending(mcp)
    try answer(sbd, caller.id, card, allow: allow)

    let result = try mcp.call("send_group", ["pending": .number(Double(card)), "timeout": 0]).decode(GroupSend.self)

    #expect(result.decision == (allow ? .sent : .cancelled))
    #expect(result.sent == allow)
    #expect(Set((result.deliveries ?? []).map(\.session)) == (allow ? [a.id, b.id] : []))
    #expect(try sent(sbd, a.id) == (allow ? ["Rebase on main."] : []))
    #expect(try sent(sbd, b.id) == (allow ? ["Rebase on main."] : []))
  }

  /// The SB_SESSION_ID of a server that has no calling session.
  enum NoCaller: CaseIterable { case unset, empty, unknown }

  @Test(arguments: NoCaller.allCases) func sendGroupWithoutACallingSessionRefuses(_ caller: NoCaller) throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", a.id)
    let env: [String: String] =
      switch caller {
      case .unset: [:]
      case .empty: ["SB_SESSION_ID": "", "CLAUDECODE": "1"]
      case .unknown: inside("snope1")
      }
    let mcp = try MCPClient(sbd, env: env)

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."])

    #expect(result.isError)
    #expect(try sbd.cards().isEmpty)
    #expect(try sent(sbd, a.id).isEmpty)
  }

  /// The `targets` that the old confirmation step passed.
  enum OldTargets: CaseIterable { case listed, empty, withTheCaller }

  @Test(arguments: OldTargets.allCases) func sendGroupWithTargetsSendsNothing(_ shape: OldTargets) throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", caller.id, a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))
    let targets: [JSON] =
      switch shape {
      case .listed: [.string(a.id)]
      case .empty: []
      case .withTheCaller: [.string(caller.id), .string(a.id)]
      }

    let result = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main.", "targets": .array(targets)])

    #expect(result.isError || (try? result.decode(GroupSend.self))?.sent == false)
    #expect(try sent(sbd, a.id).isEmpty)
    #expect(try sent(sbd, caller.id).isEmpty)
  }

  @Test func sendGroupsSchemaTakesPendingAndNotTargets() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "send_group" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["pending"] != nil)
    #expect(properties["timeout"] != nil)
    #expect(properties["text"] != nil)
    #expect(properties["targets"] == nil)
  }

  @Test func sendGroupLeavesOutTheCaller() throws {
    let sbd = try Instance()
    let caller = try sbd.new(name: "caller")
    let a = try sbd.new(name: "alpha")
    _ = try addGroup(sbd, "Flags", caller.id, a.id)
    let mcp = try MCPClient(sbd, env: inside(caller.id))

    let pending = try mcp.call("send_group", ["group": "Flags", "text": "Rebase on main."]).decode(GroupSend.self)
    try answer(sbd, caller.id, try #require(pending.pending), allow: true)

    #expect(pending.targets.map(\.id) == [a.id])
    #expect(try sent(sbd, a.id) == ["Rebase on main."])
    #expect(try sent(sbd, caller.id).isEmpty)
  }

  // MARK: Artifacts

  @Test func listGroupsCarriesTheGroupsArtifacts() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags", a.id)
    try sbd.postArtifactHook(a.id)
    let mcp = try MCPClient(sbd)

    let groups = try #require(try mcp.call("list_groups").json?["groups"]?.array)

    let flags = try #require(groups.first { $0["id"]?.string == g.id })
    let row = try #require(flags["artifacts"]?.array?.first)
    #expect(row["url"]?.string == artifactPageURL)
    #expect(row["session"]?.string == a.id)
    #expect(row["sessionName"]?.string == "alpha")
  }

  @Test func listGroupsCarriesTheRowsOfARemovedMember() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let g = try addGroup(sbd, "Flags", a.id)
    try sbd.postArtifactHook(a.id)
    try sbd.sb("rm", a.id)
    let mcp = try MCPClient(sbd)

    let groups = try #require(try mcp.call("list_groups").json?["groups"]?.array)

    let flags = try #require(groups.first { $0["id"]?.string == g.id })
    #expect(flags["artifacts"]?.array?.compactMap { $0["session"]?.string } == [a.id])
  }

  // MARK: Group artifact links

  /// The tool takes no title, so a title that Claude passes never reaches the link.
  @Test func addGroupArtifactAddsAClaudeLinkTitledWithTheNormalizedURL() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let billing = try addGroup(sbd, "Billing")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call(
      "add_group_artifact", ["group": "Flags", "url": .string("\(artifactPageURL)#top"), "title": "Delta Rates"])

    #expect(!result.isError, "\(result.text)")
    #expect(result.json?["id"]?.string == g.id)
    let links = try #require(result.json?["links"]?.array)
    #expect(links.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(links.compactMap { $0["title"]?.string } == [artifactPageURL])
    #expect(links.compactMap { $0["by"]?.string } == ["claude"])
    let rows = result.json?["artifacts"]?.array ?? []
    #expect(rows.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(rows.compactMap { $0["link"]?.string } == links.compactMap { $0["id"]?.string })
    #expect(try sbd.groupLinks(billing.id).isEmpty)
  }

  @Test func addGroupArtifactOfALinkThatIsNotAnArtifactIsAnErrorAndAddsNothing() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("add_group_artifact", ["group": "Flags", "url": "https://example.com/rfc"])

    #expect(result.isError)
    #expect(try sbd.groupLinks(g.id).isEmpty)
  }

  @Test func removeGroupArtifactOfAClaudeLinkRemovesTheRow() throws {
    let sbd = try Instance()
    _ = try addGroup(sbd, "Flags")
    let id = try sbd.addGroupLink(group: "Flags", url: artifactPageURL, by: .claude)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("remove_group_artifact", ["group": "Flags", "link": .string(id)])

    #expect(!result.isError, "\(result.text)")
    let links = result.json?["links"]?.array ?? []
    #expect(links.isEmpty)
    #expect(result.json?["artifacts"] == nil)
  }

  @Test func removeGroupArtifactOfAUsersLinkIsAnErrorAndKeepsIt() throws {
    let sbd = try Instance()
    let g = try addGroup(sbd, "Flags")
    let ids = [
      try sbd.addGroupLink(group: "Flags", url: artifactPageURL),
      try sbd.addGroupLink(group: "Flags", url: "https://example.com/rfc"),
    ]
    let mcp = try MCPClient(sbd)

    for id in ids {
      let result = try mcp.call("remove_group_artifact", ["group": "Flags", "link": .string(id)])
      #expect(result.isError, "\(id)")
    }

    #expect(try sbd.groupLinks(g.id).map(\.id) == ids)
  }

  @Test func theListGroupsDescriptionNamesArtifacts() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "list_groups" })

    #expect(tool["description"]?.string?.contains("artifacts") == true, "\(tool["description"]?.string ?? "")")
  }
}
