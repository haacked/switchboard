import Foundation
import Testing

@testable import SwitchboardCore

private enum WatchFx {
  /// D6: 3 days, spelled out so a change to `SlackWatch.windowMs` fails here.
  static let windowMs: Int64 = 3 * 24 * 60 * 60 * 1000
  static let t: Int64 = 1_794_960_000_000

  static func link(_ url: String = LinkFixtures.slackRoot, t: Int64 = t, id: String = "l1", by: LinkAuthor = .you)
    -> ExternalLink
  {
    ExternalLink(id: id, title: "Thread", url: url, by: by, t: t)
  }

  static func watched(_ link: ExternalLink, now: Int64, replyWaits: Set<String> = []) -> Bool {
    link.linkTarget.map { SlackWatch.isWatched(link, target: $0, now: now, replyWaits: replyWaits) } ?? false
  }

  static func keys(_ links: [ExternalLink], now: Int64, replyWaits: [SlackThreadRef] = []) -> [String] {
    SlackWatch.threads(links, now: now, replyWaits: replyWaits).map(\.key)
  }

  /// The thread of an open reply wait on the URL's thread. It fails the test when the URL names no Slack thread.
  static func ref(_ url: String) throws -> SlackThreadRef {
    try #require(LinkTarget.parse(url).flatMap(SlackThreadRef.init(target:)), "\(url) names no Slack thread")
  }
}

/// Risk 7: a link is watched exactly while `now < link.t + windowMs` or its key is in `replyWaits`.
@Suite struct SlackWatchTests {
  @Test func theWindowIsThreeDays() {
    #expect(SlackWatch.windowMs == WatchFx.windowMs)
  }

  // MARK: isWatched

  @Test func aLinkIsWatchedAtItsOwnTime() {
    #expect(WatchFx.watched(WatchFx.link(), now: WatchFx.t))
  }

  @Test func aLinkIsWatchedOneMsBeforeItsWindowEnds() {
    #expect(WatchFx.watched(WatchFx.link(), now: WatchFx.t + WatchFx.windowMs - 1))
  }

  @Test func aLinkIsNotWatchedWhenItsWindowEnds() {
    #expect(!WatchFx.watched(WatchFx.link(), now: WatchFx.t + WatchFx.windowMs))
  }

  @Test func aLinkIsNotWatchedOneMsAfterItsWindowEnds() {
    #expect(!WatchFx.watched(WatchFx.link(), now: WatchFx.t + WatchFx.windowMs + 1))
  }

  @Test func aReplyWaitOnItsThreadKeepsALinkWatchedPastItsWindow() {
    let late = WatchFx.t + 10 * WatchFx.windowMs

    #expect(WatchFx.watched(WatchFx.link(), now: late, replyWaits: [LinkFixtures.slackRootKey]))
  }

  @Test func aReplyLinksThreadKeyIsItsThreadsKey() {
    let late = WatchFx.t + WatchFx.windowMs

    #expect(WatchFx.watched(WatchFx.link(LinkFixtures.slackReply), now: late, replyWaits: [LinkFixtures.slackRootKey]))
  }

  @Test func aReplyWaitOnAnotherThreadDoesNotKeepALinkWatched() {
    let late = WatchFx.t + WatchFx.windowMs

    #expect(!WatchFx.watched(WatchFx.link(), now: late, replyWaits: [LinkFixtures.otherThreadKey]))
  }

  @Test(arguments: [
    LinkFixtures.linear, LinkFixtures.notion, LinkFixtures.google, LinkFixtures.grafana, "https://example.com/doc",
    LinkFixtures.githubPR,
  ])
  func aLinkThatIsNotSlackIsNotWatched(_ url: String) {
    #expect(!WatchFx.watched(WatchFx.link(url), now: WatchFx.t))
  }

  @Test func aLinkThatIsNotSlackIsNotWatchedEvenWithItsKeyInTheReplyWaits() throws {
    let key = try #require(LinkTarget.parse(LinkFixtures.linear)?.key)

    #expect(!WatchFx.watched(WatchFx.link(LinkFixtures.linear), now: WatchFx.t, replyWaits: [key]))
  }

  // MARK: threads

  @Test func aWatchedLinkGivesItsThreadsKeyChannelAndTs() throws {
    let refs = SlackWatch.threads([WatchFx.link(LinkFixtures.slackReply)], now: WatchFx.t, replyWaits: [])

    let ref = try #require(refs.first)
    #expect(refs.count == 1)
    #expect(ref.key == LinkFixtures.slackRootKey)
    #expect(ref.channel == LinkFixtures.channel)
    #expect(ref.thread == LinkFixtures.rootTs)
  }

  @Test func threadsLeaveOutLinksThatAreNotSlack() {
    let links = [WatchFx.link(LinkFixtures.linear, id: "l1"), WatchFx.link(LinkFixtures.slackRoot, id: "l2")]

    #expect(WatchFx.keys(links, now: WatchFx.t) == [LinkFixtures.slackRootKey])
  }

  @Test func threadsLeaveOutLinksPastTheirWindow() {
    let links = [
      WatchFx.link(LinkFixtures.slackRoot, t: WatchFx.t - WatchFx.windowMs), WatchFx.link(LinkFixtures.otherThread),
    ]

    #expect(WatchFx.keys(links, now: WatchFx.t) == [LinkFixtures.otherThreadKey])
  }

  @Test func threadsKeepALinkPastItsWindowThatAReplyWaitNames() throws {
    let links = [WatchFx.link(t: WatchFx.t - WatchFx.windowMs)]

    #expect(
      try WatchFx.keys(links, now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.slackRoot)]) == [
        LinkFixtures.slackRootKey
      ])
  }

  @Test func twoThreadsGiveTwoRefs() {
    let links = [WatchFx.link(id: "l1"), WatchFx.link(LinkFixtures.otherThread, id: "l2")]

    #expect(Set(WatchFx.keys(links, now: WatchFx.t)) == [LinkFixtures.slackRootKey, LinkFixtures.otherThreadKey])
  }

  // MARK: Reply waits' threads

  /// #504 D4: the poll reads a reply wait's thread even when no link lists it.
  @Test func aReplyWaitsThreadThatNoLinkListsIsReturned() throws {
    let refs = try SlackWatch.threads([], now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.otherThread)])

    #expect(try refs == [WatchFx.ref(LinkFixtures.otherThread)])
  }

  @Test func aReplyWaitsThreadThatNoLinkListsComesAfterTheLinksThreads() throws {
    let links = [WatchFx.link()]

    let keys = try WatchFx.keys(links, now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.otherThread)])

    #expect(keys == [LinkFixtures.slackRootKey, LinkFixtures.otherThreadKey])
  }

  @Test func aReplyWaitsThreadThatALinkListsIsReturnedOnce() throws {
    let links = [WatchFx.link(LinkFixtures.slackReply)]

    let keys = try WatchFx.keys(links, now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.slackRoot)])

    #expect(keys == [LinkFixtures.slackRootKey])
  }

  /// A link past its window that a reply wait keeps watched keeps its place among the links' threads, ahead of a
  /// later link inside its window.
  @Test func aLinkPastItsWindowThatAReplyWaitNamesKeepsItsPlaceAmongTheLinks() throws {
    let links = [
      WatchFx.link(LinkFixtures.slackRoot, t: WatchFx.t - WatchFx.windowMs, id: "l1"),
      WatchFx.link(LinkFixtures.otherThread, id: "l2"),
    ]

    let keys = try WatchFx.keys(links, now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.slackRoot)])

    #expect(keys == [LinkFixtures.slackRootKey, LinkFixtures.otherThreadKey])
  }

  @Test func aLinkPastItsWindowThatAReplyWaitNamesIsReturnedOnce() throws {
    let links = [WatchFx.link(LinkFixtures.slackReply, t: WatchFx.t - WatchFx.windowMs)]

    let keys = try WatchFx.keys(links, now: WatchFx.t, replyWaits: [WatchFx.ref(LinkFixtures.slackRoot)])

    #expect(keys == [LinkFixtures.slackRootKey])
  }

  @Test func replyWaitsThreadsThatNoLinkListsKeepTheirOrder() throws {
    let waits: [SlackThreadRef] = try [WatchFx.ref(LinkFixtures.otherThread), WatchFx.ref(LinkFixtures.slackRoot)]

    #expect(
      WatchFx.keys([], now: WatchFx.t, replyWaits: waits) == [LinkFixtures.otherThreadKey, LinkFixtures.slackRootKey])
  }

  /// The threads are one per thread key, so two reply waits on one thread give one read.
  @Test func twoReplyWaitsOnOneThreadGiveOneRef() throws {
    let waits: [SlackThreadRef] = try [WatchFx.ref(LinkFixtures.otherThread), WatchFx.ref(LinkFixtures.otherThread)]

    #expect(WatchFx.keys([], now: WatchFx.t, replyWaits: waits) == [LinkFixtures.otherThreadKey])
  }

  @Test func noReplyWaitsGiveOnlyTheLinksThreads() {
    let links = [WatchFx.link(id: "l1"), WatchFx.link(LinkFixtures.otherThread, t: WatchFx.t - WatchFx.windowMs)]

    #expect(WatchFx.keys(links, now: WatchFx.t, replyWaits: []) == [LinkFixtures.slackRootKey])
  }

  // MARK: Hidden links

  /// D5: a hidden link is not among the session's listed links, so nothing watches it.
  @Test func aHiddenFoundLinkIsNotWatched() {
    var s = Session(id: "s1", name: "one", cwd: "/tmp", claudeSessionId: "u1", created: 0)
    s.hiddenLinks = [LinkFixtures.slackReply]
    let found = [WatchFx.link(LinkFixtures.slackRoot, id: "fabcde", by: .found)]

    #expect(WatchFx.keys(s.links(found: found), now: WatchFx.t).isEmpty)
  }

  @Test func aFoundLinkThatIsNotHiddenIsWatched() {
    let s = Session(id: "s1", name: "one", cwd: "/tmp", claudeSessionId: "u1", created: 0)
    let found = [WatchFx.link(LinkFixtures.slackRoot, id: "fabcde", by: .found)]

    #expect(WatchFx.keys(s.links(found: found), now: WatchFx.t) == [LinkFixtures.slackRootKey])
  }

  // MARK: One thread in two sessions

  /// The root's link in one session and a reply's link in another name one thread, and sbd reads it once.
  @Test func oneThreadInTwoSessionsIsOneRef() {
    let links = [
      WatchFx.link(LinkFixtures.slackRoot, id: "l1"), WatchFx.link(LinkFixtures.slackReply, t: WatchFx.t + 5000),
    ]

    #expect(WatchFx.keys(links, now: WatchFx.t + 5000) == [LinkFixtures.slackRootKey])
  }

  @Test func oneThreadInTwoSessionsIsWatchedWhileTheNewerLinkIs() {
    let old = WatchFx.link(LinkFixtures.slackRoot, t: WatchFx.t - WatchFx.windowMs, id: "l1")
    let new = WatchFx.link(LinkFixtures.slackReply, t: WatchFx.t, id: "l2")

    #expect(WatchFx.keys([old, new], now: WatchFx.t + 1) == [LinkFixtures.slackRootKey])
    #expect(WatchFx.keys([new, old], now: WatchFx.t + 1) == [LinkFixtures.slackRootKey])
  }

  @Test func oneThreadInTwoSessionsStopsWhenBothWindowsEnd() {
    let old = WatchFx.link(LinkFixtures.slackRoot, t: WatchFx.t - WatchFx.windowMs, id: "l1")
    let new = WatchFx.link(LinkFixtures.slackReply, t: WatchFx.t, id: "l2")

    #expect(WatchFx.keys([old, new], now: WatchFx.t + WatchFx.windowMs).isEmpty)
  }
}
