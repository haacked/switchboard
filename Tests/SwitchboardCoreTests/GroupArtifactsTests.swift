import Foundation
import Testing

@testable import SwitchboardCore

private let second = "https://claude.ai/artifact/SecondPage"
private let secondUUID = "55555555-1111-2222-3333-444444444444"

private func artifact(
  _ url: String = artifactShortURL, id: String? = artifactUUID, title: String = "Delta Rates", published: Int64,
  updated: Int64, removed: Int64? = nil
) -> SessionArtifact {
  SessionArtifact(
    url: url, artifactId: id, title: title, published: published, updated: updated, removed: removed)
}

/// The rows that `forgetSession` keeps for a removed session: its entries with its id and name.
private func kept(_ artifacts: [SessionArtifact], session: String, name: String) -> [GroupArtifact] {
  artifacts.map {
    GroupArtifact(
      url: $0.url, artifactId: $0.artifactId, title: $0.title, published: $0.published, updated: $0.updated,
      removed: $0.removed, session: session, sessionName: name)
  }
}

private func row(
  _ url: String = artifactShortURL, id: String? = artifactUUID, title: String = "Delta Rates", published: Int64,
  updated: Int64, removed: Int64? = nil, session: String, name: String
) -> GroupArtifact {
  GroupArtifact(
    url: url, artifactId: id, title: title, published: published, updated: updated, removed: removed,
    session: session, sessionName: name)
}

/// A live member or the group's chat, with its artifacts.
struct ArtifactMember: Sendable {
  var id: String
  var name: String
  var artifacts: [SessionArtifact]
}

private func list(_ live: [ArtifactMember], kept: [GroupArtifact] = []) -> [GroupArtifact] {
  GroupArtifacts.list(
    live.flatMap { member in member.artifacts.map { GroupArtifact($0, session: member.id, sessionName: member.name) } }
      + kept)
}

/// A group link that the user added.
private func groupLink(
  _ url: String = artifactShortURL, id: String = "l1", title: String? = nil, by author: Author = .you, t: Int64
) -> GroupLink {
  GroupLink(id: id, title: title ?? url, url: url, by: author, t: t)
}

/// The row that `GroupArtifact(link:)` derives from a link that it must accept.
private func linkRow(
  _ url: String = artifactShortURL, id: String = "l1", title: String? = nil, by author: Author = .you, t: Int64
) throws -> GroupArtifact {
  try #require(GroupArtifact(link: groupLink(url, id: id, title: title, by: author, t: t)))
}

/// The group list (`GroupArtifacts.list`): live members' and the chat's entries plus the kept rows, one row per
/// artifact, newest `updated` first.
@Suite struct GroupArtifactsTests {
  @Test func noInputsListNothing() {
    #expect(list([]).isEmpty)
  }

  @Test func aLiveMembersEntryBecomesARowWithItsIdAndName() {
    let s = ArtifactMember(id: "s1", name: "flags-cache", artifacts: [artifact(published: 1000, updated: 2000)])

    #expect(list([s]) == [row(published: 1000, updated: 2000, session: "s1", name: "flags-cache")])
  }

  @Test func aKeptRowIsListedAsItWasKept() {
    let k = row(published: 1000, updated: 2000, removed: 3000, session: "gone", name: "old-name")

    #expect(list([], kept: [k]) == [k])
  }

  // MARK: Same artifact

  @Test func twoRowsWithTheSameURLMergeIntoOneFromTheLatestUpdate() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(title: "Old", published: 1000, updated: 2000)])
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "New", published: 1500, updated: 4000)])

    let rows = list([a, b])

    #expect(rows == [row(title: "New", published: 1000, updated: 4000, session: "b", name: "bravo")])
  }

  @Test func aLiveRowAndAKeptRowWithTheSameURLMerge() {
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "Live", published: 3000, updated: 3000)])
    let k = row(title: "Kept", published: 1000, updated: 2000, session: "gone", name: "removed-one")

    let rows = list([b], kept: [k])

    #expect(rows == [row(title: "Live", published: 1000, updated: 3000, session: "b", name: "bravo")])
  }

  /// A `/code/artifact/<uuid>` link and the short link name the same artifact when the ids match.
  @Test func rowsWithTheSameArtifactIdMergeAcrossLinkForms() {
    let a = ArtifactMember(
      id: "a", name: "alpha", artifacts: [artifact(artifactShortURL, published: 1000, updated: 1000)])
    let b = ArtifactMember(
      id: "b", name: "bravo", artifacts: [artifact(artifactCodeURL, published: 2000, updated: 2000)])

    let rows = list([a, b])

    #expect(rows.count == 1)
    #expect(rows.first?.session == "b")
    #expect(rows.first?.published == 1000)
    #expect(rows.first?.updated == 2000)
  }

  @Test func rowsWithDifferentURLsAndNoIdsStaySeparate() {
    let a = ArtifactMember(
      id: "a", name: "alpha",
      artifacts: [
        artifact(artifactShortURL, id: nil, published: 1000, updated: 1000),
        artifact(second, id: nil, title: "Second", published: 1000, updated: 2000),
      ])

    #expect(list([a]).map(\.url) == [second, artifactShortURL])
  }

  @Test func rowsWithDifferentURLsAndDifferentIdsStaySeparate() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000)])
    let b = ArtifactMember(
      id: "b", name: "bravo", artifacts: [artifact(second, id: secondUUID, published: 1000, updated: 2000)])

    #expect(list([a, b]).count == 2)
  }

  /// The rule is not transitive: the short link matches the code link by id, and the code link matches an
  /// id-less row by URL. All three are one artifact, whatever the order of the members.
  @Test func aChainOfMatchesMergesIntoOneRowInEveryOrder() {
    let members = [
      ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000)]),
      ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(artifactCodeURL, published: 2000, updated: 2000)]),
      ArtifactMember(
        id: "c", name: "charlie", artifacts: [artifact(artifactCodeURL, id: nil, published: 3000, updated: 3000)]),
    ]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

    let lists = orders.map { order in list(order.map { members[$0] }) }

    #expect(
      lists.first
        == [
          row(artifactCodeURL, id: artifactUUID, published: 1000, updated: 3000, session: "c", name: "charlie")
        ])
    #expect(Set(lists.map { "\($0)" }).count == 1)
  }

  // MARK: Removed

  /// `removed` is set when the latest removal among the merged rows is at or after their latest update.
  @Test(arguments: [(5000, 3000, 5000), (3000, 3000, 3000), (2000, 3000, nil)] as [(Int64, Int64, Int64?)])
  func theMergedRowIsRemovedOnlyWhenTheLatestRemovalIsAtOrAfterTheLatestUpdate(
    removedAt: Int64, otherUpdated: Int64, removed: Int64?
  ) {
    let a = ArtifactMember(
      id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000, removed: removedAt)])
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: otherUpdated)])

    let rows = list([a, b])

    #expect(rows.map(\.removed) == [removed])
  }

  @Test func aRemovedRowStaysInTheList() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000, removed: 2000)])

    #expect(list([a]).map(\.removed) == [2000])
  }

  // MARK: Order

  @Test func rowsSortByUpdatedNewestFirst() {
    let a = ArtifactMember(
      id: "a", name: "alpha",
      artifacts: [
        artifact(published: 1000, updated: 1000),
        artifact(second, id: secondUUID, title: "Second", published: 1000, updated: 3000),
      ])
    let third = "https://claude.ai/artifact/ThirdPage"
    let k = row(third, id: nil, title: "Third", published: 500, updated: 2000, session: "gone", name: "gone")

    #expect(list([a], kept: [k]).map(\.url) == [second, third, artifactShortURL])
  }

  @Test func rowsWithEqualUpdatedSortByURL() {
    let z = "https://claude.ai/artifact/ZZZ"
    let a = "https://claude.ai/artifact/AAA"
    let m = ArtifactMember(
      id: "m", name: "member",
      artifacts: [
        artifact(z, id: nil, published: 1000, updated: 1000), artifact(a, id: nil, published: 1000, updated: 1000),
      ])

    #expect(list([m]).map(\.url) == [a, z])
  }

  // MARK: The same list before and after sb rm

  /// A group whose member `s` has artifacts, with the other members and the kept rows around it.
  struct RemovalCase: Sendable, CustomTestStringConvertible {
    var name: String
    var s: [SessionArtifact]
    var others: [ArtifactMember] = []
    var kept: [GroupArtifact] = []
    /// The group's links. Each one that `GroupArtifact(link:)` accepts lists as a row.
    var links: [GroupLink] = []
    var testDescription: String { name }

    var linkRows: [GroupArtifact] { links.compactMap(GroupArtifact.init(link:)) }
  }

  static let removals: [RemovalCase] = [
    RemovalCase(name: "one artifact", s: [artifact(published: 1000, updated: 2000)]),
    RemovalCase(name: "a removed entry", s: [artifact(published: 1000, updated: 2000, removed: 3000)]),
    RemovalCase(
      name: "the same URL live in another member, updated later", s: [artifact(published: 1000, updated: 2000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1500, updated: 4000)])
      ]),
    RemovalCase(
      name: "the same URL live in another member, updated earlier", s: [artifact(published: 1000, updated: 5000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1500, updated: 4000)])
      ]),
    RemovalCase(
      name: "the same URL kept from a removed session", s: [artifact(published: 3000, updated: 3000)],
      kept: [row(title: "Old", published: 1000, updated: 2000, removed: 2500, session: "gone", name: "gone")]),
    RemovalCase(
      name: "the same artifact by id under the code link",
      s: [artifact(artifactCodeURL, published: 1000, updated: 2000)],
      others: [ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: 1500)])]),
    RemovalCase(
      name: "two artifacts with equal updated",
      s: [artifact(published: 1000, updated: 2000), artifact(second, id: secondUUID, published: 1000, updated: 2000)]),
    RemovalCase(
      name: "the same URL with equal updated in another member",
      s: [artifact(title: "S", published: 1000, updated: 2000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1000, updated: 2000)])
      ]),
    RemovalCase(
      name: "a removal at the other member's update time",
      s: [artifact(published: 1000, updated: 1000, removed: 2000)],
      others: [ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: 2000)])]),
    RemovalCase(
      name: "a link to the same artifact, added after the publish", s: [artifact(published: 1000, updated: 2000)],
      links: [groupLink(t: 5000)]),
    RemovalCase(
      name: "a link to the same artifact, added before the publish", s: [artifact(published: 1000, updated: 2000)],
      links: [groupLink(t: 500)]),
    RemovalCase(
      name: "a link added after a delete", s: [artifact(published: 1000, updated: 2000, removed: 3000)],
      links: [groupLink(t: 4000)]),
    RemovalCase(
      name: "a code link to the same artifact", s: [artifact(published: 1000, updated: 2000)],
      links: [groupLink(artifactCodeURL, t: 1500)]),
    RemovalCase(
      name: "a link at the publish's update time", s: [artifact(published: 1000, updated: 2000)],
      links: [groupLink(t: 2000)]),
  ]

  /// `forgetSession` turns the member's entries into kept rows with its id and name. The list must not change.
  @Test(arguments: removals)
  func theListIsTheSameWhetherTheMemberIsLiveOrKept(_ c: RemovalCase) {
    let others = c.others
    let s = ArtifactMember(id: "s", name: "flags-cache", artifacts: c.s)

    let live: [ArtifactMember] = others + [s]
    let keptRows: [GroupArtifact] = c.kept + kept(c.s, session: s.id, name: s.name)

    let before = list(live, kept: c.kept + c.linkRows)
    let after = list(others, kept: keptRows + c.linkRows)

    #expect(after == before)
  }

  /// A live list does not depend on the order of the members.
  @Test(arguments: removals)
  func theListDoesNotDependOnTheOrderOfTheMembers(_ c: RemovalCase) {
    let others = c.others
    let s = ArtifactMember(id: "s", name: "flags-cache", artifacts: c.s)

    let last: [ArtifactMember] = others + [s]
    let first: [ArtifactMember] = [s] + others

    #expect(list(last, kept: c.kept + c.linkRows) == list(first, kept: c.kept + c.linkRows))
  }

  /// The group's chat publishes plan artifacts. Its entries list like a member's.
  @Test func theChatsEntriesListLikeAMembers() {
    let chat = ArtifactMember(id: "c1", name: "Flags chat", artifacts: [artifact(published: 1000, updated: 1000)])
    let member = ArtifactMember(
      id: "s1", name: "alpha", artifacts: [artifact(second, id: secondUUID, published: 2000, updated: 2000)])

    #expect(list([member, chat]).map(\.session) == ["s1", "c1"])
  }

  // MARK: A row from a group link

  @Test func aLinkRowHasTheLinksFieldsAndNoSession() throws {
    let r = try linkRow(title: "Flag evaluations plan", t: 7000)

    #expect(r.url == artifactShortURL)
    #expect(r.artifactId == nil)
    #expect(r.title == "Flag evaluations plan")
    #expect(r.published == 7000)
    #expect(r.updated == 7000)
    #expect(r.removed == nil)
    #expect(r.session == nil)
    #expect(r.sessionName == nil)
    #expect(r.link == "l1")
  }

  @Test func aCodeLinkRowHasTheUUIDAsItsArtifactId() throws {
    let r = try linkRow(artifactCodeURL, t: 7000)

    #expect(r.artifactId == artifactUUID)
  }

  /// A link row's `updated` is when the link was added.
  @Test func theCaptionSaysAddedOnALinkRowAndUpdatedOnASessionRow() throws {
    let minute: Int64 = 60_000
    let now: Int64 = 10 * minute

    #expect(try linkRow(t: now - 5 * minute).caption(now: now) == "added 5m ago")
    #expect(
      row(published: 0, updated: now - 5 * minute, session: "s1", name: "alpha").caption(now: now) == "updated 5m ago")
    #expect(
      row(published: 0, updated: 0, removed: now - 5 * minute, session: "s1", name: "alpha").caption(now: now)
        == "removed 5m ago")
  }

  // MARK: Merging a link with a session's rows

  @Test func aLinkAloneListsTheLinksRow() throws {
    let l = try linkRow(t: 7000)

    #expect(GroupArtifacts.list([l]) == [l])
  }

  @Test func aLinkNewerThanTheLastPublishKeepsTheSessionsFields() throws {
    let s = row(published: 1000, updated: 2000, session: "s1", name: "flags-cache")

    let rows = GroupArtifacts.list([s, try linkRow(t: 5000)])

    #expect(rows.count == 1)
    let r = try #require(rows.first)
    #expect(r.url == artifactShortURL)
    #expect(r.artifactId == artifactUUID)
    #expect(r.title == "Delta Rates")
    #expect(r.session == "s1")
    #expect(r.sessionName == "flags-cache")
    #expect(r.published == 1000)
    #expect(r.updated == 2000)
    #expect(r.removed == nil)
    #expect(r.link == "l1")
  }

  @Test func aLinkOlderThanTheFirstPublishKeepsTheSessionsPublished() throws {
    let s = row(published: 1000, updated: 2000, session: "s1", name: "flags-cache")

    let rows = GroupArtifacts.list([try linkRow(t: 500), s])

    #expect(rows.count == 1)
    #expect(rows.first?.published == 1000)
    #expect(rows.first?.updated == 2000)
    #expect(rows.first?.title == "Delta Rates")
    #expect(rows.first?.link == "l1")
  }

  @Test func aLinkAndAKeptRowKeepTheKeptRowsFields() throws {
    let k = row(title: "Kept", published: 1000, updated: 2000, session: "gone", name: "removed-one")

    let rows = list([], kept: [k, try linkRow(t: 5000)])

    #expect(rows.count == 1)
    #expect(rows.first?.title == "Kept")
    #expect(rows.first?.session == "gone")
    #expect(rows.first?.sessionName == "removed-one")
    #expect(rows.first?.link == "l1")
  }

  @Test func aLinkWithALiveAndAKeptRowTakesTheLatestSessionRow() throws {
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "Live", published: 3000, updated: 3000)])
    let k = row(title: "Kept", published: 1000, updated: 2000, session: "gone", name: "removed-one")

    let rows = list([b], kept: [k, try linkRow(t: 9000)])

    #expect(rows.count == 1)
    #expect(rows.first?.title == "Live")
    #expect(rows.first?.session == "b")
    #expect(rows.first?.published == 1000)
    #expect(rows.first?.updated == 3000)
    #expect(rows.first?.link == "l1")
  }

  @Test func aLinkAddedAfterADeleteLeavesTheRowRemoved() throws {
    let s = row(published: 1000, updated: 2000, removed: 3000, session: "s1", name: "flags-cache")

    let rows = GroupArtifacts.list([s, try linkRow(t: 4000)])

    #expect(rows.count == 1)
    #expect(rows.first?.removed == 3000)
    #expect(rows.first?.updated == 2000)
    #expect(rows.first?.link == "l1")
  }

  @Test func aRepublishAfterADeleteWithALinkPresentIsNotRemoved() throws {
    let deleted = row(published: 1000, updated: 2000, removed: 3000, session: "gone", name: "removed-one")
    let republished = row(published: 1500, updated: 5000, session: "s1", name: "flags-cache")

    let rows = GroupArtifacts.list([deleted, try linkRow(t: 4000), republished])

    #expect(rows.count == 1)
    #expect(rows.first?.removed == nil)
    #expect(rows.first?.updated == 5000)
    #expect(rows.first?.session == "s1")
  }

  @Test func aSessionRowWithoutALinkHasNoLink() {
    let rows = GroupArtifacts.list([row(published: 1000, updated: 2000, session: "s1", name: "flags-cache")])

    #expect(rows.first?.link == nil)
  }

  @Test func twoLinksOfOneArtifactKeepTheEarliestLink() throws {
    let later = try linkRow(id: "l1", title: "Later", t: 3000)
    let earlier = try linkRow("\(artifactShortURL)#top", id: "l2", title: "Earlier", t: 2000)

    let rows = GroupArtifacts.list([later, earlier])

    #expect(rows.count == 1)
    #expect(rows.first?.link == "l2")
    #expect(rows.first?.title == "Earlier")
    #expect(rows.first?.session == nil)
  }

  @Test func twoLinksOfOneArtifactAddedAtOnceKeepTheFirstLinkById() throws {
    let b = try linkRow(id: "lb", title: "B", t: 2000)
    let a = try linkRow("\(artifactShortURL)/", id: "la", title: "A", t: 2000)

    let rows = GroupArtifacts.list([b, a])

    #expect(rows.count == 1)
    #expect(rows.first?.link == "la")
    #expect(rows.first?.title == "A")
  }

  /// A `/code/artifact/<uuid>` link names the uuid that a publish of the short link records.
  @Test func aCodeLinkJoinsAShortURLRowWithThatArtifactId() throws {
    let s = row(artifactShortURL, id: artifactUUID, published: 1000, updated: 2000, session: "s1", name: "alpha")

    let rows = GroupArtifacts.list([s, try linkRow(artifactCodeURL, t: 5000)])

    #expect(rows.count == 1)
    #expect(rows.first?.url == artifactShortURL)
    #expect(rows.first?.session == "s1")
    #expect(rows.first?.link == "l1")
  }

  /// sbd cannot map a short id to a uuid, so the two links of one page list apart without a session row.
  @Test func aShortLinkAndACodeLinkWithoutASessionRowListTwoRows() throws {
    let rows = GroupArtifacts.list([
      try linkRow(artifactShortURL, id: "l1", t: 3000), try linkRow(artifactCodeURL, id: "l2", t: 2000),
    ])

    #expect(rows.count == 2)
  }

  @Test func aShortLinkAndACodeLinkJoinThroughASessionRowAndKeepTheEarliestLink() throws {
    let s = row(artifactShortURL, id: artifactUUID, published: 1000, updated: 1000, session: "s1", name: "alpha")
    let short = try linkRow(artifactShortURL, id: "l1", t: 3000)
    let code = try linkRow(artifactCodeURL, id: "l2", t: 2000)

    let rows = GroupArtifacts.list([short, s, code])

    #expect(rows.count == 1)
    #expect(rows.first?.session == "s1")
    #expect(rows.first?.link == "l2")
  }

  /// The link and the code row share nothing directly. The short row matches the link by URL and the code row by
  /// id, so all three are one artifact in every order.
  @Test func aLinkAndASessionRowJoinedOnlyThroughAThirdRowListOneRowInEveryOrder() throws {
    let rows = [
      try linkRow(artifactShortURL, t: 5000),
      row(
        artifactShortURL, id: artifactUUID, title: "Short", published: 1000, updated: 1000, session: "a", name: "alpha"),
      row(
        artifactCodeURL, id: artifactUUID, title: "Code", published: 2000, updated: 3000, session: "b", name: "bravo"),
    ]

    let lists = permutations(rows).map(GroupArtifacts.list)

    #expect(Set(lists.map { "\($0)" }).count == 1)
    #expect(lists.first?.count == 1)
    #expect(lists.first?.first?.session == "b")
    #expect(lists.first?.first?.title == "Code")
    #expect(lists.first?.first?.published == 1000)
    #expect(lists.first?.first?.link == "l1")
  }

  /// Ties on `updated` and `t` make the tiebreak decide, and the list must not depend on the order of the rows.
  @Test func aMixOfSessionKeptAndLinkRowsListsTheSameInEveryOrder() throws {
    let rows = [
      row(published: 1000, updated: 2000, session: "s1", name: "alpha"),
      row(published: 900, updated: 2000, removed: 1500, session: "gone", name: "removed-one"),
      try linkRow(artifactShortURL, id: "l1", t: 2000),
      try linkRow(artifactCodeURL, id: "l2", t: 2000),
      row(id: nil, title: "Other title", published: 1200, updated: 2000, session: "s3", name: "charlie"),
    ]

    let lists = permutations(rows).map(GroupArtifacts.list)

    #expect(lists.count == 120)
    #expect(Set(lists.map { "\($0)" }).count == 1)
    #expect(lists.first?.count == 1)
    #expect(lists.first?.first?.link == "l1")
    #expect(lists.first?.first?.published == 900)
    #expect(lists.first?.first?.removed == nil)
    #expect(lists.first?.first?.session != nil)
  }

  @Test func linkOnlyRowsListTheSameInEveryOrder() throws {
    let rows = [
      try linkRow(artifactShortURL, id: "l3", t: 2000),
      try linkRow("\(artifactShortURL)#a", id: "l1", t: 2000),
      try linkRow("\(artifactShortURL)/", id: "l2", t: 2000),
      try linkRow(second, id: "l0", t: 2000),
    ]

    let lists = permutations(rows).map(GroupArtifacts.list)

    #expect(Set(lists.map { "\($0)" }).count == 1)
    #expect(lists.first?.map(\.url) == [artifactShortURL, second])
    #expect(lists.first?.map(\.link) == ["l1", "l0"])
  }

  // MARK: names(_:)

  @Test(arguments: [
    (artifactShortURL, true),
    ("\(artifactShortURL)?v=2#top", true),
    ("HTTPS://CLAUDE.AI/artifact/\(artifactShortId)", true),
    (artifactCodeURL, true),
    ("https://claude.ai/artifact/\(artifactUUID)", true),
    (second, false),
    ("https://claude.ai/code/artifact/\(secondUUID)", false),
    ("https://evil.com/artifact/\(artifactShortId)", false),
    ("", false),
  ])
  func namesMatchesTheSameURLOrTheSameId(_ url: String, _ names: Bool) {
    let r = row(published: 1000, updated: 1000, session: "s1", name: "alpha")

    #expect(r.names(url) == names)
  }

  @Test func namesDoesNotMatchByIdWhenTheRowHasNoId() {
    let r = row(id: nil, published: 1000, updated: 1000, session: "s1", name: "alpha")

    #expect(!r.names(artifactCodeURL))
    #expect(r.names(artifactShortURL))
  }
}

/// A group keeps its removed sessions' rows in `SessionGroup.keptArtifacts`, and a merge carries them.
@Suite struct GroupKeptArtifactsTests {
  private func group(_ id: String, _ name: String, artifacts: [GroupArtifact]? = nil) -> SessionGroup {
    var g = SessionGroup(id: id, name: name, created: 1)
    g.keptArtifacts = artifacts
    return g
  }

  @Test func aGroupThatAnOlderSbdStoredHasNoKeptArtifacts() throws {
    let g = try JSONCoding.decode(
      SessionGroup.self, from: #"{"id": "g1", "name": "Flags", "notes": [], "created": 1}"#)

    #expect(g.keptArtifacts == nil)
  }

  @Test func keptArtifactsSurviveEncoding() throws {
    let g = group(
      "g1", "Flags", artifacts: [row(published: 1000, updated: 2000, removed: 3000, session: "s1", name: "alpha")])

    #expect(try JSONCoding.decode(SessionGroup.self, from: try JSONCoding.encode(g)) == g)
  }

  /// The JSON is flat, so `jq '.groups[].artifacts[].url'` reads each URL.
  @Test func aKeptRowEncodesItsFieldsFlat() throws {
    let r = row(published: 1000, updated: 2000, removed: 3000, session: "s1", name: "alpha")

    let json = try #require(JSON.parse(try JSONCoding.encode(r)))

    #expect(json["url"]?.string == artifactShortURL)
    #expect(json["artifactId"]?.string == artifactUUID)
    #expect(json["title"]?.string == "Delta Rates")
    #expect(json["published"]?.int == 1000)
    #expect(json["updated"]?.int == 2000)
    #expect(json["removed"]?.int == 3000)
    #expect(json["session"]?.string == "s1")
    #expect(json["sessionName"]?.string == "alpha")
  }

  @Test func absorbingAppendsTheOtherGroupsKeptRows() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")
    let theirs = row(second, id: secondUUID, published: 2000, updated: 2000, session: "b", name: "bravo")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(merged.keptArtifacts == [mine, theirs])
  }

  @Test func absorbingIntoAGroupWithoutKeptRowsTakesTheOthers() {
    let theirs = row(published: 2000, updated: 2000, session: "b", name: "bravo")

    let merged = group("g1", "Flags").absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(merged.keptArtifacts == [theirs])
  }

  @Test func absorbingAGroupWithoutKeptRowsKeepsThisGroupsRows() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs"), now: 30)

    #expect(merged.keptArtifacts == [mine])
  }

  @Test func absorbingTwoGroupsWithoutKeptRowsKeepsNone() {
    let merged = group("g1", "Flags").absorbing(group("g2", "Docs"), now: 30)

    #expect((merged.keptArtifacts ?? []).isEmpty)
  }

  /// The merged rows list like the two groups' rows together.
  @Test func absorbingKeepsTheGroupListOfBothGroups() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")
    let theirs = row(published: 500, updated: 3000, session: "b", name: "bravo")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(list([], kept: merged.keptArtifacts ?? []) == list([], kept: [mine, theirs]))
  }
}
