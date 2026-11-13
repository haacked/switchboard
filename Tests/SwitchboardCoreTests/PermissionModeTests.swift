import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct PermissionModeTests {
  /// A permission turn whose hooks report the mode.
  func turn(_ mode: String?) -> [Event] {
    let m: [String: JSON] = mode.map { ["permission_mode": .string($0)] } ?? [:]
    return promptTurn(touchCall.merging(m) { $1 }, touch.merging(m) { $1 })
  }

  @Test func aCardFromManualOrAcceptEditsModeOffersAutoMode() {
    #expect(facts(turn("default")).cards[0].offers(.autoMode))
    #expect(facts(turn("acceptEdits")).cards[0].offers(.autoMode))
    for mode in ["auto", "plan", "bypassPermissions", nil] {
      #expect(!facts(turn(mode)).cards[0].offers(.autoMode))
    }
  }

  @Test func aQuestionOrAClosedHookDoesNotOfferAutoMode() {
    let m: [String: JSON] = ["permission_mode": "default"]
    #expect(!facts(promptTurn(ask(), ask(id: nil).merging(m) { $1 })).cards[0].offers(.autoMode))
    let closed = facts(turn("default") + [event("card_closed", 3, ["card": 3])])
    #expect(closed.cards[0].hookClosed)
    #expect(!closed.cards[0].offers(.autoMode))
  }

  @Test func factsFollowTheMainSessionsMode() {
    #expect(facts(turn("default")).permissionMode == "default")
    // A subagent's hook doesn't change the main session's mode.
    let sub = event(
      "PreToolUse", 4, tool("Bash", ["command": "ls"], agent: "a1").merging(["permission_mode": "plan"]) { $1 })
    #expect(facts(turn("default") + [sub]).permissionMode == "default")
    let answered = event("answered", 4, ["card": 3, "behavior": "allow", "permission_mode": "auto"])
    #expect(facts(turn("default") + [answered]).permissionMode == "auto")
    // A launch without a mode leaves it unknown until the next hook.
    #expect(facts(turn("default") + [event("resumed", 5)]).permissionMode == nil)
    #expect(facts(turn("default") + [event("resumed", 5, ["permission_mode": "auto"])]).permissionMode == "auto")
  }

  @Test func anAutoModeAllowSetsTheSessionsMode() {
    let output: JSON = [
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": [
          "behavior": "allow",
          "updatedPermissions": [["type": "setMode", "mode": "auto", "destination": "session"]],
        ],
      ]
    ]
    let card = facts(turn("default")).cards[0]
    #expect(Decision.allow(updatedInput: nil, permissions: card.permissions(.autoMode)).hookOutput == output)
  }

  @Test func eachAutoModeRefusalSaysWhy() {
    let m: [String: JSON] = ["permission_mode": "default"]
    let question = facts(promptTurn(ask(), ask(id: nil).merging(m) { $1 })).cards[0]
    #expect(question.refusal(.autoMode) == "card 3 isn't a permission prompt")
    let closed = facts(turn("default") + [event("card_closed", 3, ["card": 3])]).cards[0]
    #expect(closed.refusal(.autoMode) == "card 3's hook closed, so sbd can't switch the mode")
    #expect(facts(turn("default")).cards[0].hookClosedRefusal(.autoMode) == closed.refusal(.autoMode))
    #expect(facts(turn(nil)).cards[0].refusal(.autoMode) == "card 3's hook didn't report the permission mode")
    #expect(facts(turn("auto")).cards[0].refusal(.autoMode) == "s1 is already in auto mode")
    #expect(facts(turn("plan")).cards[0].refusal(.autoMode) == "card 3 came from plan mode")
    #expect(facts(turn("default")).cards[0].refusal(.autoMode) == nil)
  }

  @Test func alwaysUsesItsOwnFlagLabelAndAdvice() {
    #expect(AllowExtra.always.argument == "always")
    #expect(AllowExtra.always.flag == "--always")
    #expect(AllowExtra.always.label == "Always allow")
    #expect(AllowExtra.always.withoutPhrase == "always")
    #expect(AllowExtra.always.triageAction == nil)
  }

  @Test func aHeldCardWithDescribableSuggestionsOffersAlways() throws {
    let card = try writeRestartCard(restarted: false)

    #expect(card.offers(.always))
  }

  /// The write-restart.json request came from auto mode, so always is its only extra.
  @Test func suggestionsOfferOnlyAlwaysFromAutoMode() throws {
    #expect(try writeRestartCard(restarted: false).offeredExtras == [.always])
  }

  @Test func aCardFromManualModeWithSuggestionsOffersBothExtras() throws {
    #expect(try suggestionCard([addDirectories()]).offeredExtras == [.autoMode, .always])
  }

  @Test func aCardWhoseHookClosedRefusesAlways() throws {
    let card = try writeRestartCard()

    #expect(!card.offers(.always))
    #expect(card.refusal(.always) == "card 3's hook closed, so sbd can't save the always-allow rule")
  }

  @Test func theHookClosedRefusalOfAlwaysIsTheSameForAHeldCard() throws {
    let held = try writeRestartCard(restarted: false)

    #expect(held.hookClosedRefusal(.always) == "card 3's hook closed, so sbd can't save the always-allow rule")
  }

  @Test func aCardClosedByCardClosedRefusesAlways() {
    let closed = facts(
      promptTurn(touchCall, touch.merging(["permission_suggestions": [addDirectories()]]) { $1 })
        + [event("card_closed", 3, ["card": 3])]
    ).cards[0]

    #expect(closed.hookClosed)
    #expect(closed.refusal(.always) == "card 3's hook closed, so sbd can't save the always-allow rule")
  }

  @Test func aCardWithoutSuggestionsRefusesAlways() throws {
    #expect(try suggestionCard(nil).refusal(.always) == "card 3's request offered no always-allow rule")
    #expect(facts(permissionTurn()).cards[0].refusal(.always) == "card 3's request offered no always-allow rule")
  }

  @Test func aCardWithAnEmptySuggestionListDoesNotOfferAlways() throws {
    let card = try suggestionCard([])

    #expect(!card.offers(.always))
    #expect(card.refusal(.always) != nil)
  }

  @Test(arguments: [
    JSON.array([addRules(behavior: "deny")]), [addRules(behavior: "ask")],
    [["type": "replaceRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "session"]],
    [["type": "removeDirectories", "directories": ["/w/data"], "destination": "session"]],
    [addDirectories(destination: "cliArg")], [addDirectories([42])], [addDirectories(), addRules(behavior: "deny")],
  ])
  func aCardWithUndescribableSuggestionsRefusesAlways(_ suggestions: JSON) throws {
    let card = try suggestionCard(suggestions)

    #expect(
      card.refusal(.always) == "card 3's always-allow rule is one Switchboard can't describe, so sbd won't apply it")
  }

  @Test(arguments: [
    facts(
      promptTurn(ask(), ask(id: nil).merging(["permission_suggestions": [addDirectories()]]) { $1 })
    ).cards[0],
    trustCard(), facts([sendPending()]).cards[0],
  ])
  func aCardThatIsNotAPermissionPromptRefusesAlways(_ card: Card) {
    #expect(!card.offers(.always))
    #expect(card.refusal(.always) == "card \(card.id) isn't a permission prompt")
  }

  @Test func alwaysAppliesExactlyTheRequestsSuggestions() throws {
    let card = try writeRestartCard(restarted: false)
    let suggestions = try #require(try eventFixture("write-restart")["permission_suggestions"]?.array)

    #expect(card.permissions(.always) == suggestions)
  }

  @Test func aCardWithoutSuggestionsAppliesNoPermissions() throws {
    #expect(try suggestionCard(nil).permissions(.always).isEmpty)
  }

  @Test func theNoteOfAlwaysIsTheSuggestionsDescription() throws {
    let card = try writeRestartCard(restarted: false)

    #expect(card.note(.always) == AlwaysAllow.describe(card.permissionSuggestions))
  }

  @Test func anAlwaysAllowCarriesTheWriteRestartSuggestionsVerbatim() throws {
    let suggestions = try #require(try eventFixture("write-restart")["permission_suggestions"])

    let output = Decision.allow(updatedInput: nil, permissions: try #require(suggestions.array)).hookOutput

    #expect(output["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == suggestions)
  }

  @Test func anAlwaysAllowOfACardCarriesItsSuggestionsVerbatim() throws {
    let suggestions: JSON = [
      addDirectories(["/w/say \"hi\"", "/w/back\\slash", "/w/caf\u{E9}", "/w/null"]),
      addRules([["toolName": "Bash", "ruleContent": "echo 'a b' \"c\" \\n"], ["toolName": "WebSearch"]]),
      setMode("acceptEdits"),
    ]
    let card = try suggestionCard(suggestions)
    let output: JSON = [
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": ["behavior": "allow", "updatedPermissions": suggestions],
      ]
    ]

    #expect(Decision.allow(updatedInput: nil, permissions: card.permissions(.always)).hookOutput == output)
  }

  @Test func titlesUseTheStatusLinesNames() {
    #expect(PermissionMode.title("default") == "manual")
    #expect(PermissionMode.title("acceptEdits") == "accept edits")
    #expect(PermissionMode.title("auto") == "auto")
  }

  @Test func aConfigWithoutAutoModeStartsSessionsInAutoMode() throws {
    #expect(try JSONCoding.decode(Config.self, from: #"{"idleStopSeconds": 30}"#).autoMode)
    #expect(try !JSONCoding.decode(Config.self, from: #"{"autoMode": false}"#).autoMode)
  }
}
