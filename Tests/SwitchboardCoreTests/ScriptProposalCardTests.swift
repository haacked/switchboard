import Foundation
import Testing

@testable import SwitchboardCore

/// The data of a `script_proposed` event: a proposal to run `command` every `every` ms in the folder of `target`.
/// An edit's proposal also names the schedule and holds its command and timeout before the edit.
func scriptProposalData(
  command: String = "git fetch", target: String = "s2", targetName: String = "alpha", folder: String = "/w/alpha",
  every: Int64 = 3_600_000, timeout: Int64? = nil, reason: String = "Keep the branch fresh.", schedule: String? = nil,
  before: (command: String, timeout: Int64?)? = nil, expires: Int64 = 86_400_010
) -> [String: JSON] {
  var data: [String: JSON] = [
    "target": .string(target), "targetName": .string(targetName), "folder": .string(folder),
    "every": .number(Double(every)), "command": .string(command), "reason": .string(reason),
    "expires": .number(Double(expires)),
  ]
  if let timeout { data["timeout"] = .number(Double(timeout)) }
  if let schedule { data["schedule"] = .string(schedule) }
  if let before {
    var old: [String: JSON] = ["command": .string(before.command), "every": .number(Double(every))]
    if let t = before.timeout { old["timeout"] = .number(Double(t)) }
    data["before"] = .object(old)
  }
  return data
}

/// A `script_proposed` event 13 on the proposing session s1, so its card's id is 13.
func scriptProposed(
  command: String = "git fetch", id: Int64 = 13, t: Int64 = 10, schedule: String? = nil,
  before: (command: String, timeout: Int64?)? = nil, timeout: Int64? = nil
) -> Event {
  Event(
    id: id, session: "s1", t: t, kind: "script_proposed",
    data: .object(scriptProposalData(command: command, timeout: timeout, schedule: schedule, before: before)))
}

/// The `script_decided` event that closes card `card`.
func scriptDecided(_ card: Int64, _ decision: String, schedule: String? = nil, t: Int64 = 20) -> Event {
  var data: [String: JSON] = ["card": .number(Double(card)), "decision": .string(decision)]
  if let schedule { data["schedule"] = .string(schedule) }
  return event("script_decided", t, data)
}

/// The card that a `script_proposed` event opens.
func scriptCard(_ command: String = "git fetch") -> Card { facts([scriptProposed(command: command)]).cards[0] }

/// Text where a decoder, a trim, or a JSON round trip could change what Claude wrote, or where a terminal could act on
/// what the card prints.
let scriptCommands = [
  "git fetch && git status --short | head -5", "null", "  42  ", "echo \"hi\" > /tmp/x", "\u{1B}[2Kecho hidden",
  "printf 'a\\nb'\nrm -rf ~/scratch", "{\"command\": null}", "echo \u{7}bell\tdone",
]

/// The events that end a turn, plus sbd's own `idle`. None of them closes a `script` card.
let scriptCardSurvivors = turnEnds + [event("idle", 4)]

/// A `script` card holds a script schedule that a session proposed, which the user
/// approves or denies. It opens with `script_proposed` and closes only with `script_decided`.
@Suite struct ScriptProposalCardTests {
  // MARK: Opening the card

  @Test func aScriptProposedEventOpensAScriptCardOnTheProposingSession() throws {
    let cards = facts([scriptProposed()]).cards

    let card = try #require(cards.first)
    #expect(cards.count == 1)
    #expect(card.id == 13)
    #expect(card.session == "s1")
    #expect(card.kind == .script)
    #expect(card.since == 10)
  }

  @Test func theCardHoldsTheProposalAsRecorded() throws {
    let proposal = try #require(scriptCard().scriptProposal)

    #expect(proposal.target == "s2")
    #expect(proposal.targetName == "alpha")
    #expect(proposal.folder == "/w/alpha")
    #expect(proposal.every == 3_600_000)
    #expect(proposal.command == "git fetch")
    #expect(proposal.timeout == nil)
    #expect(proposal.reason == "Keep the branch fresh.")
    #expect(proposal.schedule == nil)
    #expect(proposal.before == nil)
    #expect(proposal.expires == 86_400_010)
  }

  @Test func aProposalWithATimeoutKeepsIt() throws {
    let card = try #require(facts([scriptProposed(timeout: 120_000)]).cards.first)

    #expect(card.scriptProposal?.timeout == 120_000)
  }

  /// Decision 28: an edit's card names the schedule and holds the command and timeout that the edit replaces.
  @Test func anEditsProposalHoldsTheScheduleAndTheCommandBefore() throws {
    let card = try #require(
      facts([scriptProposed(command: "git pull", schedule: "r7", before: ("git fetch", 600_000))]).cards.first)

    let proposal = try #require(card.scriptProposal)
    #expect(proposal.schedule == "r7")
    #expect(proposal.command == "git pull")
    #expect(proposal.before?.command == "git fetch")
    #expect(proposal.before?.timeout == 600_000)
  }

  @Test(arguments: scriptCommands) func theCardKeepsTheRecordedCommandExactly(_ command: String) {
    #expect(scriptCard(command).scriptProposal?.command == command)
  }

  @Test func theCardHoldsNoCallNoQuestionsAndNoOtherKindsPayload() {
    let card = scriptCard()

    #expect(card.input == [:])
    #expect(card.questions.isEmpty)
    #expect(!card.deferred)
    #expect(!card.hookClosed)
    #expect(card.send == nil)
    #expect(card.mcpRequest == nil)
  }

  @Test func otherKindsOfCardHoldNoProposal() {
    #expect(facts(permissionTurn()).cards.first?.scriptProposal == nil)
    #expect(facts(questionTurn()).cards.first?.scriptProposal == nil)
    #expect(facts([sendPending()]).cards.first?.scriptProposal == nil)
    #expect(mcpCard().scriptProposal == nil)
    #expect(trustCard().scriptProposal == nil)
  }

  /// Data that is not a `ScriptProposal` opens no card.
  static let notProposals: [JSON] = [
    [:],
    ["command": "git fetch"],
    [
      "target": "s2", "targetName": "alpha", "folder": "/w/alpha", "every": "1h", "command": "git fetch",
      "reason": "r", "expires": 1,
    ],
    [
      "target": "s2", "targetName": "alpha", "folder": "/w/alpha", "every": 3_600_000, "command": 42, "reason": "r",
      "expires": 1,
    ],
    .object(mcpRequestData()),
    .object(sendPendingData()),
    "git fetch",
    .null,
  ]

  @Test(arguments: notProposals) func dataThatIsNotAProposalOpensNoCard(_ data: JSON) {
    let e = Event(id: 13, session: "s1", t: 10, kind: "script_proposed", data: data)

    #expect(Card(scriptProposal: e) == nil)
    #expect(facts([e]).cards.isEmpty)
  }

  // MARK: What the card says

  @Test func theReasonSaysToApproveTheScriptAndNamesTheCommand() {
    #expect(scriptCard().reason == "approve a script: git fetch")
  }

  /// The reason becomes the session's attention line and the Inbox item's title, which a terminal or a list row
  /// shows on one line.
  @Test(arguments: scriptCommands) func theReasonHoldsNoControlCharacterAndNoNewline(_ command: String) {
    let reason = scriptCard(command).reason

    #expect(reason.hasPrefix("approve a script: "), "\(reason)")
    #expect(!reason.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\t" }, "\(reason)")
    #expect(!reason.contains("\n"), "\(reason)")
  }

  /// No dialog in the terminal shows a proposal, so sbd never looks for one.
  @Test func aScriptCardIsNotFindable() {
    #expect(!scriptCard().findable)
  }

  @Test func aScriptCardOutlivesItsTurn() {
    #expect(scriptCard().outlivesTurn)
  }

  @Test func anOpenScriptCardNeedsYouWithTheCardsReason() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), scriptProposed(), event("Stop", 11)])

    let verdict = Attention.evaluate(session(), f, now: 12)

    #expect(verdict.state == .needsYou)
    #expect(verdict.reason == "approve a script: git fetch")
  }

  // MARK: Closing the card

  @Test(arguments: ["approved", "denied", "expired", "stale"]) func scriptDecidedClosesItsCard(_ decision: String) {
    #expect(facts([scriptProposed(), scriptDecided(13, decision)]).cards.isEmpty)
  }

  @Test func scriptDecidedForAnotherCardLeavesTheCard() {
    #expect(facts([scriptProposed(), scriptDecided(99, "approved")]).cards.map(\.id) == [13])
  }

  @Test func scriptDecidedClosesOnlyItsOwnCard() {
    let f = facts([scriptProposed(id: 13), scriptProposed(id: 15, t: 12), scriptDecided(13, "denied")])

    #expect(f.cards.map(\.id) == [15])
  }

  /// Another kind's decision that names the card is not the decision that closes it.
  @Test func anotherKindOfDecisionLeavesTheScriptCard() {
    let f = facts([scriptProposed(), sendDecided(13, "sent"), mcpDecidedEvent(13, "allowed")])

    #expect(f.cards.map(\.id) == [13])
  }

  @Test func aScriptDecisionLeavesASendCardAndAnMCPCard() {
    let f = facts([sendPending(), mcpRequestEvent(), scriptDecided(7, "approved"), scriptDecided(9, "approved")])

    #expect(f.cards.map(\.id) == [7, 9])
  }

  @Test(arguments: scriptCardSurvivors) func aScriptCardSurvivesTheEndOfTheTurn(_ end: Event) {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), scriptProposed(), end])

    #expect(f.cards.map(\.id) == [13])
  }

  @Test(
    arguments: ["PostToolUse", "PostToolUseFailure"],
    [
      tool("mcp__switchboard__add_schedule", ["every": "1h", "script": "git fetch"]),
      tool("mcp__switchboard__edit_schedule", ["schedule": "r7", "script": "git pull"]),
      tool("Bash", ["command": "sb schedule s2 --every 1h --script 'git fetch'"]),
    ])
  func aScriptCardSurvivesTheCallThatOpenedItFinishing(_ kind: String, _ call: [String: JSON]) {
    let f = facts([scriptProposed(), event(kind, 11, call)])

    #expect(f.cards.map(\.id) == [13])
  }

  @Test func theNextSessionStartKeepsAScriptCard() {
    #expect(facts([scriptProposed(), event("SessionStart", 11)]).cards.map(\.id) == [13])
  }

  @Test func theEndOfTheTurnRemovesAPermissionCardAndKeepsAScriptCard() {
    let f = facts(permissionTurn() + [scriptProposed(), event("Stop", 11, ["last_assistant_message": "ok"])])

    #expect(f.cards.map(\.kind) == [.script])
  }

  /// The held requests end with sbd, but a proposal waits in the event log.
  @Test func aRestartOfSbdKeepsAScriptCard() {
    var replay = SessionReplay.replaying(fetchTurn() + [scriptProposed()], session: session())

    replay.restarted()

    #expect(replay.facts.cards.map(\.id) == [13])
  }

  // MARK: Encoding

  @Test func aScriptCardSurvivesEncoding() throws {
    for card in [
      scriptCard(), scriptCard("\u{1B}[2Kecho hidden"),
      facts([scriptProposed(command: "git pull", schedule: "r7", before: ("git fetch", nil), timeout: 60_000)]).cards[
        0],
    ] {
      #expect(try JSONCoding.decode(Card.self, from: try JSONCoding.encode(card)) == card)
    }
  }

  @Test func theKindUsesTheWireNameScript() throws {
    #expect(Card.Kind.script.rawValue == "script")
    #expect(try JSON(encoding: Card.Kind.script) == "script")
  }

  /// The data that sbd records in `script_proposed` is the encoded proposal, and it reads back as the same proposal.
  @Test func theRecordedDataIsTheEncodedProposal() throws {
    let recorded = JSON.object(
      scriptProposalData(timeout: 300_000, schedule: "r7", before: (command: "git fetch", timeout: nil)))

    let proposal = try JSONCoding.convert(recorded, to: ScriptProposal.self)

    #expect(try JSON(encoding: proposal) == recorded)
  }

  @Test(
    arguments: [
      ("pending", ScriptDecision.pending), ("approved", .approved), ("denied", .denied), ("expired", .expired),
      ("stale", .stale),
    ])
  func theDecisionUsesTheWireNames(_ raw: String, _ decision: ScriptDecision) throws {
    #expect(decision.rawValue == raw)
    #expect(try JSON(encoding: decision) == .string(raw))
  }

  /// Decision 27: a proposal waits a day, as long as a held permission request.
  @Test func aProposalExpiresAfterADay() {
    #expect(ScriptProposal.expirySeconds == 86_400)
    #expect(ScriptProposal.expirySeconds == Int64(Card.holdSeconds))
  }
}

/// The MCP tools tell Claude that a script from a session other than a Manager conversation waits for the
/// user, and that the turn ends after the call.
@Suite struct ScriptProposalCardTestsMCPTools {
  func tool(_ name: String) throws -> MCPToolServer.Tool {
    try #require(MCPToolServer.allTools.first { $0.name == name })
  }

  /// The tool's description and its `script` property's description, in lower case.
  func text(_ name: String) throws -> String {
    let t = try tool(name)
    return (t.description + "\n" + (t.properties["script"]?["description"]?.string ?? "")).lowercased()
  }

  @Test(arguments: ["add_schedule", "edit_schedule"])
  func theScriptDescriptionSaysTheUserMustApproveAScriptFromASession(_ name: String) throws {
    let text = try text(name)

    #expect(text.contains("approve"), "\(text)")
    #expect(text.contains("manager conversation"), "\(text)")
  }

  @Test(arguments: ["add_schedule", "edit_schedule"])
  func theScriptDescriptionSaysToEndTheTurnAfterTheCall(_ name: String) throws {
    let text = try text(name)

    #expect(text.contains("end the turn") || text.contains("end your turn"), "\(text)")
  }
}
