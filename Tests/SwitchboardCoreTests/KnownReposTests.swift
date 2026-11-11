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
}
