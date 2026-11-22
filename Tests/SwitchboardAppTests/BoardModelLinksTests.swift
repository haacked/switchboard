import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000

private func session(_ id: String, links: [ExternalLink]) -> SessionSummary {
  var s = notedSession([], id: id)
  s.links = links
  return s
}

/// Test arguments are read outside the main actor, so the links that `openLink`'s tests take live at file scope.
private let openSlackLink = ExternalLink(
  id: "fabc12", title: "Slack thread in C0123ABCD", url: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456",
  by: .found, t: now - 60_000)
private let openWebLink = ExternalLink(
  id: "l3", title: "Flag RFC", url: "https://example.com/rfc/flags", by: .you, t: now - 180_000)
private let groupWebLink = ExternalLink(
  id: "l2", title: "Design doc", url: "https://example.com/design", by: .you, t: now - 120_000)
private let groupSlackLink = ExternalLink(
  id: "l4", title: "Rollout thread", url: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456", by: .you,
  t: now - 240_000)

/// sbd decides what Remove does: it deletes an added link and hides a found one. The app always removes as you.
@MainActor
@Suite struct BoardModelLinksTests {
  // MARK: Remove on a row of the group's list

  static let found = ExternalLink(
    id: "fabc12", title: "Slack thread in C0123ABCD",
    url: "https://acme.slack.com/archives/C0123ABCD/p1700000000123456",
    by: .found, t: now - 60_000)
  static let added = ExternalLink(
    id: "l2", title: "Design doc", url: "https://example.com/design", by: .you, t: now - 120_000)

  /// The rows of group g1, which holds s2. Session s2 found the Slack thread, and the group has the design doc.
  static func rows() -> [LinkRows.Row] {
    let group = GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0, links: [added]), sessions: ["s2"])
    return LinkRows(group: group, liveSessions: ["s2": session("s2", links: [found])], now: now).rows
  }

  @Test func removeOnAGroupRowSendsGroupLinkRmWithTheGroup() async throws {
    let row = try #require(Self.rows().first { $0.owner == .group("g1") })

    let sent = await firstRequest { $0.removeLink(row) }

    #expect(sent.op == "group-link-rm")
    #expect(sent.args == ["group": "g1", "link": "l2", "by": "you"])
  }

  @Test func removeOnASessionRowSendsLinkRmWithTheRowsSession() async throws {
    let row = try #require(Self.rows().first { $0.owner == .session("s2") })

    let sent = await firstRequest { $0.removeLink(row) }

    #expect(sent.op == "link-rm")
    #expect(sent.args == ["session": "s2", "link": "fabc12", "by": "you"])
  }

  @Test func removeOnASidePanelRowSendsLinkRmWithTheSession() async throws {
    let row = try #require(LinkRows(session: session("s1", links: [Self.found]), now: now).rows.first)

    let sent = await firstRequest { $0.removeLink(row) }

    #expect(sent.op == "link-rm")
    #expect(sent.args == ["session": "s1", "link": "fabc12", "by": "you"])
  }

  // MARK: Open records link-open

  /// sbd records an Open of any session link. A Slack link's Open clears its new-reply mark. The Open tests wait at
  /// most 3 seconds for a request, because `firstRequest` waits forever when the model sends nothing.
  @Test(arguments: [openSlackLink, openWebLink])
  func openOnASidePanelRowSendsLinkOpenWithTheSessionAndTheLink(_ link: ExternalLink) async throws {
    let row = try #require(LinkRows(session: session("s1", links: [link]), now: now).rows.first)
    let (model, sent) = recordingModel()

    model.openLink(row)
    await sent.wait(for: "link-open")

    let expected: [String: JSON] = ["session": "s1", "link": .string(link.id), "by": "you"]
    #expect(sent.value.first { $0.op == "link-open" }?.args == expected)
  }

  @Test func openOnAGroupListsSessionRowSendsLinkOpenWithTheRowsSession() async throws {
    let row = try #require(Self.rows().first { $0.owner == .session("s2") })
    let (model, sent) = recordingModel()

    model.openLink(row)
    await sent.wait(for: "link-open")

    #expect(sent.value.first { $0.op == "link-open" }?.args == ["session": "s2", "link": "fabc12", "by": "you"])
  }

  @Test func openOnASessionRowSendsOneRequest() async throws {
    let row = try #require(LinkRows(session: session("s1", links: [Self.found]), now: now).rows.first)
    let (model, sent) = recordingModel()

    model.openLink(row)
    model.removeLink(row)
    await sent.wait(for: "link-rm")

    #expect(sent.ops == ["link-open", "link-rm"])
  }

  /// A group's own link has no session, and sbd keeps no Open time for it. The model's requests run in order on one
  /// queue, so a request sent after the Open shows whether the Open sent anything.
  @Test(arguments: [groupWebLink, groupSlackLink])
  func openOnAGroupsOwnRowSendsNothing(_ link: ExternalLink) async throws {
    let group = GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0, links: [link]), sessions: [])
    let row = try #require(LinkRows(group: group, liveSessions: [:], now: now).rows.first)
    try #require(row.owner == .group("g1"))
    let sentinel = try #require(Self.rows().first { $0.owner == .session("s2") })
    let (model, sent) = recordingModel()

    model.openLink(row)
    model.removeLink(sentinel)
    await sent.wait(for: "link-rm")

    #expect(sent.ops == ["link-rm"])
  }
}
