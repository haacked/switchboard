import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let minute: Int64 = 60_000
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour

private let slackURL = "https://acme.slack.com/archives/C0123ABCD/p1700000000123456"
private let linearURL = "https://linear.app/acme/issue/ENG-12"
private let webURL = "https://example.com/rfc/flags"
private let artifactURL = "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv"

/// A link as sbd stores it. Without `title`, the title is the one that sbd fills in for a link added without one.
private func linkFixture(
  _ id: String, url: String = webURL, title: String? = nil, by: LinkAuthor = .you, t: Int64 = now - 5 * minute
) -> ExternalLink {
  ExternalLink(id: id, title: title ?? (try! ExternalLink.cleanTitle(nil, url: url)), url: url, by: by, t: t)
}

/// A link that sbd found, with the title that `LinkTarget` gives.
private func foundFixture(_ id: String, url: String = slackURL, t: Int64 = now - 3 * minute) -> ExternalLink {
  ExternalLink(id: id, title: LinkTarget.parse(url)!.title, url: url, by: .found, t: t)
}

private func sessionFixture(_ id: String = "s1", name: String = "fix-cache", links: [ExternalLink]?) -> SessionSummary {
  var s = notedSession([], id: id)
  s.name = name
  s.links = links
  return s
}

private func sessionRows(_ links: [ExternalLink]?, id: String = "s1") -> [LinkRows.Row] {
  LinkRows(session: sessionFixture(id, links: links), now: now).rows
}

/// A group as `group-ls` returns it: the group's artifact list holds a row for each group link that
/// `GroupArtifact(link:)` accepts, merged the way sbd's `groupSummary` merges them.
private func groupFixture(_ links: [ExternalLink]?, id: String = "g", sessions: [String] = ["s1"]) -> GroupSummary {
  var g = GroupSummary(SessionGroup(id: id, name: "Flags", created: 0, links: links), sessions: sessions)
  let artifacts = GroupArtifacts.list((links ?? []).compactMap(GroupArtifact.init(link:)))
  if !artifacts.isEmpty { g.artifacts = artifacts }
  return g
}

private func byId(_ sessions: [SessionSummary]) -> [String: SessionSummary] {
  Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
}

private func groupRows(
  _ links: [ExternalLink]?, members: [String] = ["s1"], live: [SessionSummary] = []
) -> [LinkRows.Row] {
  LinkRows(group: groupFixture(links, sessions: members), liveSessions: byId(live), now: now).rows
}

// MARK: - Session rows

@Suite struct LinkRowsTests {
  @Test func aSessionWithoutLinksHasNoRows() {
    #expect(sessionRows(nil).isEmpty)
  }

  @Test func aSessionWithAnEmptyLinkListHasNoRows() {
    #expect(sessionRows([]).isEmpty)
  }

  /// sbd lists a session's links oldest first. The panel shows the newest first.
  @Test func rowsAreNewestFirst() {
    let links = [
      linkFixture("l1", t: now - 3 * hour), linkFixture("l2", t: now - 2 * hour), linkFixture("l3", t: now - hour),
    ]

    #expect(sessionRows(links).map(\.link.id) == ["l3", "l2", "l1"])
  }

  @Test func linksWithTheSameTimeSortByLinkId() {
    let links = [linkFixture("lc", t: now - hour), linkFixture("la", t: now - hour), linkFixture("lb", t: now - hour)]

    #expect(sessionRows(links).map(\.link.id) == ["la", "lb", "lc"])
  }

  @Test func theRowIdIsTheSessionIdAndTheLinkId() {
    #expect(sessionRows([linkFixture("l1")], id: "s7").map(\.id) == ["s7/l1"])
  }

  @Test func theOwnerIsTheSession() {
    #expect(sessionRows([linkFixture("l1")], id: "s7").map(\.owner) == [.session("s7")])
  }

  @Test func aRowKeepsItsLink() {
    let link = linkFixture("l1", title: "Flag RFC")

    #expect(sessionRows([link]).map(\.link) == [link])
  }

  /// A session's links to claude.ai artifacts list here, because a session's artifacts come from publish results
  /// and never from its links.
  @Test func aSessionLinkToAClaudeArtifactIsARow() {
    #expect(sessionRows([linkFixture("l1", url: artifactURL)]).map(\.link.id) == ["l1"])
  }

  @Test(arguments: [
    (LinkAuthor.found, 3 * minute, "found 3m ago"),
    (.you, 2 * hour, "added by you 2h ago"),
    (.claude, day, "added by Claude 1d ago"),
  ])
  func theCaptionSaysWhoAddedTheLinkAndWhen(_ by: LinkAuthor, _ age: Int64, _ caption: String) {
    #expect(sessionRows([linkFixture("l1", by: by, t: now - age)]).map(\.caption) == [caption])
  }

  @Test func theRowTitleIsTheDisplayTitle() {
    #expect(sessionRows([linkFixture("l1", url: linearURL)]).map(\.title) == ["Linear ENG-12"])
  }

  /// The side panel lists one session's links, so its spoken title doesn't name the owner.
  @Test func aSessionRowsSpokenTitleIsTheDisplayTitle() {
    #expect(sessionRows([linkFixture("l1", url: linearURL)]).map(\.spokenTitle) == ["Linear ENG-12"])
  }

  @Test func removeOnAFoundLinkSaysItHidesTheLink() {
    #expect(
      sessionRows([foundFixture("fabc12")]).map(\.removeHelp) == [
        "Hide this link. Switchboard won't add it again unless you add it by hand."
      ])
  }

  @Test(arguments: [LinkAuthor.you, .claude])
  func removeOnAnAddedLinkSaysItRemovesTheLink(_ by: LinkAuthor) {
    #expect(sessionRows([linkFixture("l1", by: by)]).map(\.removeHelp) == ["Remove this link from the list."])
  }

  // MARK: Display title

  /// The short form replaces a title only when the title is the URL that sbd filled in for a link added without
  /// `--title`.
  @Test(arguments: [
    ("a short web URL without a title", linkFixture("l1", url: webURL), "example.com/rfc/flags"),
    (
      "a web URL with a query and a fragment, without a title",
      linkFixture("l1", url: "https://example.com/rfc/flags?tab=2&x=y#intro"), "example.com/rfc/flags"
    ),
    ("a host without a path, without a title", linkFixture("l1", url: "https://example.com"), "example.com"),
    ("a host with a root path, without a title", linkFixture("l1", url: "https://example.com/"), "example.com"),
    ("a Slack URL without a title", linkFixture("l1", url: slackURL), "Slack thread in C0123ABCD"),
    ("a Linear URL without a title", linkFixture("l1", url: linearURL), "Linear ENG-12"),
    (
      "a Linear URL with a slug without a title",
      linkFixture("l1", url: "https://linear.app/acme/issue/ENG-12/fix-the-cache"), "Linear ENG-12"
    ),
    (
      "a link that Claude added without a title", linkFixture("l1", url: webURL, by: .claude),
      "example.com/rfc/flags"
    ),
    ("a given title", linkFixture("l1", url: webURL, title: "Flag RFC"), "Flag RFC"),
    ("a given title on a known kind", linkFixture("l1", url: slackURL, title: "Rollout thread"), "Rollout thread"),
    ("a title that Claude gave", linkFixture("l1", url: webURL, title: "Rollout plan", by: .claude), "Rollout plan"),
    ("a found link", foundFixture("fabc12"), "Slack thread in C0123ABCD"),
    (
      "a given title that is another URL", linkFixture("l1", url: webURL, title: "https://example.com/other"),
      "https://example.com/other"
    ),
    (
      "a given title that is the start of the URL", linkFixture("l1", url: webURL, title: "https://example.com/rfc"),
      "https://example.com/rfc"
    ),
  ])
  func titleShowsTheShortFormOnlyForATitleThatSbdFilledIn(_ shape: String, _ link: ExternalLink, _ title: String) {
    #expect(LinkRows.title(link) == title, "\(shape)")
  }

  /// sbd cut the stored title of a URL over 200 characters to 199 characters and an ellipsis. The short form
  /// replaces that cut title. The host and path here fit in 200 characters, so the test holds whether or not the
  /// short form is cut too.
  @Test func aLongWebURLWithoutATitleShowsItsHostAndPath() throws {
    let path = "/" + String(repeating: "a", count: 185)
    let link = linkFixture("l1", url: "https://example.com\(path)?q=1")
    try #require(link.title.hasSuffix("…"))

    #expect(LinkRows.title(link) == "example.com\(path)")
  }

  @Test func aLongKnownKindURLWithoutATitleShowsItsKindTitle() throws {
    let slug = String(repeating: "a", count: 250)
    let link = linkFixture("l1", url: "https://linear.app/acme/issue/ENG-12/\(slug)")
    try #require(link.title.hasSuffix("…"))

    #expect(LinkRows.title(link) == "Linear ENG-12")
  }
}

// MARK: - Group rows

extension LinkRowsTests {
  @Suite struct GroupRows {
    static let member = sessionFixture(
      "s1", name: "fix-cache", links: [foundFixture("fabc12", t: now - 3 * minute)])

    @Test func aGroupWithOnlyItsOwnLinksListsThem() {
      let rows = groupRows([linkFixture("l1", t: now - hour), linkFixture("l2", t: now - 2 * hour)])

      #expect(rows.map(\.id) == ["g/l1", "g/l2"])
    }

    @Test func aGroupLinksOwnerIsTheGroup() {
      #expect(groupRows([linkFixture("l1")]).map(\.owner) == [.group("g")])
    }

    @Test func aGroupWithOnlySessionLinksListsThem() {
      let rows = groupRows(nil, live: [Self.member])

      #expect(rows.map(\.id) == ["s1/fabc12"])
    }

    @Test func aSessionLinksOwnerIsTheSession() {
      #expect(groupRows(nil, live: [Self.member]).map(\.owner) == [.session("s1")])
    }

    @Test func aGroupWithBothListsTheGroupsAndTheSessionsLinks() {
      let rows = groupRows([linkFixture("l1", t: now - hour)], live: [Self.member])

      #expect(rows.map(\.id) == ["s1/fabc12", "g/l1"])
    }

    @Test func aGroupWithNoLinksHasNoRows() {
      #expect(groupRows(nil, live: [sessionFixture("s1", links: nil)]).isEmpty)
    }

    @Test func aGroupWithNoLinksHasNoLinkTitle() {
      let rows = LinkRows(group: groupFixture(nil), liveSessions: byId([sessionFixture("s1", links: nil)]), now: now)

      #expect(rows.linkTitle == nil)
    }

    @Test func linkTitleCountsTheGroupsAndTheSessionsRows() {
      let rows = LinkRows(group: groupFixture([linkFixture("l1")]), liveSessions: byId([Self.member]), now: now)

      #expect(rows.linkTitle == "Links 2")
    }

    /// The group's artifact list already shows a group link to a claude.ai artifact.
    @Test func linkTitleLeavesOutAGroupLinkToAnArtifact() {
      let links = [linkFixture("l1"), linkFixture("l2", url: artifactURL)]

      #expect(LinkRows(group: groupFixture(links), liveSessions: [:], now: now).linkTitle == "Links 1")
    }

    @Test func aGroupWhoseOnlyLinkIsAnArtifactHasNoLinkTitle() {
      let links = [linkFixture("l1", url: artifactURL)]

      #expect(LinkRows(group: groupFixture(links), liveSessions: [:], now: now).linkTitle == nil)
    }

    /// `sb rm` takes a session out of `ls`, and the group list leaves out a removed session's links.
    @Test func aMemberMissingFromTheLiveSessionsIsSkipped() {
      let rows = groupRows(nil, members: ["s1", "s9"], live: [Self.member])

      #expect(rows.map(\.id) == ["s1/fabc12"])
    }

    /// The app passes every live session, so a session outside the group must add nothing.
    @Test func aLiveSessionOutsideTheGroupAddsNothing() {
      let outsider = sessionFixture("s5", name: "other", links: [linkFixture("l9")])

      #expect(groupRows(nil, members: ["s1"], live: [Self.member, outsider]).map(\.id) == ["s1/fabc12"])
    }

    /// The artifact filter applies only to the group's own links. A session's artifact link has no row in the
    /// group's artifact list.
    @Test func aMembersLinkToAClaudeArtifactIsARow() {
      let member = sessionFixture("s1", links: [linkFixture("l1", url: artifactURL)])

      #expect(groupRows(nil, live: [member]).map(\.id) == ["s1/l1"])
    }

    @Test func rowsAcrossOwnersAreNewestFirst() {
      let s1 = sessionFixture("s1", links: [linkFixture("la", t: now - 3 * hour), linkFixture("lb", t: now - hour)])
      let s2 = sessionFixture("s2", name: "other", links: [linkFixture("lc", t: now - 2 * hour)])
      let links = [linkFixture("ld", t: now - 4 * hour), linkFixture("le", t: now - 30 * minute)]

      let rows = groupRows(links, members: ["s1", "s2"], live: [s1, s2])

      #expect(rows.map(\.id) == ["g/le", "s1/lb", "s2/lc", "s1/la", "g/ld"])
    }

    @Test func rowsWithTheSameTimeSortByOwnerIdThenLinkId() {
      let t = now - hour
      let s1 = sessionFixture("s1", links: [linkFixture("lz", t: t), linkFixture("la", t: t)])
      let s2 = sessionFixture("s2", name: "other", links: [linkFixture("lb", t: t)])
      let links = [linkFixture("ly", t: t), linkFixture("lx", t: t)]

      let rows = groupRows(links, members: ["s2", "s1"], live: [s2, s1])

      #expect(rows.map(\.id) == ["g/lx", "g/ly", "s1/la", "s1/lz", "s2/lb"])
    }

    @Test(arguments: [(LinkAuthor.you, "group · added by you 2h ago"), (.claude, "group · added by Claude 2h ago")])
    func aGroupRowsCaptionStartsWithGroup(_ by: LinkAuthor, _ caption: String) {
      #expect(groupRows([linkFixture("l1", by: by, t: now - 2 * hour)]).map(\.caption) == [caption])
    }

    @Test func aSessionRowsCaptionStartsWithTheSessionsName() {
      #expect(groupRows(nil, live: [Self.member]).map(\.caption) == ["fix-cache · found 3m ago"])
    }

    @Test func aGroupRowsTitleIsTheDisplayTitle() {
      #expect(groupRows([linkFixture("l1", url: linearURL)]).map(\.title) == ["Linear ENG-12"])
    }

    // MARK: Risk 2: row identity across owners

    /// A found link's id hashes its page, so two sessions that found one Slack thread give the link one id.
    @Test func twoSessionsWithTheSameFoundLinkGiveTwoRows() {
      let s1 = sessionFixture("s1", links: [foundFixture("fabc12")])
      let s2 = sessionFixture("s2", name: "other", links: [foundFixture("fabc12")])

      let rows = groupRows(nil, members: ["s1", "s2"], live: [s1, s2])

      #expect(rows.map(\.id) == ["s1/fabc12", "s2/fabc12"])
    }

    @Test func twoSessionsWithTheSameFoundLinkKeepTheirOwners() {
      let s1 = sessionFixture("s1", links: [foundFixture("fabc12")])
      let s2 = sessionFixture("s2", name: "other", links: [foundFixture("fabc12")])

      let rows = groupRows(nil, members: ["s1", "s2"], live: [s1, s2])

      #expect(rows.map(\.owner) == [.session("s1"), .session("s2")])
    }

    /// VoiceOver reads the buttons' labels without the caption, so the spoken title names the owner.
    @Test func twoSessionsWithTheSameFoundLinkGiveDifferentSpokenTitles() {
      let s1 = sessionFixture("s1", links: [foundFixture("fabc12")])
      let s2 = sessionFixture("s2", name: "other", links: [foundFixture("fabc12")])

      let rows = groupRows(nil, members: ["s1", "s2"], live: [s1, s2])

      #expect(
        rows.map(\.spokenTitle) == [
          "Slack thread in C0123ABCD from fix-cache", "Slack thread in C0123ABCD from other",
        ])
    }

    @Test func aGroupLinksSpokenTitleNamesTheGroup() {
      #expect(groupRows([linkFixture("l1", url: linearURL)]).map(\.spokenTitle) == ["Linear ENG-12 from group"])
    }

    @Test func aGroupLinkAndASessionLinkWithTheSameIdAndURLGiveTwoRows() {
      let member = sessionFixture("s1", links: [linkFixture("l1", url: webURL)])

      let rows = groupRows([linkFixture("l1", url: webURL)], live: [member])

      #expect(rows.map(\.id) == ["g/l1", "s1/l1"])
      #expect(rows.map(\.owner) == [.group("g"), .session("s1")])
    }

    @Test func aSessionWithAFoundAndAnAddedLinkGivesTwoRows() {
      let member = sessionFixture("s1", links: [foundFixture("fabc12", t: now - hour), linkFixture("l1", t: now)])

      #expect(groupRows(nil, live: [member]).map(\.id) == ["s1/l1", "s1/fabc12"])
    }

    @Test func everyRowIdInOneListIsDistinct() {
      let s1 = sessionFixture("s1", links: [foundFixture("fabc12"), linkFixture("l1")])
      let s2 = sessionFixture("s2", name: "other", links: [foundFixture("fabc12"), linkFixture("l1")])

      let rows = groupRows([linkFixture("l1"), linkFixture("fabc12")], members: ["s1", "s2"], live: [s1, s2])

      #expect(rows.count == 6)
      #expect(Set(rows.map(\.id)).count == rows.count)
    }
  }
}

// MARK: - Risk 1: the Artifacts/Links split for group links

/// A group link lists in exactly one of the group's two lists: Artifacts when `GroupArtifact(link:)` accepts it,
/// else Links.
extension LinkRowsTests {
  @Suite struct ArtifactsLinksSplit {
    /// A spelling of a group link's URL.
    struct Shape: Sendable, CustomTestStringConvertible {
      var name: String
      var url: String
      var testDescription: String { name }
    }

    static let shapes: [Shape] = [
      Shape(name: "short artifact link", url: "https://claude.ai/artifact/AbCdEfGhIjKlMnOpQrStUv"),
      Shape(name: "code artifact link", url: "https://claude.ai/code/artifact/00000000-1111-2222-3333-444444444444"),
      Shape(name: "short artifact link with a query", url: "https://claude.ai/artifact/QueryArtifact?tab=2"),
      Shape(name: "short artifact link with a fragment", url: "https://claude.ai/artifact/FragArtifact#top"),
      Shape(
        name: "code artifact link with a query",
        url: "https://claude.ai/code/artifact/11111111-1111-2222-3333-444444444444?x=1"),
      Shape(
        name: "code artifact link with a fragment",
        url: "https://claude.ai/code/artifact/22222222-1111-2222-3333-444444444444#part"),
      Shape(
        name: "code artifact link with a query and a fragment",
        url: "https://claude.ai/code/artifact/33333333-1111-2222-3333-444444444444?x=1#part"),
      Shape(name: "uppercase host", url: "https://Claude.AI/artifact/UpperHost"),
      Shape(name: "uppercase scheme", url: "HTTPS://claude.ai/artifact/UpperScheme"),
      Shape(name: "trailing slash", url: "https://claude.ai/artifact/TrailingSlash/"),
      Shape(name: "http artifact link", url: "http://claude.ai/artifact/PlainHttp"),
      Shape(name: "another host with an artifact path", url: "https://example.com/artifact/OtherHost"),
      Shape(name: "a subdomain of claude.ai", url: "https://www.claude.ai/artifact/Subdomain"),
      Shape(name: "an artifact path without an id", url: "https://claude.ai/artifact"),
      Shape(name: "an artifact path with an extra segment", url: "https://claude.ai/artifact/Extra/more"),
      Shape(name: "a claude.ai page that is not an artifact", url: "https://claude.ai/chat/abc"),
      Shape(name: "a plain web URL", url: webURL),
      Shape(name: "a Slack URL", url: slackURL),
      Shape(name: "a Linear URL", url: linearURL),
    ]

    /// Whether the link lists in the group's artifact list and in its link list.
    static func placement(_ links: [ExternalLink], of link: ExternalLink) -> (artifacts: Bool, links: Bool) {
      let group = groupFixture(links)
      let artifactRows = GroupArtifactRows(group: group, liveNames: [:], now: now).rows
      let linkRows = LinkRows(group: group, liveSessions: [:], now: now).rows
      return (
        artifactRows.contains { $0.artifact.link == link.id },
        linkRows.contains { $0.owner == .group("g") && $0.link.id == link.id }
      )
    }

    @Test(arguments: shapes)
    func aGroupLinkListsInExactlyOneOfArtifactsAndLinks(_ shape: Shape) {
      let link = linkFixture("l1", url: shape.url)

      let placed = Self.placement([link], of: link)

      #expect(placed.artifacts != placed.links)
    }

    /// The Links list leaves out exactly the links that `GroupArtifact(link:)` accepts.
    @Test(arguments: shapes)
    func aGroupLinkListsInLinksOnlyWhenNoArtifactRowNamesIt(_ shape: Shape) {
      let link = linkFixture("l1", url: shape.url)

      #expect(Self.placement([link], of: link).links == (GroupArtifact(link: link) == nil))
    }

    /// Every shape in one group, each with its own artifact id, so no two rows merge.
    @Test func everyLinkOfOneGroupListsInExactlyOneList() {
      let links = Self.shapes.enumerated().map { i, shape in linkFixture("l\(i)", url: shape.url) }

      let misplaced = links.filter { link in
        let placed = Self.placement(links, of: link)
        return placed.artifacts == placed.links
      }

      #expect(misplaced.map(\.url) == [])
    }
  }
}

// MARK: - Link kinds

extension LinkRowsTests {
  @Suite struct Kinds {
    @Test(arguments: LinkKind.allCases)
    func eachKindsSymbolResolves(_ kind: LinkKind) {
      #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.label) != nil)
    }

    @Test(arguments: [
      (LinkKind.slack, "number"), (.linear, "checkmark.circle"), (.notion, "doc.text"), (.google, "doc.richtext"),
      (.grafana, "chart.xyaxis.line"), (.web, "link"),
    ])
    func eachKindHasItsSymbol(_ kind: LinkKind, _ symbol: String) {
      #expect(kind.symbol == symbol)
    }

    @Test(arguments: [
      (LinkKind.slack, "Slack"), (.linear, "Linear"), (.notion, "Notion"), (.google, "Google"),
      (.grafana, "Grafana"), (.web, "Web"),
    ])
    func eachKindHasItsLabel(_ kind: LinkKind, _ label: String) {
      #expect(kind.label == label)
    }
  }
}
