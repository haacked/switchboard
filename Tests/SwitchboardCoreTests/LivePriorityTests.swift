import Foundation
import Testing

@testable import SwitchboardCore

/// A `livePriority` value in config.json and the list that sbd keeps from it.
struct PriorityValue: CustomTestStringConvertible, Sendable {
  var label: String
  var json: String
  var kept: [String]

  var testDescription: String { label }
}

private func value(_ label: String, _ json: String, kept: [String] = []) -> PriorityValue {
  PriorityValue(label: label, json: json, kept: kept)
}

/// The config that config.json holds with a cap of 35 and this `livePriority`.
private func config(livePriority json: String) throws -> Config {
  try JSONCoding.decode(Config.self, from: #"{"liveCap": 35, "livePriority": \#(json)}"#)
}

@Suite struct LivePriorityTests {
  // MARK: Rank

  @Test func anExactRepositoryEntryRanksItsRepository() {
    let priority = LivePriority(entries: ["PostHog/posthog"])

    #expect(priority.rank(of: "PostHog/posthog") == 1)
  }

  @Test func anOrgEntryRanksEachRepositoryOfTheOrg() {
    let priority = LivePriority(entries: ["PostHog"])

    #expect(priority.rank(of: "PostHog/other") == 1)
  }

  @Test func aRepositoryThatNoEntryMatchesIsUnranked() {
    let priority = LivePriority(entries: ["PostHog", "haacked/switchboard"])

    #expect(priority.rank(of: "acme/x") == 0)
  }

  @Test func aRepositoryEntryDoesNotRankOtherRepositoriesOfItsOrg() {
    let priority = LivePriority(entries: ["PostHog/posthog"])

    #expect(priority.rank(of: "PostHog/other") == 0)
  }

  @Test func anOrgEntryDoesNotRankARepositoryWhoseNameMatchesIt() {
    let priority = LivePriority(entries: ["posthog"])

    #expect(priority.rank(of: "haacked/posthog") == 0)
  }

  @Test func aNilRepositoryIsUnranked() {
    let priority = LivePriority(entries: ["PostHog", "PostHog/posthog"])

    #expect(priority.rank(of: nil) == 0)
  }

  @Test func anEmptyListRanksNothing() {
    let priority = LivePriority(entries: [])

    #expect(priority.rank(of: "PostHog/posthog") == 0)
  }

  @Test func earlierEntriesRankHigher() {
    let priority = LivePriority(entries: ["PostHog/posthog", "haacked/switchboard", "acme"])

    #expect(priority.rank(of: "PostHog/posthog") == 3)
    #expect(priority.rank(of: "haacked/switchboard") == 2)
    #expect(priority.rank(of: "acme/x") == 1)
  }

  @Test(arguments: [
    ("PostHog/posthog", "posthog/POSTHOG"), ("posthog/posthog", "PostHog/PostHog"), ("POSTHOG", "posthog/x"),
    ("posthog", "PostHog/x"),
  ])
  func matchingIgnoresCase(_ entry: String, _ repository: String) {
    let priority = LivePriority(entries: [entry])

    #expect(priority.rank(of: repository) == 1)
  }

  @Test func anExactEntryBeforeItsOrgRanksAtItsOwnPosition() {
    let priority = LivePriority(entries: ["PostHog/posthog", "PostHog"])

    #expect(priority.rank(of: "PostHog/posthog") == 2)
    #expect(priority.rank(of: "PostHog/other") == 1)
  }

  /// "Exact wins over org" holds even when the org comes first, so the exact
  /// repository ranks below its org's other repositories.
  @Test func anExactEntryAfterItsOrgStillWinsAtItsOwnPosition() {
    let priority = LivePriority(entries: ["PostHog", "PostHog/posthog"])

    #expect(priority.rank(of: "PostHog/posthog") == 1)
    #expect(priority.rank(of: "PostHog/other") == 2)
  }

  @Test func aDuplicateEntryKeepsItsFirstPosition() {
    let priority = LivePriority(entries: ["PostHog/posthog", "haacked/switchboard", "PostHog/posthog"])

    #expect(priority.rank(of: "PostHog/posthog") > priority.rank(of: "haacked/switchboard"))
  }

  @Test func aDuplicateEntryInAnotherCaseKeepsItsFirstPosition() {
    let priority = LivePriority(entries: ["PostHog", "haacked", "POSTHOG"])

    #expect(priority.rank(of: "PostHog/posthog") > priority.rank(of: "haacked/switchboard"))
  }

  // MARK: Entry

  @Test func theEntryOfARepositoryIsTheExactEntryAsWritten() {
    let priority = LivePriority(entries: ["PostHog", "PostHog/posthog"])

    #expect(priority.entry(of: "posthog/posthog") == "PostHog/posthog")
  }

  @Test func theEntryOfARepositoryWithoutAnExactEntryIsItsOrgEntry() {
    let priority = LivePriority(entries: ["PostHog"])

    #expect(priority.entry(of: "PostHog/other") == "PostHog")
  }

  @Test func anUnrankedRepositoryHasNoEntry() {
    let priority = LivePriority(entries: ["PostHog"])

    #expect(priority.entry(of: "acme/x") == nil)
  }

  @Test func aNilRepositoryHasNoEntry() {
    let priority = LivePriority(entries: ["PostHog"])

    #expect(priority.entry(of: nil) == nil)
  }

  // MARK: Config

  @Test func theDefaultIsAnEmptyList() {
    #expect(Config().livePriority == [])
  }

  @Test func anAbsentLivePriorityDecodesAsAnEmptyList() throws {
    let c = try JSONCoding.decode(Config.self, from: #"{"liveCap": 35}"#)

    #expect(c.livePriority == [])
  }

  @Test func aValidListDecodesInItsOrder() throws {
    let c = try config(livePriority: #"["PostHog/posthog", "PostHog", "haacked"]"#)

    #expect(c.livePriority == ["PostHog/posthog", "PostHog", "haacked"])
  }

  static let badValues: [PriorityValue] = [
    value("a string", #""PostHog""#),
    value("a number", "3"),
    value("a bool", "true"),
    value("an object", #"{"PostHog": 1}"#),
    value("null", "null"),
    value("an empty string", #""""#),
    value("a string with two slashes", #""a/b/c""#),
    value("an array holding a number", "[3]"),
    value("an array holding an empty string", #"[""]"#),
    value("an array holding a string with two slashes", #"["a/b/c"]"#),
    value("an array holding an array", #"[["PostHog"]]"#),
    value("an array holding null", "[null]"),
    value("a number before a valid entry", #"[3, "PostHog"]"#, kept: ["PostHog"]),
    value("an empty string before a valid entry", #"["", "PostHog"]"#, kept: ["PostHog"]),
    value("two slashes before a valid entry", #"["a/b/c", "PostHog/posthog"]"#, kept: ["PostHog/posthog"]),
    value("an object between valid entries", #"["PostHog", {"x": 1}, "haacked"]"#, kept: ["PostHog", "haacked"]),
  ]

  @Test(arguments: badValues)
  func aBadLivePriorityKeepsTheCapFromTheSameFile(_ bad: PriorityValue) throws {
    let c = try config(livePriority: bad.json)

    #expect(c.liveCap == 35)
  }

  @Test(arguments: badValues)
  func aBadLivePriorityKeepsOnlyItsValidEntries(_ bad: PriorityValue) throws {
    let c = try config(livePriority: bad.json)

    #expect(c.livePriority == bad.kept)
  }

  @Test func aBadLivePriorityKeepsTheOtherKeys() throws {
    let c = try JSONCoding.decode(
      Config.self, from: #"{"liveCap": 35, "idleStopSeconds": 60, "livePriority": 3, "branchPrefix": "haacked/"}"#)

    #expect(c.idleStopSeconds == 60)
    #expect(c.branchPrefix == "haacked/")
  }
}
