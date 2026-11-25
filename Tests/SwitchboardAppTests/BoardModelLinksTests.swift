import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000

private func session(_ id: String, links: [ExternalLink]) -> SessionSummary {
  var s = notedSession([], id: id)
  s.links = links
  return s
}

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

  /// The Artifacts popover removes a group link to a claude.ai artifact by the link's id, because Links leaves it out.
  @Test func removeByIdOnAGroupSendsGroupLinkRm() async {
    let sent = await firstRequest { $0.removeLink("l9", of: .group("g1")) }

    #expect(sent.op == "group-link-rm")
    #expect(sent.args == ["group": "g1", "link": "l9", "by": "you"])
  }
}
