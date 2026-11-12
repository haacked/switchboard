import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct KnownReposTests {
  @Test func mergesOneEntryPerPathAndKeepsTheLatestUse() {
    let entries = [
      KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 5),
      KnownRepo(path: "/dev/beta", name: "acme/beta", used: 6),
      KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 9),
      KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 7),
    ]

    let merged = KnownRepos.merge(entries)

    #expect(
      merged == [
        KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 9),
        KnownRepo(path: "/dev/beta", name: "acme/beta", used: 6),
      ])
  }

  @Test func ordersByMostRecentUseThenUnusedByNameThenPath() {
    let entries = [
      KnownRepo(path: "/dev/zebra", name: "Zebra", used: nil),
      KnownRepo(path: "/dev/old", name: "aaa/old", used: 10),
      KnownRepo(path: "/work/apple", name: "apple", used: nil),
      KnownRepo(path: "/dev/new", name: "zzz/new", used: 30),
      KnownRepo(path: "/dev/apple", name: "Apple", used: nil),
      KnownRepo(path: "/dev/mid", name: "mmm/mid", used: 20),
      KnownRepo(path: "/dev/banana", name: "banana", used: nil),
    ]

    let merged = KnownRepos.merge(entries)

    #expect(
      merged.map(\.path) == [
        "/dev/new", "/dev/mid", "/dev/old", "/dev/apple", "/work/apple", "/dev/banana", "/dev/zebra",
      ])
  }

  @Test func keepsTwoClonesOfOneRepositoryAsTwoEntries() {
    let entries = [
      KnownRepo(path: "/dev/widgets", name: "acme/widgets", used: 5),
      KnownRepo(path: "/dev/widgets-2", name: "acme/widgets", used: 8),
    ]

    let merged = KnownRepos.merge(entries)

    #expect(
      merged == [
        KnownRepo(path: "/dev/widgets-2", name: "acme/widgets", used: 8),
        KnownRepo(path: "/dev/widgets", name: "acme/widgets", used: 5),
      ])
    #expect(merged.map(\.id) == ["/dev/widgets-2", "/dev/widgets"])
  }

  @Test(arguments: [false, true])
  func anEntryWithAUseWinsOverTheSamePathWithout(unusedFirst: Bool) {
    let used = KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 1)
    let unused = KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: nil)

    let merged = KnownRepos.merge(unusedFirst ? [unused, used] : [used, unused])

    #expect(merged == [used])
  }

  // MARK: preferred

  static let alpha = KnownRepo(path: "/dev/alpha", name: "acme/alpha", used: 5)
  static let beta = KnownRepo(path: "/dev/beta", name: "acme/beta", used: 6)

  /// A work session in `group` whose main checkout is `checkout`, unless the test sets it otherwise.
  func session(
    _ id: String, group: String? = "g1", checkout: String?, repo: String? = nil, kind: SessionKind = .work
  ) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: checkout ?? "", repo: repo, branch: nil, claudeSessionId: id, state: .working,
      reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil,
      waits: [], notes: [])
    s.group = group
    s.checkout = checkout
    s.kind = kind
    return s
  }

  @Test func preferredPicksTheRepoMostOfTheGroupsSessionsUse() {
    let sessions = [
      session("s1", checkout: Self.beta.path),
      session("s2", checkout: Self.beta.path),
      session("s3", checkout: Self.alpha.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  @Test(arguments: [false, true], [false, true])
  func preferredBreaksATieByKnownOrder(alphaFirst: Bool, reversed: Bool) {
    let known = alphaFirst ? [Self.alpha, Self.beta] : [Self.beta, Self.alpha]
    let sessions = [session("s1", checkout: Self.beta.path), session("s2", checkout: Self.alpha.path)]
    let ordered = reversed ? Array(sessions.reversed()) : sessions

    let picked = KnownRepos.preferred(known, group: "g1", sessions: ordered)

    #expect(picked == known.first)
  }

  @Test func preferredIgnoresSessionsInOtherGroupsAndUngrouped() {
    let sessions = [
      session("s1", group: "g2", checkout: Self.alpha.path),
      session("s2", group: "g2", checkout: Self.alpha.path),
      session("s3", group: nil, checkout: Self.alpha.path),
      session("s4", group: "g1", checkout: Self.beta.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  @Test func preferredIgnoresAGroupChatAndTheManager() {
    let sessions = [
      session("c1", checkout: Self.alpha.path, kind: .chat),
      session("m1", checkout: Self.alpha.path, kind: .manager),
      session("s1", checkout: Self.beta.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  /// An unstarted follow-up has an empty cwd and no checkout.
  @Test func preferredIgnoresASessionWithoutACheckout() {
    let sessions = [
      session("s1", checkout: nil),
      session("s2", checkout: nil),
      session("s3", checkout: Self.beta.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  @Test func preferredIgnoresACheckoutThatIsNotKnown() {
    let sessions = [
      session("s1", checkout: "/dev/gamma"),
      session("s2", checkout: "/dev/gamma"),
      session("s3", checkout: Self.beta.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  /// The repo field can name another path than the checkout, so only the checkout counts.
  @Test func preferredMatchesTheCheckoutNotTheRepo() {
    let sessions = [
      session("s1", checkout: Self.beta.path, repo: Self.alpha.path),
      session("s2", checkout: Self.beta.path, repo: Self.alpha.path),
      session("s3", checkout: Self.alpha.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.beta)
  }

  @Test func preferredFallsBackToTheFirstKnownForAnEmptyGroup() {
    let sessions = [session("s1", group: "g2", checkout: Self.beta.path)]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: "g1", sessions: sessions)

    #expect(picked == Self.alpha)
  }

  @Test func preferredFallsBackToTheFirstKnownWithoutAGroup() {
    let sessions = [
      session("s1", group: "g1", checkout: Self.beta.path),
      session("s2", group: "g1", checkout: Self.beta.path),
    ]

    let picked = KnownRepos.preferred([Self.alpha, Self.beta], group: nil, sessions: sessions)

    #expect(picked == Self.alpha)
  }

  @Test func preferredIsNilWhenNothingIsKnown() {
    let sessions = [session("s1", checkout: Self.beta.path)]

    #expect(KnownRepos.preferred([], group: "g1", sessions: sessions) == nil)
  }
}
