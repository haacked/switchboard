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
