import Foundation
import Testing

@testable import SwitchboardCore

private let root = LinkFixtures.slackRoot
private let reply = LinkFixtures.slackReply
private let rfc = "https://example.com/rfcs/flag-evaluations"
private let doc = "https://example.com/docs/cache-design"
private let now: Int64 = 1_000

/// A link that sbd found at `t`, with the id and title that `SessionFacts.applyLinks` gives it.
private func found(_ url: String, t: Int64, taken: [String] = []) throws -> ExternalLink {
  let target = try #require(LinkTarget.parse(url), "\(url) has no known kind")
  return ExternalLink(
    id: ExternalLink.foundId(key: target.key, taken: taken), title: target.title, url: url, by: .found, t: t)
}

private func added(_ id: String, _ url: String, by author: LinkAuthor = .you, t: Int64, title: String? = nil)
  -> ExternalLink
{
  ExternalLink(id: id, title: title ?? url, url: url, by: author, t: t)
}

private func linkSession(added: [ExternalLink]? = nil, hidden: [String]? = nil) -> Session {
  var s = Session(id: "s1", name: "flags-cache", cwd: "/a", claudeSessionId: "u1", created: 5)
  s.addedLinks = added
  s.hiddenLinks = hidden
  return s
}

extension LinkAdd {
  fileprivate var addedLink: ExternalLink? {
    if case .added(let link) = self { return link }
    return nil
  }

  fileprivate var unhidLink: ExternalLink? {
    if case .unhid(let link) = self { return link }
    return nil
  }
}

extension LinkRemoval {
  fileprivate var deletedLink: ExternalLink? {
    if case .deleted(let link) = self { return link }
    return nil
  }

  fileprivate var hidLink: ExternalLink? {
    if case .hid(let link) = self { return link }
    return nil
  }
}

/// Two URLs of one page, which `LinkTarget.parse` gives the same key.
struct SamePage: Sendable, CustomTestStringConvertible {
  var name: String
  var hidden: String
  var found: String

  var testDescription: String { name }

  static let all = [
    SamePage(name: "the same URL", hidden: root, found: root),
    SamePage(name: "a Slack reply against its thread's root", hidden: reply, found: root),
    SamePage(name: "a Slack root against a reply in its thread", hidden: root, found: reply),
    SamePage(
      name: "a Linear issue with and without its slug", hidden: "https://linear.app/example/issue/ENG-123",
      found: LinkFixtures.linear),
    SamePage(
      name: "a Notion page on notion.so and on a notion.site",
      hidden: "https://example.notion.site/Q4-Plan-\(LinkFixtures.hex)", found: LinkFixtures.notion),
    SamePage(
      name: "a Google Doc with an account and another action",
      hidden: "https://docs.google.com/document/u/0/d/\(LinkFixtures.googleId)/view", found: LinkFixtures.google),
    SamePage(
      name: "a Grafana dashboard with and without its slug and query",
      hidden: "https://grafana.example.com/d/abc123", found: LinkFixtures.grafana),
  ]
}

/// Where the id of a `link rm` points, in the fixture of `RemoveCase`.
enum LinkPlace: String, Sendable {
  case addedByYou, addedByClaude, listedFound, hiddenFound, shadowedFound, unknown
}

/// One row of the `link rm` table of Decision 6.
struct RemoveCase: Sendable, CustomTestStringConvertible {
  enum Outcome: Sendable {
    case deleted
    case hid
    /// The error holds the text.
    case refused(String)
  }

  var place: LinkPlace
  var by: Author
  var outcome: Outcome

  var testDescription: String { "\(by.rawValue) removes \(place.rawValue)" }

  static let all = [
    RemoveCase(place: .addedByYou, by: .you, outcome: .deleted),
    RemoveCase(place: .addedByClaude, by: .you, outcome: .deleted),
    RemoveCase(place: .listedFound, by: .you, outcome: .hid),
    RemoveCase(place: .hiddenFound, by: .you, outcome: .refused("has no link")),
    RemoveCase(place: .shadowedFound, by: .you, outcome: .refused("has no link")),
    RemoveCase(place: .unknown, by: .you, outcome: .refused("has no link")),
    RemoveCase(place: .addedByYou, by: .claude, outcome: .refused("Only you can remove a link you added")),
    RemoveCase(place: .addedByClaude, by: .claude, outcome: .deleted),
    RemoveCase(place: .listedFound, by: .claude, outcome: .refused("Only you can hide a link that Switchboard found")),
    RemoveCase(place: .hiddenFound, by: .claude, outcome: .refused("has no link")),
    RemoveCase(place: .shadowedFound, by: .claude, outcome: .refused("has no link")),
    RemoveCase(place: .unknown, by: .claude, outcome: .refused("has no link")),
  ]
}

/// The rules of a session's hand-added and hidden links, as pure functions on `Session`: the merged list that every
/// summary carries, `addLink`, and `removeLink`.
@Suite struct SessionLinkRulesTests {
  // MARK: The merged list

  @Test func withNeitherFieldTheListIsTheFoundLinksWithTheirIds() throws {
    let links = [try found(root, t: 10), try found(LinkFixtures.linear, t: 20)]

    #expect(linkSession().links(found: links) == links)
  }

  @Test func withNoFoundLinksTheListIsTheAddedLinks() {
    let mine = [added("lab2cd", rfc, t: 10), added("lef3gh", doc, by: .claude, t: 20)]

    #expect(linkSession(added: mine).links(found: []) == mine)
  }

  @Test func addedLinksInterleaveWithFoundLinksByTime() throws {
    let early = try found(root, t: 10)
    let late = try found(LinkFixtures.linear, t: 30)
    let s = linkSession(added: [added("lab2cd", rfc, t: 20), added("lef3gh", doc, t: 40)])

    let links = s.links(found: [early, late])

    #expect(links.map(\.id) == [early.id, "lab2cd", late.id, "lef3gh"])
  }

  @Test func anAddedLinkAfterEveryFoundLinkListsLast() throws {
    let f = [try found(root, t: 10), try found(LinkFixtures.linear, t: 20)]
    let s = linkSession(added: [added("lab2cd", rfc, t: 30)])

    #expect(s.links(found: f).map(\.id) == f.map(\.id) + ["lab2cd"])
  }

  @Test func aFoundLinkListsBeforeAnAddedLinkWithTheSameTime() throws {
    let f = try found(root, t: 10)
    let s = linkSession(added: [added("lab2cd", rfc, t: 10)])

    #expect(s.links(found: [f]).map(\.id) == [f.id, "lab2cd"])
  }

  @Test func addedLinksListInTimeOrderWhateverTheirStoredOrder() {
    let s = linkSession(added: [added("lef3gh", doc, t: 30), added("lab2cd", rfc, t: 20)])

    #expect(s.links(found: []).map(\.id) == ["lab2cd", "lef3gh"])
  }

  @Test func anAddedLinkWithAFoundLinksURLListsInsteadOfIt() throws {
    let f = try found(root, t: 10)
    let mine = added("lab2cd", root, t: 5)

    #expect(linkSession(added: [mine]).links(found: [f]) == [mine])
  }

  @Test(arguments: SamePage.all) func aHiddenURLLeavesOutTheFoundLinkOfTheSamePage(_ page: SamePage) throws {
    let f = try found(page.found, t: 10)

    #expect(linkSession(hidden: [page.hidden]).links(found: [f]).isEmpty)
  }

  @Test func aHiddenURLLeavesTheOtherFoundLinksListedWithTheirIds() throws {
    let slack = try found(root, t: 10)
    let linear = try found(LinkFixtures.linear, t: 20)

    #expect(linkSession(hidden: [reply]).links(found: [slack, linear]) == [linear])
  }

  /// Only found links are hidden. An added link of a hidden page, and an unrelated `web` link, stay listed.
  @Test func aHiddenURLLeavesEveryAddedLinkListed() throws {
    let f = try found(root, t: 10)
    let samePage = added("lab2cd", reply, t: 20)
    let web = added("lef3gh", rfc, t: 30)

    let links = linkSession(added: [samePage, web], hidden: [root]).links(found: [f])

    #expect(links == [samePage, web])
  }

  // MARK: Page keys

  @Test(arguments: SamePage.all) func twoURLsOfOnePageHaveOnePageKey(_ page: SamePage) {
    #expect(ExternalLink.pageKey(page.hidden) == ExternalLink.pageKey(page.found))
  }

  @Test func theReplyAndRootOfASlackThreadShareTheRootsKey() {
    #expect(ExternalLink.pageKey(reply) == LinkFixtures.slackRootKey)
  }

  @Test func aWebURLsPageKeyIsTheURL() {
    #expect(ExternalLink.pageKey(rfc) == rfc)
    #expect(ExternalLink.pageKey(rfc) != ExternalLink.pageKey(doc))
  }

  @Test func anArtifactLinksPageKeyIsItsNormalizedForm() {
    #expect(ExternalLink.pageKey("\(artifactShortURL)#top") == artifactShortURL)
  }

  // MARK: Add

  @Test func anAddByYouAppendsALinkByYouWithItsTitleAndTheTime() throws {
    var s = linkSession()

    let result = try s.addLink(url: rfc, title: "Flag RFC", by: .you, found: [], now: now)

    let link = try #require(result.addedLink)
    #expect(link.url == rfc)
    #expect(link.title == "Flag RFC")
    #expect(link.by == .you)
    #expect(link.t == now)
    #expect(link.id.hasPrefix("l"))
    #expect(s.addedLinks == [link])
    #expect(s.hiddenLinks == nil)
  }

  @Test func anAddByClaudeOfAPageThatIsNotHiddenIsByClaude() throws {
    var s = linkSession(hidden: [root])

    let result = try s.addLink(url: rfc, title: "Flag RFC", by: .claude, found: [try found(root, t: 1)], now: now)

    let link = try #require(result.addedLink)
    #expect(link.by == .claude)
    #expect(link.title == "Flag RFC")
    #expect(s.addedLinks == [link])
  }

  @Test(arguments: [nil, "", "  \n "]) func withoutATitleTheTitleIsTheURL(_ title: String?) throws {
    var s = linkSession()

    let link = try #require(try s.addLink(url: rfc, title: title, by: .you, found: [], now: now).addedLink)

    #expect(link.title == rfc)
  }

  @Test func aLongURLWithoutATitleIsCutWithAnEllipsisForTheTitle() throws {
    let url = GroupLinkTests.url(ofLength: ExternalLink.titleLimit + 1)
    var s = linkSession()

    let link = try #require(try s.addLink(url: url, title: nil, by: .you, found: [], now: now).addedLink)

    #expect(link.url == url)
    #expect(link.title.count == ExternalLink.titleLimit)
    #expect(link.title.hasSuffix("…"))
  }

  @Test func aTitleIsCollapsedToOneLine() throws {
    var s = linkSession()

    let result = try s.addLink(url: rfc, title: "Flag\n  evaluations\tRFC ", by: .you, found: [], now: now)

    #expect(result.addedLink?.title == "Flag evaluations RFC")
  }

  @Test func aTitleOfExactlyTheLimitIsKept() throws {
    let title = String(repeating: "a", count: ExternalLink.titleLimit)
    var s = linkSession()

    let result = try s.addLink(url: rfc, title: title, by: .you, found: [], now: now)

    #expect(result.addedLink?.title == title)
  }

  @Test(arguments: [Author.you, .claude]) func aTitleOverTheLimitIsRefusedAndChangesNothing(_ by: Author) {
    let title = String(repeating: "a", count: ExternalLink.titleLimit + 1)
    var s = linkSession(added: [added("lab2cd", doc, t: 1)])
    let before = s

    let message = refusal { _ = try s.addLink(url: rfc, title: title, by: by, found: [], now: now) }

    #expect(message?.contains("\(ExternalLink.titleLimit)") == true, "\(message ?? "no error")")
    #expect(s == before)
  }

  @Test(arguments: [
    ("http://example.com/rfc", LinkKind.web), (rfc, .web), (root, .slack), (reply, .slack),
    (LinkFixtures.linear, .linear), (LinkFixtures.notion, .notion), (LinkFixtures.google, .google),
    (LinkFixtures.grafana, .grafana), (artifactShortURL, .web),
  ])
  func anAddedLinkHasTheKindOfItsURL(_ url: String, _ kind: LinkKind) throws {
    var s = linkSession()

    let link = try #require(try s.addLink(url: url, title: nil, by: .you, found: [], now: now).addedLink)

    #expect(link.kind == kind)
  }

  /// A host check of the whole host name keeps a look-alike from passing as Slack.
  @Test func aLookAlikeSlackHostIsAddedAsWebWithTheURLAsItsTitle() throws {
    let url = "https://example.slack.com.evil.example/archives/\(LinkFixtures.channel)/\(LinkFixtures.rootP)"
    var s = linkSession()

    let link = try #require(try s.addLink(url: url, title: nil, by: .claude, found: [], now: now).addedLink)

    #expect(link.kind == .web)
    #expect(link.title == url)
  }

  @Test func theURLIsStoredTrimmedAndAnArtifactLinkNormalized() throws {
    var s = linkSession()

    let result = try s.addLink(url: "  \(artifactShortURL)#top \n", title: nil, by: .you, found: [], now: now)

    #expect(result.addedLink?.url == artifactShortURL)
    #expect(s.addedLinks?.map(\.url) == [artifactShortURL])
  }

  @Test(arguments: [
    nil, "", "ftp://example.com/file", "javascript:alert(1)", "example.com", "https://exa mple.com",
    "https://user:pass@example.com/", "https://user@example.com",
    "https://example.slack.com@evil.example/archives/C0EXAMPLE01/p1794965000000100",
  ])
  func anAddOfAURLThatCleanURLRefusesChangesNothing(_ url: String?) {
    var s = linkSession(added: [added("lab2cd", doc, t: 1)], hidden: [root])
    let before = s

    let message = refusal { _ = try s.addLink(url: url, title: nil, by: .you, found: [], now: now) }

    #expect(message != nil, "\(url ?? "nil")")
    #expect(s == before)
  }

  @Test(arguments: [Author.you, .claude]) func anAddOfAListedFoundLinksURLIsRefusedAndNamesIt(_ by: Author) throws {
    let f = try found(root, t: 10)
    var s = linkSession()
    let before = s

    let message = refusal { _ = try s.addLink(url: root, title: nil, by: by, found: [f], now: now) } ?? "no error"

    #expect(message.contains("flags-cache already has a link to \(root)"), "\(message)")
    #expect(message.contains(f.id), "\(message)")
    #expect(s == before)
  }

  @Test(arguments: [Author.you, .claude]) func anAddOfAnAddedLinksURLIsRefusedAndNamesIt(_ by: Author) {
    var s = linkSession(added: [added("lab2cd", rfc, by: .claude, t: 10)])
    let before = s

    let message = refusal { _ = try s.addLink(url: rfc, title: "Again", by: by, found: [], now: now) } ?? "no error"

    #expect(message.contains("already has a link"), "\(message)")
    #expect(message.contains("lab2cd"), "\(message)")
    #expect(s == before)
  }

  @Test(arguments: [Author.you, .claude]) func anAddOfAnotherFormOfAnAddedArtifactLinkIsRefused(_ by: Author) {
    var s = linkSession(added: [added("lab2cd", artifactShortURL, t: 10)])
    let before = s

    let message = refusal { _ = try s.addLink(url: "\(artifactShortURL)#top", title: nil, by: by, found: [], now: now) }

    #expect(message?.contains("already has a link") == true, "\(message ?? "no error")")
    #expect(s == before)
  }

  /// A duplicate is the same target, not the same page, so a second reply in a listed thread is its own link.
  @Test(arguments: [Author.you, .claude]) func anAddOfAnotherURLOfAListedFoundLinksPageIsAdded(_ by: Author) throws {
    let f = try found(root, t: 10)
    var s = linkSession()

    let link = try #require(try s.addLink(url: reply, title: nil, by: by, found: [f], now: now).addedLink)

    #expect(link.url == reply)
    #expect(s.links(found: [f]).map(\.id) == [f.id, link.id])
  }

  /// `addLink` takes no generator, so the test adds many links and checks every id it gets.
  @Test func everyNewIdStartsWithLAndDiffersFromEveryTakenId() throws {
    let f = [try found(root, t: 1), try found(LinkFixtures.linear, t: 2), try found(LinkFixtures.notion, t: 3)]
    var s = linkSession(added: [added("lab2cd", rfc, t: 4), added("lef3gh", doc, t: 5)])

    var ids: [String] = []
    for i in 0..<100 {
      let result = try s.addLink(url: "https://example.com/pages/\(i)", title: nil, by: .you, found: f, now: now)
      ids.append(try #require(result.addedLink).id)
    }

    let taken = Set(f.map(\.id) + ["lab2cd", "lef3gh"])
    #expect(ids.allSatisfy { $0.hasPrefix("l") && $0.count == 6 }, "\(ids)")
    #expect(Set(ids).count == ids.count)
    #expect(taken.isDisjoint(with: ids))
    #expect(Set(s.addedLinks?.map(\.id) ?? []) == Set(ids).union(["lab2cd", "lef3gh"]))
  }

  // MARK: Add of a hidden page

  @Test func yourAddOfAHiddenFoundLinksURLUnhidesItWithItsFoundId() throws {
    let f = try found(root, t: 10)
    var s = linkSession(hidden: [root])

    let result = try s.addLink(url: root, title: "Ignored", by: .you, found: [f], now: now)

    #expect(result.unhidLink == f)
    #expect(result.addedLink == nil)
    #expect(s.addedLinks == nil)
    #expect(s.hiddenLinks == nil)
    #expect(s.links(found: [f]) == [f])
  }

  @Test func yourUnhideTakesOffEveryHiddenURLOfThatPageAndNoOther() throws {
    let slack = try found(root, t: 10)
    let linear = try found(LinkFixtures.linear, t: 20)
    var s = linkSession(hidden: [reply, LinkFixtures.linear, root])

    let result = try s.addLink(url: root, title: nil, by: .you, found: [slack, linear], now: now)

    #expect(result.unhidLink?.id == slack.id)
    #expect(s.hiddenLinks == [LinkFixtures.linear])
    #expect(s.links(found: [slack, linear]) == [slack])
  }

  @Test func yourAddOfAnotherURLOfAHiddenPageAddsALinkAndKeepsThePageHidden() throws {
    let f = try found(root, t: 10)
    var s = linkSession(hidden: [root])

    let result = try s.addLink(url: reply, title: nil, by: .you, found: [f], now: now)

    let link = try #require(result.addedLink)
    #expect(link.url == reply)
    #expect(link.by == .you)
    #expect(link.id.hasPrefix("l"))
    #expect(s.hiddenLinks == [root])
    #expect(s.links(found: [f]) == [link])
  }

  @Test(arguments: [root, reply]) func claudesAddOfAHiddenPageIsRefusedAndChangesNothing(_ url: String) throws {
    let f = try found(root, t: 10)
    var s = linkSession(hidden: [root])
    let before = s

    let message = refusal { _ = try s.addLink(url: url, title: nil, by: .claude, found: [f], now: now) } ?? "no error"

    #expect(message.contains("The user hid a link to this page"), "\(message)")
    #expect(message.contains("sb link add"), "\(message)")
    #expect(s == before)
  }

  // MARK: Remove

  /// Found: a listed Slack link, a hidden Linear link, and a Google link that a hand link to the same URL shadows.
  /// Added: a link by you, a link by Claude, and the shadowing link.
  private func removeFixture() throws -> (session: Session, found: [ExternalLink], ids: [LinkPlace: String]) {
    let slack = try found(root, t: 10)
    let linear = try found(LinkFixtures.linear, t: 20)
    let google = try found(LinkFixtures.google, t: 25)
    let s = linkSession(
      added: [
        added("lab2cd", rfc, by: .you, t: 30), added("lef3gh", doc, by: .claude, t: 40),
        added("ljk4mn", LinkFixtures.google, by: .you, t: 50),
      ], hidden: [LinkFixtures.linear])
    let ids: [LinkPlace: String] = [
      .addedByYou: "lab2cd", .addedByClaude: "lef3gh", .listedFound: slack.id, .hiddenFound: linear.id,
      .shadowedFound: google.id, .unknown: "lnope2",
    ]
    return (s, [slack, linear, google], ids)
  }

  @Test(arguments: RemoveCase.all) func removeFollowsTheTableOfDecision6(_ row: RemoveCase) throws {
    let fixture = try removeFixture()
    var s = fixture.session
    let before = s
    let id = try #require(fixture.ids[row.place])

    switch row.outcome {
    case .deleted:
      let removal = try s.removeLink(id: id, by: row.by, found: fixture.found)
      #expect(removal.deletedLink?.id == id)
      #expect(s.addedLinks?.map(\.id) == before.addedLinks?.map(\.id).filter { $0 != id })
      #expect(s.hiddenLinks == before.hiddenLinks)
    case .hid:
      let removal = try s.removeLink(id: id, by: row.by, found: fixture.found)
      let link = try #require(removal.hidLink)
      #expect(link.id == id)
      #expect(s.hiddenLinks == (before.hiddenLinks ?? []) + [link.url])
      #expect(s.addedLinks == before.addedLinks)
      #expect(!s.links(found: fixture.found).contains { $0.id == id })
    case .refused(let text):
      let message = refusal { _ = try s.removeLink(id: id, by: row.by, found: fixture.found) } ?? "no error"
      #expect(message.contains(text), "\(message)")
      #expect(s == before)
    }
  }

  @Test(arguments: [Author.you, .claude]) func anUnknownIdsRefusalNamesTheSessionAndTheId(_ by: Author) {
    var s = linkSession(added: [added("lab2cd", rfc, t: 1)])

    let message = refusal { _ = try s.removeLink(id: "lnope2", by: by, found: []) } ?? "no error"

    #expect(message.contains("flags-cache has no link lnope2"), "\(message)")
  }

  @Test(arguments: [Author.you, .claude]) func aPrefixOfALinkIdIsRefused(_ by: Author) throws {
    let f = try found(root, t: 10)
    var s = linkSession(added: [added("lab2cd", rfc, by: .claude, t: 1)])
    let before = s

    for id in ["lab2c", String(f.id.dropLast()), "LAB2CD", "lab2cd "] {
      let message = refusal { _ = try s.removeLink(id: id, by: by, found: [f]) }
      #expect(message?.contains("has no link") == true, "\(id): \(message ?? "no error")")
    }

    #expect(s == before)
  }

  /// The hand link kept the found link off the list, so deleting it alone would bring the found link back.
  @Test(arguments: [LinkAuthor.you, .claude])
  func yourDeleteOfAHandLinkThatShadowsAFoundLinkHidesTheFoundLinkToo(_ author: LinkAuthor) throws {
    let f = try found(root, t: 10)
    var s = linkSession(added: [added("lab2cd", root, by: author, t: 20)])

    let removal = try s.removeLink(id: "lab2cd", by: .you, found: [f])

    #expect(removal.deletedLink?.id == "lab2cd")
    #expect(s.addedLinks == nil)
    #expect(s.hiddenLinks == [root])
    #expect(s.links(found: [f]).isEmpty)
  }

  /// Claude never hides a link, so the found link that its link shadowed lists again.
  @Test func claudesDeleteOfItsLinkThatShadowsAFoundLinkBringsTheFoundLinkBack() throws {
    let f = try found(root, t: 10)
    var s = linkSession(added: [added("lab2cd", root, by: .claude, t: 20)])

    let removal = try s.removeLink(id: "lab2cd", by: .claude, found: [f])

    #expect(removal.deletedLink?.id == "lab2cd")
    #expect(s.addedLinks == nil)
    #expect(s.hiddenLinks == nil)
    #expect(s.links(found: [f]) == [f])
  }

  @Test func deletingTheLastAddedLinkLeavesAddedLinksNil() throws {
    var s = linkSession(added: [added("lab2cd", rfc, t: 1)])

    _ = try s.removeLink(id: "lab2cd", by: .you, found: [])

    #expect(s.addedLinks == nil)
  }

  @Test func hidingAFoundLinkAppendsItsURLAndKeepsTheOtherFoundIds() throws {
    let slack = try found(reply, t: 10)
    let linear = try found(LinkFixtures.linear, t: 20)
    let notion = try found(LinkFixtures.notion, t: 30)
    var s = linkSession(hidden: [LinkFixtures.linear])

    let removal = try s.removeLink(id: slack.id, by: .you, found: [slack, linear, notion])

    #expect(removal.hidLink == slack)
    #expect(s.hiddenLinks == [LinkFixtures.linear, reply])
    #expect(s.links(found: [slack, linear, notion]) == [notion])
  }

  /// Hiding and then adding the URL back, as the user, returns the session to where it started.
  @Test func aHideThenAnUnhideLeavesBothFieldsNil() throws {
    let f = try found(root, t: 10)
    var s = linkSession()

    _ = try s.removeLink(id: f.id, by: .you, found: [f])
    _ = try s.addLink(url: root, title: nil, by: .you, found: [f], now: now)

    #expect(s == linkSession())
  }

  // MARK: Storage

  @Test func aSessionRowFromBeforeTheseFieldsDecodesWithNeither() throws {
    let row = #"{"id":"s1","name":"one","cwd":"/a","claudeSessionId":"u1","created":5,"started":true,"done":false}"#

    let s = try JSONCoding.decode(Session.self, from: row)

    #expect(s.addedLinks == nil)
    #expect(s.hiddenLinks == nil)
  }

  @Test func aSessionWithNeitherFieldEncodesNeitherKey() throws {
    let keys = try #require(try JSON(encoding: linkSession()).object?.keys)

    #expect(!keys.contains("addedLinks"))
    #expect(!keys.contains("hiddenLinks"))
  }

  @Test func aSessionWithAddedAndHiddenLinksSurvivesEncoding() throws {
    let s = linkSession(
      added: [added("lab2cd", reply, by: .you, t: 7, title: "Thread"), added("lef3gh", rfc, by: .claude, t: 9)],
      hidden: [root, LinkFixtures.linear])

    let decoded = try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s))

    #expect(decoded == s)
  }

  /// The stored row writes the derived keys as every encoded link does, and decoding ignores them.
  @Test func aStoredAddedSlackLinkCarriesItsKindAndThread() throws {
    let s = linkSession(added: [added("lab2cd", reply, t: 7)])

    let link = try #require(try JSON(encoding: s)["addedLinks"]?.array?.first)

    #expect(link["kind"]?.string == "slack")
    #expect(link["thread"]?.string == LinkFixtures.rootTs)
  }
}
