import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct AlwaysAllowTests {
  /// Suggestions that Switchboard can describe. Their texts hold a space, quotes,
  /// and a backslash, which must reach the hook's reply unchanged.
  static let suggestions: JSON = [
    ["type": "addDirectories", "directories": ["/w/my data", "/w/say \"hi\""], "destination": "session"],
    [
      "type": "addRules", "behavior": "allow", "destination": "localSettings",
      "rules": [["toolName": "Bash", "ruleContent": "echo 'a b' \"c\" \\ d"]],
    ],
  ]

  /// A session outside auto mode whose Edit card is open. The stub adds
  /// `suggestions` to the PermissionRequest, or adds none when it is nil.
  func asked(_ suggestions: JSON? = AlwaysAllowTests.suggestions) throws -> (Instance, SessionSummary, Card) {
    let sbd = try Instance()
    if let suggestions {
      try suggestions.text.write(toFile: "\(sbd.home.path)/suggestions.json", atomically: true, encoding: .utf8)
    }
    try "alpha\nbeta\n".write(toFile: "\(sbd.work)/notes.txt", atomically: true, encoding: .utf8)
    let s = try sbd.new(prompt: "edit notes.txt beta BETA")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    return (sbd, asked, try #require(asked.cards.first))
  }

  /// Waits for the stub to make the edit.
  @discardableResult
  func edited(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try sbd.waitFor(id, "the edit's reply") { $0.lastReply?.hasPrefix("Edited") == true && $0.cards.isEmpty }
  }

  @Test func aCardWithSuggestionsOffersAlways() throws {
    let (sbd, s, card) = try asked()

    #expect(card.permissionSuggestions == Self.suggestions)
    #expect(card.offeredExtras == [.autoMode, .always])
    let listed = try sbd.sb("cards", s.id)
    #expect(listed.contains("approve Edit, --auto offered, --always offered"))
    #expect(listed.contains(try #require(AlwaysAllow.describe(Self.suggestions))))
  }

  @Test func cardsJsonCarriesTheSuggestions() throws {
    let (sbd, s, _) = try asked()

    let cards = try JSONCoding.decode([Card].self, from: try sbd.sb("cards", "--json", s.id))

    #expect(cards.first?.permissionSuggestions == Self.suggestions)
  }

  /// `sb choose` doesn't offer always-allow, so the Inbox options stay as they were.
  @Test func chooseDoesNotOfferAlways() throws {
    let (sbd, s, _) = try asked()

    let item = try #require(try sbd.get(s.id).triage)

    #expect(item.options.map(\.action) == [.allow, .deny, .allowAutoMode])
  }

  @Test func allowWithAlwaysAnswersTheHookWithTheSuggestions() throws {
    let (sbd, s, _) = try asked()

    let answer = try JSON.parse(sbd.sb("allow", "--always", "--json", s.id))

    #expect(answer?["delivery"]?.string == "hook")
    let after = try edited(sbd, s.id)
    let decision = try #require(sbd.permissionAnswers(s.claudeSessionId).last)
    #expect(decision["behavior"] == "allow")
    #expect(decision["updatedPermissions"] == Self.suggestions)
    #expect(after.permissionMode == "default")
    #expect(try String(contentsOfFile: "\(sbd.work)/notes.txt", encoding: .utf8) == "alpha\nBETA\n")
  }

  @Test func allowWithAlwaysRecordsItInTheAnsweredEvent() throws {
    let (sbd, s, card) = try asked()

    try sbd.sb("allow", "--always", s.id)

    try edited(sbd, s.id)
    let answered = try sbd.events(s.id).filter { $0.kind == "answered" }
    #expect(answered.count == 1)
    #expect(answered.first?.data["card"] == .number(Double(card.id)))
    #expect(answered.first?.data["always"] == true)
    #expect(answered.first?.data["permission_mode"] == nil)
  }

  @Test func aPlainAllowSendsNoSuggestions() throws {
    let (sbd, s, _) = try asked()

    try sbd.sb("allow", s.id)

    try edited(sbd, s.id)
    let decision = try #require(sbd.permissionAnswers(s.claudeSessionId).last)
    #expect(decision["behavior"] == "allow")
    #expect(decision["updatedPermissions"] == nil)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" && $0.data["always"] != nil })
  }

  @Test func allowWithAutoSendsOnlyTheModeSwitch() throws {
    let (sbd, s, _) = try asked()

    try sbd.sb("allow", "--auto", s.id)

    try edited(sbd, s.id)
    let decision = try #require(sbd.permissionAnswers(s.claudeSessionId).last)
    #expect(decision["updatedPermissions"] == [["type": "setMode", "mode": "auto", "destination": "session"]])
  }

  @Test func aCardWithoutSuggestionsDoesNotOfferAlways() throws {
    let (sbd, s, card) = try asked(nil)

    #expect(card.permissionSuggestions == nil)
    #expect(!card.offers(.always))
    #expect(try !sbd.sb("cards", s.id).contains("--always"))
  }

  @Test func refusesAlwaysWithoutSuggestions() throws {
    let (sbd, s, card) = try asked(nil)

    let refused = try sbd.run("allow", "--always", s.id)

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("card \(card.id)'s request offered no always-allow rule. Allow it without always"))
    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
    #expect(sbd.permissionAnswers(s.claudeSessionId).isEmpty)
  }

  @Test func refusesAlwaysForSuggestionsItCantDescribe() throws {
    let replace: JSON = [
      ["type": "replaceRules", "rules": [["toolName": "Bash"]], "behavior": "allow", "destination": "userSettings"]
    ]
    let (sbd, s, card) = try asked(replace)
    #expect(card.permissionSuggestions == replace)
    #expect(!card.offers(.always))
    #expect(try !sbd.sb("cards", s.id).contains("--always"))

    let refused = try sbd.run("allow", "--always", s.id)

    #expect(refused.status != 0)
    #expect(
      refused.stderr.contains(
        "card \(card.id)'s always-allow rule is one Switchboard can't describe, so sbd won't apply it"))
    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(sbd.permissionAnswers(s.claudeSessionId).isEmpty)
  }

  /// An app that read the card before sbd's check still can't apply the rule.
  @Test func sbdChecksAlwaysOnEveryAnswer() throws {
    let replace: JSON = [["type": "removeDirectories", "directories": ["/w/data"], "destination": "session"]]
    let (sbd, s, _) = try asked(replace)

    #expect(throws: APIError.self) {
      try sbd.client.call("answer", ["session": .string(s.id), "behavior": "allow", "always": true])
    }

    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
    #expect(sbd.permissionAnswers(s.claudeSessionId).isEmpty)
  }

  @Test func refusesAlwaysAfterTheHookTimesOut() throws {
    let (sbd, s, card) = try asked()
    try #require(card.offers(.always))
    try sbd.type(s.id, "timeout")
    let closed = try sbd.waitFor(s.id, "the closed hook") { $0.cards.first?.hookClosed == true }
    #expect(closed.cards.first?.offers(.always) == false)

    let refused = try sbd.run("allow", "--always", s.id)

    #expect(refused.status != 0)
    #expect(
      refused.stderr.contains(
        "card \(card.id)'s hook closed, so sbd can't save the always-allow rule. Allow it without always"))
    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
  }

  @Test func refusesAutoWithAlways() throws {
    let (sbd, s, card) = try asked()
    try #require(card.offeredExtras == [.autoMode, .always])

    let refused = try sbd.run("allow", "--auto", "--always", s.id)

    #expect(refused.status != 0)
    #expect(refused.stderr.contains("card \(card.id): pick one of autoMode and always"))
    let after = try sbd.get(s.id)
    #expect(after.cards.count == 1)
    #expect(after.permissionMode == "default")
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
    #expect(sbd.permissionAnswers(s.claudeSessionId).isEmpty)
  }

  @Test func alwaysIsRefusedWithADeny() throws {
    let (sbd, s, _) = try asked()

    #expect(throws: APIError.self) {
      try sbd.client.call("answer", ["session": .string(s.id), "behavior": "deny", "always": true])
    }

    #expect(try sbd.get(s.id).cards.count == 1)
    #expect(try !sbd.events(s.id).contains { $0.kind == "answered" })
  }
}

extension GroupMessageTests {
  @Test func alwaysIsRefusedForAGroupMessage() throws {
    let s = try setup()
    let card = try open(s)
    #expect(throws: APIError.self) {
      try s.sbd.client.call(
        "answer",
        ["session": .string(s.sender.id), "card": .number(Double(card)), "behavior": "allow", "always": true])
    }
    #expect(try sent(s.sbd, s.a.id).isEmpty)
    #expect(try s.sbd.get(s.sender.id).cards.count == 1)
  }
}
