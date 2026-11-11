import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct RepoPickerListTests {
  static let switchboard = KnownRepo(path: "/Users/me/dev/switchboard", name: "haacked/switchboard", used: 30)
  static let posthog = KnownRepo(path: "/Users/me/dev/posthog", name: "PostHog/posthog", used: 20)
  static let dotfiles = KnownRepo(path: "/Users/me/Work/dotfiles", name: "dotfiles", used: nil)
  static let repos = [switchboard, posthog, dotfiles]

  /// Every combination of Shift, Command, Option, and Control that has Command, Option, or Control.
  static let withCommandOptionOrControl = ReturnKeyTests.allModifiers.filter {
    !$0.isDisjoint(with: [.command, .option, .control])
  }

  func rows(_ filter: String, repos: [KnownRepo] = repos) -> [RepoPickerList.Row] {
    RepoPickerList(repos: repos, filter: filter).rows
  }

  // MARK: Rows

  @Test(arguments: ["", "   ", "\t"])
  func listsEveryRepoInOrderThenTheAddRow(filter: String) {
    #expect(
      rows(filter) == [.repo(Self.switchboard), .repo(Self.posthog), .repo(Self.dotfiles), .addFolder])
  }

  @Test(
    arguments: [
      ("HAACKED", [switchboard]),
      ("posthog/", [posthog]),
      ("work", [dotfiles]),
      ("WORK/DOT", [dotfiles]),
      ("me/dev", [switchboard, posthog]),
      ("O", [switchboard, posthog, dotfiles]),
      ("dev/switchboard", [switchboard]),
      ("haacked/switchboard", [switchboard]),
    ] as [(String, [KnownRepo])])
  func filtersByNameAndByPathWithoutCase(filter: String, matches: [KnownRepo]) {
    #expect(rows(filter) == matches.map { .repo($0) } + [.addFolder])
  }

  @Test(
    arguments: [
      ("dev hog", [posthog]),
      ("  hog \t dev  ", [posthog]),
      ("haacked dev", [switchboard]),
      ("dev o", [switchboard, posthog]),
      ("dev zzz", []),
      ("zzz dev", []),
      ("switchboard posthog", []),
    ] as [(String, [KnownRepo])])
  func everyTermOfTheFilterMustMatch(filter: String, matches: [KnownRepo]) {
    #expect(rows(filter) == matches.map { .repo($0) } + [.addFolder])
  }

  @Test(
    arguments: [
      ("/Users/me/dev", "/Users/me/dev", [switchboard, posthog]),
      ("  /Users/me/dev/posthog  ", "/Users/me/dev/posthog", [posthog]),
      ("~/dev/new", "~/dev/new", []),
      ("~", "~", []),
      ("/Volumes/My Disk/repo", "/Volumes/My Disk/repo", []),
    ] as [(String, String, [KnownRepo])])
  func aFilterThatStartsWithASlashOrTildeOffersToAddThatPathFirst(filter: String, path: String, matches: [KnownRepo]) {
    let list = RepoPickerList(repos: Self.repos, filter: filter)

    #expect(list.rows == [.addPath(path)] + matches.map { .repo($0) } + [.addFolder])
    #expect(list.initialHighlight == RepoPickerList.Row.addPath(path).id)
  }

  @Test(arguments: ["zzz", "switchboard-2", "haacked/posthog"])
  func aFilterWithNoMatchLeavesOnlyTheAddRow(filter: String) {
    #expect(rows(filter) == [.addFolder])
  }

  @Test(arguments: ["", "  ", "switchboard"])
  func anEmptyListHasOnlyTheAddRow(filter: String) {
    #expect(rows(filter, repos: []) == [.addFolder])
  }

  // MARK: Highlight

  @Test(arguments: ["", "dev", "/Users/me", "zzz"])
  func theHighlightStopsAtBothEnds(filter: String) throws {
    let list = RepoPickerList(repos: Self.repos, filter: filter)
    let ids = list.rows.map(\.id)
    let first = try #require(ids.first)
    let last = try #require(ids.last)

    let down = ids.dropLast().map { list.step(from: $0, by: 1) }
    let up = ids.dropFirst().map { list.step(from: $0, by: -1) }

    #expect(down == Array(ids.dropFirst()))
    #expect(up == Array(ids.dropLast()))
    #expect(list.step(from: first, by: -1) == first)
    #expect(list.step(from: last, by: 1) == last)
    #expect(last == RepoPickerList.Row.addFolder.id)
  }

  @Test func theInitialHighlightIsTheFirstRow() {
    let before = RepoPickerList(repos: Self.repos, filter: "")
    let narrowed = RepoPickerList(repos: Self.repos, filter: "o")
    let pasted = RepoPickerList(repos: Self.repos, filter: "/Users/me/Work")
    let unmatched = RepoPickerList(repos: Self.repos, filter: "zzz")
    let empty = RepoPickerList(repos: [], filter: "")

    #expect(before.initialHighlight == RepoPickerList.Row.repo(Self.switchboard).id)
    #expect(narrowed.rows.contains(.repo(Self.dotfiles)))
    #expect(narrowed.initialHighlight == RepoPickerList.Row.repo(Self.switchboard).id)
    #expect(pasted.initialHighlight == RepoPickerList.Row.addPath("/Users/me/Work").id)
    #expect(unmatched.initialHighlight == RepoPickerList.Row.addFolder.id)
    #expect(empty.initialHighlight == RepoPickerList.Row.addFolder.id)
    for list in [before, narrowed, pasted, unmatched, empty] {
      #expect(list.initialHighlight == list.rows.first?.id)
    }
  }

  // MARK: Keys on the closed control

  @Test(
    arguments: [
      ("a", []), ("z", []), ("7", []), ("/", []), ("~", []), ("-", []), (".", []), ("é", []), ("a", .capsLock),
      ("S", .shift), ("?", .shift),
    ] as [(Character, EventModifiers)])
  func aPlainCharacterOpensThePickerWithThatCharacter(_ character: Character, _ modifiers: EventModifiers) {
    #expect(RepoPickerList.opens(KeyEquivalent(character), modifiers: modifiers) == String(character))
  }

  /// macOS sends arrow keys with the numeric pad and function flags set.
  @Test(arguments: [EventModifiers(), .numericPad, .function, [.numericPad, .function]])
  func downAndSpaceOpenItEmpty(_ modifiers: EventModifiers) {
    #expect(RepoPickerList.opens(.downArrow, modifiers: modifiers) == "")
    #expect(RepoPickerList.opens(.space, modifiers: modifiers) == "")
  }

  static let keysThatTypeNothing: [KeyEquivalent] = [
    .return, .upArrow, .leftArrow, .rightArrow, .escape, .tab, .delete, .deleteForward, .home, .end, .pageUp,
    .pageDown, .clear,
  ]

  static let leftAlone: [(KeyEquivalent, EventModifiers)] =
    [KeyEquivalent("v"), KeyEquivalent("a"), KeyEquivalent("/"), .downArrow, .space, .return].flatMap { key in
      withCommandOptionOrControl.map { (key, $0) }
    }
    + keysThatTypeNothing.flatMap { key in
      [EventModifiers(), .shift, .capsLock, [.numericPad, .function]].map { (key, $0) }
    }

  @Test(arguments: leftAlone)
  func returnAndKeysWithModifiersDoNotOpenIt(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(RepoPickerList.opens(key, modifiers: modifiers) == nil)
  }
}
