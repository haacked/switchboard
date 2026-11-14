import Foundation
import Testing

@testable import SwitchboardCore

func addDirectories(_ directories: JSON = ["/w/data"], destination: JSON = "session") -> JSON {
  ["type": "addDirectories", "directories": directories, "destination": destination]
}

func addRules(
  _ rules: JSON = [["toolName": "Bash", "ruleContent": "npm test:*"]], behavior: JSON = "allow",
  destination: JSON = "localSettings"
) -> JSON {
  ["type": "addRules", "rules": rules, "behavior": behavior, "destination": destination]
}

func setMode(_ mode: JSON = "acceptEdits", destination: JSON = "session") -> JSON {
  ["type": "setMode", "mode": mode, "destination": destination]
}

/// The entry with one more field.
func adding(_ entry: JSON, _ key: String, _ value: JSON) -> JSON {
  var fields = entry.object ?? [:]
  fields[key] = value
  return .object(fields)
}

/// A held card for the write-restart.json request with other suggestions, or
/// with none when `suggestions` is nil. Its id is 3.
func suggestionCard(_ suggestions: JSON?, mode: String = "default") throws -> Card {
  var data = try #require(try eventFixture("write-restart").object)
  data["permission_suggestions"] = suggestions
  data["permission_mode"] = .string(mode)
  let request = Event(id: 3, session: "s1", t: 2, kind: "PermissionRequest", data: .object(data))
  return try #require(SessionReplay.replaying([request], session: session()).facts.cards.first)
}

/// The words that `AlwaysAllow.describe` uses for each destination.
let destinationWords: [(String, String)] = [
  ("session", "for this session"),
  ("localSettings", "in this project's local settings, .claude/settings.local.json"),
  ("projectSettings", "in this project's shared settings, .claude/settings.json"),
  ("userSettings", "in your user settings, ~/.claude/settings.json"),
]

@Suite struct AlwaysAllowDescribe {
  @Test func theWriteRestartSuggestionsNameBothDirectoriesForThisSession() throws {
    let suggestions = try #require(try eventFixture("write-restart")["permission_suggestions"])
    let directories = suggestions.array?.first?["directories"]?.array?.compactMap(\.string) ?? []
    try #require(directories.count == 2)

    let text = AlwaysAllow.describe(suggestions)

    #expect(text == "Always allow access to \(directories[0]) and \(directories[1]) for this session")
  }

  @Test func oneDirectoryIsDescribed() {
    #expect(AlwaysAllow.describe([addDirectories()]) == "Always allow access to /w/data for this session")
  }

  @Test(arguments: destinationWords)
  func aDirectoryNamesItsDestination(_ destination: String, _ words: String) {
    let text = AlwaysAllow.describe([addDirectories(destination: .string(destination))])

    #expect(text == "Always allow access to /w/data \(words)")
  }

  @Test(arguments: destinationWords)
  func anAllowRuleNamesItsDestination(_ destination: String, _ words: String) {
    #expect(AlwaysAllow.describe([addRules(destination: .string(destination))])?.contains(words) == true)
  }

  @Test(arguments: destinationWords)
  func aModeNamesItsDestination(_ destination: String, _ words: String) {
    #expect(AlwaysAllow.describe([setMode(destination: .string(destination))])?.contains(words) == true)
  }

  @Test func anAllowRuleWithOnlyAToolNameNamesTheTool() throws {
    let text = try #require(AlwaysAllow.describe([addRules([["toolName": "WebSearch"]])]))

    #expect(text.contains("WebSearch"))
  }

  @Test func anAllowRuleWithContentNamesTheToolAndTheContent() throws {
    let text = try #require(AlwaysAllow.describe([addRules([["toolName": "Bash", "ruleContent": "npm test:*"]])]))

    #expect(text.contains("Bash"))
    #expect(text.contains("npm test:*"))
  }

  @Test func everyRuleOfAnAllowIsNamed() throws {
    let rules: JSON = [
      ["toolName": "Bash", "ruleContent": "make lint"], ["toolName": "WebFetch", "ruleContent": "domain:example.com"],
    ]

    let text = try #require(AlwaysAllow.describe([addRules(rules)]))

    for part in ["Bash", "make lint", "WebFetch", "domain:example.com"] { #expect(text.contains(part)) }
  }

  @Test func aModeNamesTheMode() throws {
    #expect(try #require(AlwaysAllow.describe([setMode("acceptEdits")])).contains("acceptEdits"))
  }

  @Test(arguments: ["/w/my notes", "/w/say \"hi\"", "/w/back\\slash", "/w/caf\u{E9}/\u{1F4C1}", "/w/null", "/w/42"])
  func aDirectoryShowsExactlyAsTheRequestWroteIt(_ directory: String) throws {
    let text = try #require(AlwaysAllow.describe([addDirectories([.string(directory)])]))

    #expect(text.contains(directory))
  }

  @Test func severalSuggestionsDescribeEachOne() throws {
    let first = addDirectories(["/w/data"])
    let second = addRules([["toolName": "Bash", "ruleContent": "make lint"]], destination: "projectSettings")
    let one = try #require(AlwaysAllow.describe([first]))
    let two = try #require(AlwaysAllow.describe([second]))

    let both = try #require(AlwaysAllow.describe([first, second]))

    #expect(both.contains(one))
    #expect(both.contains(two))
  }

  @Test func threeKindsOfSuggestionDescribeEachOne() throws {
    let all: [JSON] = [addDirectories(), addRules(), setMode()]
    let parts = try all.map { try #require(AlwaysAllow.describe([$0])) }

    let text = try #require(AlwaysAllow.describe(.array(all)))

    for part in parts { #expect(text.contains(part)) }
  }

  // MARK: Undescribable suggestions

  @Test func noSuggestionsAreUndescribable() {
    #expect(AlwaysAllow.describe(nil) == nil)
    #expect(AlwaysAllow.describe(.null) == nil)
  }

  @Test func anEmptyListIsUndescribable() {
    #expect(AlwaysAllow.describe([]) == nil)
  }

  @Test(arguments: [JSON.object(["type": "addDirectories"]), "addDirectories", 1, true])
  func suggestionsThatAreNotAListAreUndescribable(_ suggestions: JSON) {
    #expect(AlwaysAllow.describe(suggestions) == nil)
  }

  @Test(arguments: [JSON.string("addDirectories"), 1, .null, []])
  func anEntryThatIsNotAnObjectIsUndescribable(_ entry: JSON) {
    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test(arguments: [JSON.string("deny"), "ask", "Allow", "", 1, .null])
  func aRuleWhoseBehaviorIsNotAllowIsUndescribable(_ behavior: JSON) {
    #expect(AlwaysAllow.describe([addRules(behavior: behavior)]) == nil)
  }

  @Test func aRuleWithoutABehaviorIsUndescribable() {
    var entry = addRules().object ?? [:]
    entry["behavior"] = nil

    #expect(AlwaysAllow.describe([.object(entry)]) == nil)
  }

  @Test(arguments: ["replaceRules", "removeRules", "removeDirectories", "AddDirectories", "addRule", "", "unknownType"])
  func aTypeOutsideTheAllowListIsUndescribable(_ type: String) {
    let entry: JSON = [
      "type": .string(type), "rules": [["toolName": "Bash"]], "behavior": "allow", "directories": ["/w/data"],
      "mode": "acceptEdits", "destination": "session",
    ]

    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test func anEntryWithoutATypeIsUndescribable() {
    let entry: JSON = ["directories": ["/w/data"], "destination": "session"]

    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test(arguments: [JSON.string("cliArg"), "flagSettings", "policySettings", "Session", "", 1, .null])
  func aDestinationOutsideTheAllowListIsUndescribable(_ destination: JSON) {
    #expect(AlwaysAllow.describe([addDirectories(destination: destination)]) == nil)
    #expect(AlwaysAllow.describe([addRules(destination: destination)]) == nil)
    #expect(AlwaysAllow.describe([setMode(destination: destination)]) == nil)
  }

  @Test(arguments: [addDirectories(), addRules(), setMode()])
  func anEntryWithoutADestinationIsUndescribable(_ entry: JSON) {
    var fields = entry.object ?? [:]
    fields["destination"] = nil

    #expect(AlwaysAllow.describe([.object(fields)]) == nil)
  }

  @Test func addDirectoriesWithoutDirectoriesIsUndescribable() {
    let entry: JSON = ["type": "addDirectories", "destination": "session"]

    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test(arguments: [JSON.array([]), "/w/data", .null, ["path": "/w/data"]])
  func directoriesThatAreNotAListOfPathsAreUndescribable(_ directories: JSON) {
    #expect(AlwaysAllow.describe([addDirectories(directories)]) == nil)
  }

  @Test(arguments: [JSON.array([42]), [.null], [true], [["path": "/w/data"]], ["/w/data", 42], [42, "/w/data"]])
  func aDirectoryThatIsNotAStringIsUndescribable(_ directories: JSON) {
    #expect(AlwaysAllow.describe([addDirectories(directories)]) == nil)
  }

  @Test func addRulesWithoutRulesIsUndescribable() {
    let entry: JSON = ["type": "addRules", "behavior": "allow", "destination": "localSettings"]

    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test(arguments: [JSON.array([]), "Bash", .null, ["toolName": "Bash"]])
  func rulesThatAreNotAListOfRulesAreUndescribable(_ rules: JSON) {
    #expect(AlwaysAllow.describe([addRules(rules)]) == nil)
  }

  @Test(arguments: [
    JSON.array([["ruleContent": "npm test:*"]]), [["toolName": 1]], [["toolName": .null]], [["toolName": ["Bash"]]],
    [["toolName": "Bash", "ruleContent": 1]], [["toolName": "Bash", "ruleContent": .null]],
    [["toolName": "Bash", "ruleContent": ["npm test"]]], ["Bash"], [["toolName": "Bash"], ["toolName": 1]],
    [["toolName": 1], ["toolName": "Bash"]],
  ])
  func aRuleWithoutAStringToolNameOrWithNonStringContentIsUndescribable(_ rules: JSON) {
    #expect(AlwaysAllow.describe([addRules(rules)]) == nil)
  }

  @Test(arguments: [JSON.number(1), .null, true, ["acceptEdits"]])
  func aModeThatIsNotAStringIsUndescribable(_ mode: JSON) {
    #expect(AlwaysAllow.describe([setMode(mode)]) == nil)
  }

  @Test func setModeWithoutAModeIsUndescribable() {
    let entry: JSON = ["type": "setMode", "destination": "session"]

    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  /// sbd sends each entry unchanged, so a key the description leaves out could change what the allow applies.
  @Test(arguments: [
    adding(addDirectories(), "rules", [["toolName": "Bash"]]), adding(addDirectories(), "mode", "acceptEdits"),
    adding(addDirectories(), "behavior", "allow"), adding(addRules(), "directories", ["/w/data"]),
    adding(addRules(), "mode", "auto"), adding(setMode(), "directories", ["/w/data"]),
    adding(setMode(), "rules", [["toolName": "Bash"]]), adding(setMode(), "behavior", "allow"),
    adding(addDirectories(), "recursive", true), adding(addRules(), "note", "x"), adding(setMode(), "scope", "global"),
  ])
  func anEntryWithAKeyOutsideItsTypeIsUndescribable(_ entry: JSON) {
    #expect(AlwaysAllow.describe([entry]) == nil)
    #expect(AlwaysAllow.describe([addDirectories(), entry]) == nil)
  }

  @Test(arguments: [
    JSON.array([["toolName": "Bash", "ruleContent": "make lint", "behavior": "deny"]]),
    [["toolName": "Bash", "destination": "userSettings"]], [["toolName": "WebSearch", "extra": .null]],
    [["toolName": "Bash"], ["toolName": "Bash", "ruleContent": "ls", "matcher": "*"]],
  ])
  func aRuleWithAKeyOutsideToolNameAndContentIsUndescribable(_ rules: JSON) {
    #expect(AlwaysAllow.describe([addRules(rules)]) == nil)
  }

  @Test(arguments: [JSON.array([""]), ["/w/data", ""], ["", "/w/data"]])
  func anEmptyDirectoryIsUndescribable(_ directories: JSON) {
    #expect(AlwaysAllow.describe([addDirectories(directories)]) == nil)
  }

  @Test(arguments: [
    JSON.array([["toolName": ""]]), [["toolName": "", "ruleContent": "npm test:*"]],
    [["toolName": "Bash", "ruleContent": ""]], [["toolName": "Bash"], ["toolName": ""]],
  ])
  func aRuleWithAnEmptyToolNameOrContentIsUndescribable(_ rules: JSON) {
    #expect(AlwaysAllow.describe([addRules(rules)]) == nil)
  }

  @Test func anEmptyModeIsUndescribable() {
    #expect(AlwaysAllow.describe([setMode("")]) == nil)
  }

  @Test(arguments: ["bypassPermissions", "auto", "default", "plan", "dontAsk", "AcceptEdits"])
  func aModeOtherThanAcceptEditsIsUndescribable(_ mode: String) {
    #expect(AlwaysAllow.describe([setMode(.string(mode))]) == nil)
  }

  @Test(arguments: [
    addDirectories([" "]), addDirectories(["/w/data", "   "]), addRules([["toolName": " "]]),
    addRules([["toolName": "Bash", "ruleContent": "  "]]), setMode(" "),
  ])
  func aBlankValueIsUndescribable(_ entry: JSON) {
    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  /// The app would show a newline as a line break inside the sentence, and an escape could redraw the terminal.
  /// A right-to-left override reverses the text, and a zero-width space hides in it.
  @Test(arguments: [
    addDirectories(["/w/a\u{2028}b"]), addDirectories(["/w/a\u{2029}b"]), addDirectories(["/w/\u{202E}txt.dab"]),
    addRules([["toolName": "Bash\u{200B}"]]),
    addDirectories(["/w/data\n for this session. Also /"]), addDirectories(["/w/a\tb"]),
    addRules([["toolName": "Bash\u{1B}[2K"]]), addRules([["toolName": "Bash", "ruleContent": "ls\r"]]),
    setMode("acceptEdits\u{7F}"),
  ])
  func aValueWithAMisleadingCharacterIsUndescribable(_ entry: JSON) {
    #expect(AlwaysAllow.describe([entry]) == nil)
  }

  @Test(arguments: [
    addRules(behavior: "deny"), addDirectories(destination: "cliArg"), addDirectories([42]),
    ["type": "removeDirectories", "directories": ["/w/data"], "destination": "session"],
  ])
  func oneUndescribableSuggestionMakesTheWholeListUndescribable(_ bad: JSON) {
    #expect(AlwaysAllow.describe([addDirectories(), bad]) == nil)
    #expect(AlwaysAllow.describe([bad, addDirectories()]) == nil)
    #expect(AlwaysAllow.describe([addRules(), setMode(), bad]) == nil)
  }
}
