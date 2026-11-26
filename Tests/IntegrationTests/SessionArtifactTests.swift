import Foundation
import SwitchboardCore
import Testing

/// The short link of a first publish, and the `artifact_id` that its `/code/artifact/<uuid>` link names.
let artifactPageId = "AbCdEfGhIjKlMnOpQrStUv"
let artifactPageURL = "https://claude.ai/artifact/\(artifactPageId)"
let artifactPageUUID = "00000000-1111-2222-3333-444444444444"
let artifactPageCodeURL = "https://claude.ai/code/artifact/\(artifactPageUUID)"
private let scratchPage = "/private/tmp/claude-501/project/session/scratchpad/report.html"

extension Instance {
  /// The input of a first publish, as Claude Code's Artifact tool sends it.
  static let artifactFirstInput: JSON = [
    "file_path": .string(scratchPage), "icon": "chart", "description": "How the delta rates chart is built.",
  ]

  /// The `tool_response` of a publish, in the shape that Claude Code's Artifact tool returns.
  static func artifactResponse(
    url: String = artifactPageURL, artifactId: String = artifactPageUUID, title: String = "Delta Rates",
    republish: Bool = false
  ) -> JSON {
    [
      "url": .string(url), "path": .string(scratchPage), "artifact_id": .string(artifactId), "title": .string(title),
      "updated": .bool(republish), "owned": true, "icon": "chart", "audience": "owner", "seq": republish ? 2 : 1,
      "version": "1794536181-a91c", "contract": "0.0.0", "liveSubscription": "arming",
    ]
  }

  /// The payload of an Artifact hook of the session's claude. A nil response leaves `tool_response` out.
  static func artifactPayload(
    kind: String = "PostToolUse", claudeSessionId: String, input: JSON = artifactFirstInput,
    response: JSON? = artifactResponse(), agent: String? = nil, toolUseId: String
  ) -> JSON {
    var payload: [String: JSON] = [
      "hook_event_name": .string(kind), "session_id": .string(claudeSessionId), "tool_name": "Artifact",
      "tool_use_id": .string(toolUseId), "tool_input": input, "permission_mode": "default", "cwd": "/tmp",
      "duration_ms": 812,
    ]
    if let response { payload["tool_response"] = response }
    if let agent { payload["agent_id"] = .string(agent) }
    return .object(payload)
  }

  /// Sends an Artifact hook for the session, as `sb hook` does for a local claude, and returns the time that sbd
  /// recorded for it. sbd folds the hook before it answers.
  @discardableResult
  func postArtifactHook(
    _ id: String, kind: String = "PostToolUse", input: JSON = artifactFirstInput,
    response: JSON? = artifactResponse(), agent: String? = nil
  ) throws -> Int64 {
    let claudeSessionId = try get(id).claudeSessionId
    let toolUseId = "toolu_\(UUID().uuidString)"
    _ = try client.call(
      "hook",
      [
        "session": .string(id),
        "payload": Instance.artifactPayload(
          kind: kind, claudeSessionId: claudeSessionId, input: input, response: response, agent: agent,
          toolUseId: toolUseId),
      ])
    let event = try #require(try events(id).last { $0.data["tool_use_id"]?.string == toolUseId })
    return event.t
  }

  /// The `artifacts` of `sb get --json`, or nil when the key is missing.
  func sessionArtifacts(_ id: String) throws -> [JSON]? { try summaryJSON(id)["artifacts"]?.array }

  /// The group's entry in `sb group ls --json`, or nil when the list does not have it.
  func groupEntry(_ id: String) throws -> JSON? {
    try #require(JSON.parse(try sb("group", "ls", "--json")))["groups"]?.array?.first { $0["id"]?.string == id }
  }

  /// The `artifacts` of the group's entry in `sb group ls --json`, or nil when the key is missing.
  func groupArtifacts(_ id: String) throws -> [JSON]? { try groupEntry(id)?["artifacts"]?.array }

  /// The id of the group that `sb group add` creates with the sessions.
  func addArtifactGroup(_ name: String, _ sessions: String...) throws -> String {
    try #require(JSON.parse(try sb(["group", "add", "--json", name] + sessions))?["id"]?.string)
  }

  /// Adds a link to the group with a raw `group-link-add` as `by`, and returns the new link's id.
  @discardableResult
  func addGroupLink(group: String, url: String, by author: Author = .you) throws -> String {
    let added = try client.call(
      "group-link-add", ["group": .string(group), "url": .string(url), "by": .string(author.rawValue)])
    return try #require(added["links"]?.array?.last?["id"]?.string)
  }

  /// The group's links in `sb group ls --json`.
  func groupLinks(_ id: String) throws -> [ExternalLink] {
    let list = try JSONCoding.decode(GroupList.self, from: sb("group", "ls", "--json"))
    return list.groups.first { $0.id == id }?.links ?? []
  }
}

/// The JSON of every group row in sbd's database, read with sqlite3 after sbd stopped.
private func storedGroupsJSON(_ sbd: Instance) throws -> String {
  let r = try sbd.sqlite("SELECT json FROM groups")
  try #require(r.status == 0, Comment(rawValue: r.stderr))
  return r.stdout
}

/// sbd records the artifacts that a session publishes with Claude Code's Artifact tool, lists them in `sb get`,
/// `sb ls`, and `sb group ls`, keeps a removed member's rows on its group, and keeps them across a restart.

@Suite(.blocking(timeLimit: .seconds(120))) struct SessionArtifactTests {
  // MARK: A session's list

  @Test func aSessionWithoutArtifactsHasNoArtifactsKey() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    #expect(try sbd.sessionArtifacts(s.id) == nil)
  }

  @Test func aPublishShowsInSbGetJson() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    let t = try sbd.postArtifactHook(s.id)

    let rows = try #require(try sbd.sessionArtifacts(s.id))
    #expect(rows.count == 1)
    #expect(rows.first?["url"]?.string == artifactPageURL)
    #expect(rows.first?["artifactId"]?.string == artifactPageUUID)
    #expect(rows.first?["title"]?.string == "Delta Rates")
    #expect(rows.first?["published"]?.int.map(Int64.init) == t)
    #expect(rows.first?["updated"]?.int.map(Int64.init) == t)
    #expect(rows.first?["removed"] == nil)
  }

  @Test func aPublishShowsInSbLsJson() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")

    try sbd.postArtifactHook(s.id)

    let rows = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)
    let mine = try #require(rows.first { $0["id"]?.string == s.id })
    let theirs = try #require(rows.first { $0["id"]?.string == other.id })
    #expect(mine["artifacts"]?.array?.compactMap { $0["url"]?.string } == [artifactPageURL])
    #expect(theirs["artifacts"] == nil)
  }

  @Test func aRepublishUpdatesTheOneEntry() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let first = try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)

    let second = try sbd.postArtifactHook(
      s.id, input: ["file_path": .string(scratchPage), "url": .string(artifactPageURL)],
      response: Instance.artifactResponse(title: "Delta Rates v2", republish: true))

    let rows = try #require(try sbd.sessionArtifacts(s.id))
    #expect(second > first)
    #expect(rows.count == 1)
    #expect(rows.first?["title"]?.string == "Delta Rates v2")
    #expect(rows.first?["published"]?.int.map(Int64.init) == first)
    #expect(rows.first?["updated"]?.int.map(Int64.init) == second)
  }

  /// A call that published nothing: a read, an open, an asset upload, and a failed publish.
  enum NotAPublish: String, CaseIterable {
    case read, open, asset, failure

    var kind: String { self == .failure ? "PostToolUseFailure" : "PostToolUse" }

    var input: JSON {
      switch self {
      case .read: ["action": "read", "url": .string(artifactPageURL)]
      case .open: ["action": "open", "url": .string(artifactPageURL)]
      case .asset: ["asset": true, "url": .string(artifactPageURL), "file_path": "/tmp/chart.png"]
      case .failure: Instance.artifactFirstInput
      }
    }

    var response: JSON {
      switch self {
      case .read:
        ["read": ["url": .string(artifactPageURL), "title": "Delta Rates", "bytes": 4096], "artifactRead": true]
      case .open:
        [
          "url": .string(artifactPageURL), "title": "Delta Rates", "artifact_id": .string(artifactPageUUID),
          "opened": true, "owned": true,
        ]
      case .asset: Instance.artifactResponse()
      case .failure: "Error: publish refused"
      }
    }
  }

  @Test(arguments: NotAPublish.allCases)
  func aCallThatPublishedNothingAddsNothing(_ call: NotAPublish) throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    try sbd.postArtifactHook(s.id, kind: call.kind, input: call.input, response: call.response)

    #expect(try sbd.sessionArtifacts(s.id) == nil)
  }

  @Test func aSubagentsPublishCountsForTheSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")

    try sbd.postArtifactHook(s.id, agent: "a1b2c3d4e5")

    #expect(try sbd.sessionArtifacts(s.id)?.compactMap { $0["url"]?.string } == [artifactPageURL])
  }

  @Test(arguments: [artifactPageURL, artifactPageCodeURL])
  func aDeleteSetsRemovedAndKeepsTheEntry(_ link: String) throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)

    let t = try sbd.postArtifactHook(s.id, input: ["action": "delete", "url": .string(link)], response: nil)

    let rows = try #require(try sbd.sessionArtifacts(s.id))
    #expect(rows.count == 1)
    #expect(rows.first?["removed"]?.int.map(Int64.init) == t)
  }

  @Test func aDeleteOfAnAssetLeavesTheEntry() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id)

    try sbd.postArtifactHook(
      s.id, input: ["action": "delete", "url": .string(artifactPageURL), "path": "0123456789abcdef0123456789abcdef"],
      response: nil)

    let rows = try #require(try sbd.sessionArtifacts(s.id))
    #expect(rows.count == 1)
    #expect(rows.first?["removed"] == nil)
  }

  @Test func sbGetPrintsALinePerArtifact() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id)

    let text = try sbd.sb("get", s.id)

    let line = try #require(text.split(separator: "\n").map(String.init).first { $0.hasPrefix("  artifact: ") })
    #expect(line.hasPrefix("  artifact: Delta Rates  \(artifactPageURL)  (updated "), "\(line)")
    #expect(line.hasSuffix(" ago)"), "\(line)")
  }

  @Test func sbGetPrintsARemovedArtifactAsRemoved() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id)
    try sbd.postArtifactHook(s.id, input: ["action": "delete", "url": .string(artifactPageURL)], response: nil)

    let text = try sbd.sb("get", s.id)

    let line = try #require(text.split(separator: "\n").map(String.init).first { $0.hasPrefix("  artifact: ") })
    #expect(line.hasPrefix("  artifact: Delta Rates  \(artifactPageURL)  (removed "), "\(line)")
  }

  /// The title comes from the tool result, which the model influenced. The text output prints it on one line.
  @Test func sbGetPrintsATitleWithControlCharactersOnOneLine() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id, response: Instance.artifactResponse(title: "Delta\nRates\u{1B}[31m"))

    let text = try sbd.sb("get", s.id)

    #expect(!text.contains("\u{1B}"))
    #expect(text.split(separator: "\n").filter { $0.contains(artifactPageURL) }.count == 1)
  }

  @Test func aSessionsArtifactsSurviveARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)
    try sbd.postArtifactHook(s.id, input: ["action": "delete", "url": .string(artifactPageURL)], response: nil)
    let before = try #require(try sbd.sessionArtifacts(s.id))

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.sessionArtifacts(s.id) == before)
  }

  // MARK: A group's list

  @Test func aGroupListsItsMembersArtifactWithTheSessionsIdAndName() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)

    let t = try sbd.postArtifactHook(s.id)

    let rows = try #require(try sbd.groupArtifacts(g))
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row["url"]?.string == artifactPageURL)
    #expect(row["artifactId"]?.string == artifactPageUUID)
    #expect(row["title"]?.string == "Delta Rates")
    #expect(row["published"]?.int.map(Int64.init) == t)
    #expect(row["updated"]?.int.map(Int64.init) == t)
    #expect(row["session"]?.string == s.id)
    #expect(row["sessionName"]?.string == "flags-cache")
    #expect(row["removed"] == nil)
  }

  @Test func aGroupWithoutArtifactsHasNoArtifactsKey() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)

    #expect(try #require(try sbd.groupEntry(g))["artifacts"] == nil)
  }

  @Test func moveTakesTheArtifactToTheNewGroup() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let h = try sbd.addArtifactGroup("Billing")
    try sbd.postArtifactHook(s.id)

    try sbd.sb("group", "move", s.id, "--to", "Billing")

    #expect(try sbd.groupArtifacts(g) == nil)
    #expect(try sbd.groupArtifacts(h)?.compactMap { $0["session"]?.string } == [s.id])
  }

  /// A group chat publishes plan artifacts on Apply. They list on its group.
  @Test func aGroupChatsPublishListsOnItsGroup() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let chat = try #require(JSON.parse(try sbd.sb("chat", "Flags", "--json"))?["id"]?.string)

    try sbd.postArtifactHook(chat)

    let rows = try #require(try sbd.groupArtifacts(g))
    #expect(rows.compactMap { $0["session"]?.string } == [chat])
    #expect(rows.compactMap { $0["url"]?.string } == [artifactPageURL])
  }

  @Test func twoMembersThatPublishTheSameURLListOneRow() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try sbd.addArtifactGroup("Flags", a.id, b.id)
    try sbd.postArtifactHook(a.id)
    try sbd.advanceClock(60_000)

    try sbd.postArtifactHook(b.id, response: Instance.artifactResponse(title: "Delta Rates v2", republish: true))

    let rows = try #require(try sbd.groupArtifacts(g))
    #expect(rows.count == 1)
    #expect(rows.first?["session"]?.string == b.id)
    #expect(rows.first?["title"]?.string == "Delta Rates v2")
  }

  // MARK: sb rm keeps the rows on the group

  @Test func afterSbRmTheRowStaysOnTheGroupWithTheSameFields() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let other = try sbd.new(name: "other")
    let g = try sbd.addArtifactGroup("Flags", s.id, other.id)
    try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)
    try sbd.postArtifactHook(
      other.id, input: ["file_path": "/tmp/other.html"],
      response: Instance.artifactResponse(
        url: "https://claude.ai/artifact/OtherPage", artifactId: "55555555-1111-2222-3333-444444444444",
        title: "Other"))
    let before = try #require(try sbd.groupArtifacts(g))

    try sbd.sb("rm", s.id)

    #expect(try sbd.groupArtifacts(g) == before)
    #expect(before.count == 2)
  }

  @Test func theKeptRowSurvivesARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    let before = try #require(try sbd.groupArtifacts(g))
    try sbd.sb("rm", s.id)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.groupArtifacts(g) == before)
  }

  @Test func aRemovedEntryIsKeptWithItsRemovedTime() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)
    let t = try sbd.postArtifactHook(s.id, input: ["action": "delete", "url": .string(artifactPageURL)], response: nil)
    let before = try #require(try sbd.groupArtifacts(g))

    try sbd.sb("rm", s.id)

    let after = try #require(try sbd.groupArtifacts(g))
    #expect(after == before)
    #expect(after.first?["removed"]?.int.map(Int64.init) == t)
  }

  /// The kept row and a live member's entry for the same URL list as one row, before and after the removal.
  @Test func aKeptRowAndALiveEntryForTheSameURLListAsOneRow() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    let g = try sbd.addArtifactGroup("Flags", a.id, b.id)
    try sbd.postArtifactHook(a.id)
    try sbd.advanceClock(60_000)
    try sbd.postArtifactHook(b.id, response: Instance.artifactResponse(republish: true))
    let before = try #require(try sbd.groupArtifacts(g))

    try sbd.sb("rm", a.id)

    #expect(before.count == 1)
    #expect(try sbd.groupArtifacts(g) == before)
  }

  /// A member that moved groups before its removal keeps its rows on the group it is in at the removal.
  @Test func aMemberThatMovedKeepsItsRowsOnItsCurrentGroup() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let h = try sbd.addArtifactGroup("Billing")
    try sbd.postArtifactHook(s.id)
    try sbd.sb("group", "move", s.id, "--to", "Billing")
    let before = try #require(try sbd.groupArtifacts(h))

    try sbd.sb("rm", s.id)

    #expect(try sbd.groupArtifacts(h) == before)
    #expect(try sbd.groupArtifacts(g) == nil)
  }

  @Test func aGroupChatsArtifactsStayOnItsGroupAfterItsRemoval() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let chat = try #require(JSON.parse(try sbd.sb("chat", "Flags", "--json"))?["id"]?.string)
    try sbd.postArtifactHook(chat)
    let before = try #require(try sbd.groupArtifacts(g))

    try sbd.sb("rm", chat)

    #expect(try sbd.groupArtifacts(g) == before)
  }

  @Test func sbGroupLsPrintsALinePerRowWithTheSessionsName() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    _ = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    try sbd.sb("rm", s.id)

    let text = try sbd.sb("group", "ls")

    #expect(text.contains("  artifact: Delta Rates  \(artifactPageURL)  by flags-cache\n"), "\(text)")
  }

  @Test func sbGroupLsMarksARemovedRow() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    _ = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    try sbd.postArtifactHook(s.id, input: ["action": "delete", "url": .string(artifactPageURL)], response: nil)

    let text = try sbd.sb("group", "ls")

    #expect(text.contains("  artifact: Delta Rates  \(artifactPageURL)  by flags-cache (removed)"), "\(text)")
  }

  // MARK: A session's artifact and a group link to it

  /// The fields that a merged row of a session's publish and a link must show: the session's title and name and
  /// the link's id.
  private func expectSessionRowWithLink(
    _ rows: [JSON], session: String, name: String, link: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(rows.count == 1, sourceLocation: sourceLocation)
    #expect(rows.first?["url"]?.string == artifactPageURL, sourceLocation: sourceLocation)
    #expect(rows.first?["title"]?.string == "Delta Rates", sourceLocation: sourceLocation)
    #expect(rows.first?["session"]?.string == session, sourceLocation: sourceLocation)
    #expect(rows.first?["sessionName"]?.string == name, sourceLocation: sourceLocation)
    #expect(rows.first?["link"]?.string == link, sourceLocation: sourceLocation)
  }

  /// The publish's URL differs in form from the link's. A short link has no `artifactId`, so the rows join only
  /// because the hook records the normalized URL.
  @Test func aPublishThenALinkListOneRowWithTheSessionsTitleAndTheLinksId() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(
      s.id, response: Instance.artifactResponse(url: "https://Claude.ai/artifact/\(artifactPageId)/"))
    try sbd.advanceClock(60_000)

    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageURL)

    expectSessionRowWithLink(try #require(try sbd.groupArtifacts(g)), session: s.id, name: "flags-cache", link: link)
    let text = try sbd.sb("group", "ls")
    #expect(text.contains("  artifact: Delta Rates  \(artifactPageURL)  by flags-cache, link \(link)\n"), "\(text)")
  }

  /// A link older than the first publish leaves `published` at the publish, not at the link's time.
  @Test func aLinkThenAPublishListOneRowPublishedAtThePublish() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageURL)
    try sbd.advanceClock(60_000)

    let t = try sbd.postArtifactHook(s.id)

    let rows = try #require(try sbd.groupArtifacts(g))
    expectSessionRowWithLink(rows, session: s.id, name: "flags-cache", link: link)
    #expect(rows.first?["published"]?.int.map(Int64.init) == t)
    #expect(rows.first?["updated"]?.int.map(Int64.init) == t)
  }

  @Test func aKeptRowAndALinkListOneRowWithTheSessionsTitleAndTheLinksId() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    try sbd.sb("rm", s.id)
    try sbd.advanceClock(60_000)

    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageURL)

    expectSessionRowWithLink(try #require(try sbd.groupArtifacts(g)), session: s.id, name: "flags-cache", link: link)
  }

  /// A link added after a delete leaves the row removed, and a republish after that clears `removed`.
  @Test func aLinkAddedAfterADeleteLeavesTheRowRemovedUntilARepublish() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    let published = try sbd.postArtifactHook(s.id)
    try sbd.advanceClock(60_000)
    let deleted = try sbd.postArtifactHook(
      s.id, input: ["action": "delete", "url": .string(artifactPageURL)], response: nil)
    try sbd.advanceClock(60_000)
    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageURL)

    let removedRows = try #require(try sbd.groupArtifacts(g))
    #expect(removedRows.count == 1)
    #expect(removedRows.first?["removed"]?.int.map(Int64.init) == deleted)
    #expect(removedRows.first?["updated"]?.int.map(Int64.init) == published)
    #expect(removedRows.first?["link"]?.string == link)

    try sbd.advanceClock(60_000)
    try sbd.postArtifactHook(s.id, response: Instance.artifactResponse(republish: true))

    let rows = try #require(try sbd.groupArtifacts(g))
    #expect(rows.count == 1)
    #expect(rows.first?["removed"] == nil)
    #expect(rows.first?["link"]?.string == link)
  }

  /// The `/code/artifact/<uuid>` link names the uuid that the publish's `artifact_id` holds.
  @Test func aLinkToTheCodeURLJoinsAPublishOfTheShortURL() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)

    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageCodeURL)

    expectSessionRowWithLink(try #require(try sbd.groupArtifacts(g)), session: s.id, name: "flags-cache", link: link)
  }

  @Test func rmOfTheLinkLeavesTheSessionRowWithoutLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let g = try sbd.addArtifactGroup("Flags", s.id)
    try sbd.postArtifactHook(s.id)
    let link = try sbd.addGroupLink(group: "Flags", url: artifactPageURL)
    try #require(try sbd.groupArtifacts(g)?.first?["link"]?.string == link)

    try sbd.sb("group", "link", "rm", "Flags", link)

    let rows = try #require(try sbd.groupArtifacts(g))
    #expect(rows.count == 1)
    #expect(rows.first?["session"]?.string == s.id)
    #expect(rows.first?["link"] == nil)
  }

  // MARK: Sessions in no group, and sb group rm

  @Test func sbRmOfAnUngroupedSessionSucceedsAndKeepsNoRow() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "flags-cache")
    let member = try sbd.new(name: "member")
    let g = try sbd.addArtifactGroup("Flags", member.id)
    try sbd.postArtifactHook(s.id)

    try sbd.sb("rm", s.id)

    #expect(try sbd.groupArtifacts(g) == nil)
    #expect(try !sbd.sb("group", "ls", "--json").contains(artifactPageURL))
    sbd.stopSbd()
    #expect(try !storedGroupsJSON(sbd).contains(artifactPageURL))
  }

  @Test func sbGroupRmDropsTheKeptRowsAndLeavesTheLiveMembersArtifacts() throws {
    let sbd = try Instance()
    let gone = try sbd.new(name: "gone")
    let live = try sbd.new(name: "live")
    let g = try sbd.addArtifactGroup("Flags", gone.id, live.id)
    try sbd.postArtifactHook(gone.id)
    try sbd.postArtifactHook(
      live.id, input: ["file_path": "/tmp/other.html"],
      response: Instance.artifactResponse(
        url: "https://claude.ai/artifact/OtherPage", artifactId: "55555555-1111-2222-3333-444444444444",
        title: "Other"))
    try sbd.sb("rm", gone.id)

    try sbd.sb("group", "rm", "Flags")

    #expect(try sbd.groupEntry(g) == nil)
    #expect(
      try sbd.sessionArtifacts(live.id)?.compactMap { $0["url"]?.string } == ["https://claude.ai/artifact/OtherPage"])
    _ = try sbd.addArtifactGroup("Flags", live.id)
    #expect(try !sbd.sb("group", "ls", "--json").contains(artifactPageURL))
    sbd.stopSbd()
    #expect(try !storedGroupsJSON(sbd).contains(g))
    #expect(try !storedGroupsJSON(sbd).contains(artifactPageURL))
  }
}

/// A session on a remote host records its artifacts from hooks that reach sbd through the box's shim, live or
/// from the spool after a reconnect.
@Suite(.blocking(timeLimit: .seconds(240))) struct RemoteSessionArtifactTests {
  private func payload(_ claudeSessionId: String) -> JSON {
    Instance.artifactPayload(claudeSessionId: claudeSessionId, toolUseId: "toolu_\(UUID().uuidString)")
  }

  private func urls(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.sessionArtifacts(id)?.compactMap { $0["url"]?.string } ?? []
  }

  private func kinds(_ sbd: Instance, _ id: String, after mark: Int64) throws -> [String] {
    try sbd.events(id).filter { $0.id > mark }.map(\.kind)
  }

  @Test func aPublishThroughTheBoxesShimWithTheLinkUpShowsInSbGet() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost()

    let run = try sbd.runBoxShim(session: s.id, payload: payload(s.claudeSessionId))

    #expect(run.status == 0)
    try sbd.waitFor("the host session's artifact") { try urls(sbd, s.id) == [artifactPageURL] }
  }

  @Test func aPublishThatWaitedInTheSpoolShowsAfterTheReconcile() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    _ = try sbd.settledEvents()
    let mark = try sbd.events(s.id).last?.id ?? 0
    try sbd.dropLinkAndRefuse("ssh: connect to host mini.local port 22: Operation timed out")
    try sbd.waitFor("the link_down of \(s.id)") { try kinds(sbd, s.id, after: mark).contains("link_down") }

    let run = try sbd.runBoxShim(session: s.id, payload: payload(s.claudeSessionId))

    #expect(run.status == 0)
    #expect(try urls(sbd, s.id).isEmpty, "sbd recorded a hook that could not reach it")
    try sbd.restoreLink()
    try sbd.waitFor("the link_up of \(s.id)", timeout: 45) { try kinds(sbd, s.id, after: mark).contains("link_up") }
    try sbd.waitFor("the spooled artifact") { try urls(sbd, s.id) == [artifactPageURL] }
  }
}
