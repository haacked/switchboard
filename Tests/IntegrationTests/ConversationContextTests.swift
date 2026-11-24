import Foundation
import SwitchboardCore
import Testing

/// The context size of a Manager conversation. After each turn of a conversation, sbd reads the input context of the
/// turn's latest API call from the transcript and records it as a `context` event. The stub's `context <n>` prompt
/// writes an assistant line whose usage gives n tokens.
@Suite(.blocking(timeLimit: .seconds(120))) struct ConversationContextTests {
  let conv = ManagerConversationsTests()

  /// A conversation whose turn for `context <tokens>` has ended and whose summary shows that size.
  @discardableResult
  func contextConversation(_ sbd: Instance, _ tokens: Int) throws -> SessionSummary {
    let c = try conv.newConversation(sbd)
    try sbd.waitFor(c.id, "the stub") { $0.live }
    return try sendContext(sbd, c.id, tokens)
  }

  /// Sends `context <tokens>` to the conversation and waits for `sb manager ls` to show that size.
  @discardableResult
  func sendContext(_ sbd: Instance, _ id: String, _ tokens: Int) throws -> SessionSummary {
    try sbd.sb("send", id, "context \(tokens)")
    return try waitForContext(sbd, id, tokens)
  }

  /// The conversation's row in `sb manager ls --json`.
  func listed(_ sbd: Instance, _ id: String) throws -> SessionSummary {
    try #require(try conv.conversations(sbd).first { $0.id == id })
  }

  @discardableResult
  func waitForContext(_ sbd: Instance, _ id: String, _ tokens: Int?, timeout: Double = 30) throws -> SessionSummary {
    try sbd.waitFor(
      "contextTokens \(tokens.map(String.init) ?? "nil") on \(id)", timeout: timeout,
      fetch: { try listed(sbd, id) }
    ) { $0.contextTokens == tokens }
  }

  /// The tokens of each `context` event of the session, oldest first. A null value reads as nil.
  func recorded(_ sbd: Instance, _ id: String) throws -> [Int?] {
    try sbd.events(id).filter { $0.kind == "context" }.map { $0.data["tokens"]?.int }
  }

  // MARK: The value

  @Test func aConversationsTurnShowsItsContextInManagerLs() throws {
    let sbd = try Instance()
    let c = try conv.newConversation(sbd)
    try sbd.waitFor(c.id, "the stub") { $0.live }

    try sbd.sb("send", c.id, "context 250000")

    let row = try waitForContext(sbd, c.id, 250_000)
    #expect(row.contextTokens == 250_000)
  }

  @Test func managerLsAndGetNameTheValueContextTokens() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    let rows = try #require(JSON.parse(try sbd.sb("manager", "ls", "--json"))?.array)
    let row = try #require(rows.first { $0["id"]?.string == c.id })
    let got = try #require(JSON.parse(try sbd.sb("get", "--json", c.id)))

    #expect(row["contextTokens"]?.int == 250_000)
    #expect(got["contextTokens"]?.int == 250_000)
  }

  /// A turn whose read gives the stored value records nothing. The plain turn's reply line carries no usage, so its
  /// read gives the earlier turn's value.
  @Test func aContextEventIsRecordedOnlyWhenTheValueChanges() throws {
    let sbd = try Instance()
    let c = try conv.idleConversation(sbd)
    try sendContext(sbd, c.id, 250_000)
    try sbd.sb("send", c.id, "again")
    try sbd.waitFor(c.id, "the reply to again") { $0.lastReply == "Done: again" }
    try sbd.sb("send", c.id, "context 250000")
    try sbd.waitFor(c.id, "the second reply") { $0.lastReply == "Context: 250000" }

    try sendContext(sbd, c.id, 260_000)

    #expect(try recorded(sbd, c.id) == [250_000, 260_000])
  }

  // MARK: Other kinds

  /// The sessions that are not Manager conversations. The Operator also has `manager` set.
  enum OtherKind: String, CaseIterable, CustomTestStringConvertible {
    case work, chat, `operator`

    var testDescription: String { rawValue }

    /// A session of this kind whose turn for `context 250000` has ended.
    func session(_ sbd: Instance) throws -> SessionSummary {
      let prompt = "context 250000"
      let id: String
      switch self {
      case .work:
        id = try sbd.new(prompt: prompt).id
      case .chat:
        _ = try ChatTests().addGroup(sbd, "Flags")
        id = try #require(try ChatTests().send(sbd, "Flags", prompt)["id"]?.string)
      case .operator:
        let op = try OperatorTests().openOperator(sbd)
        try sbd.waitFor(op.id, "the operator's claude") { $0.live }
        try sbd.sb("operator", prompt)
        id = op.id
      }
      return try sbd.waitFor(id, "the reply to \(prompt)", timeout: 30) { $0.lastReply == "Context: 250000" }
    }
  }

  /// A conversation's turn after the other session's turn shows that sbd handled both Stops.
  @Test(arguments: OtherKind.allCases)
  func anotherKindGetsNoContext(_ kind: OtherKind) throws {
    let sbd = try Instance()
    let other = try kind.session(sbd)

    try contextConversation(sbd, 250_000)

    #expect(try recorded(sbd, other.id) == [])
    #expect(try sbd.get(other.id).contextTokens == nil)
  }

  // MARK: A new context

  @Test func clearClearsTheContextUntilTheNextTurn() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)
    let next = UUID().uuidString.lowercased()

    try sbd.sb("send", c.id, "clear \(next)")

    try sbd.waitFor(c.id, "the new conversation") { $0.claudeSessionId == next }
    try waitForContext(sbd, c.id, nil)
  }

  /// A plain turn after the clear reads only the new transcript, which has no usage line, so the value stays unset.
  @Test func theTurnAfterAClearRecordsOnlyTheNewContext() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", c.id, "clear \(next)")
    try sbd.waitFor(c.id, "the new conversation") { $0.claudeSessionId == next }
    try sbd.sb("send", c.id, "after the clear")
    try sbd.waitFor(c.id, "the reply after the clear") { $0.lastReply == "Done: after the clear" }
    #expect(try listed(sbd, c.id).contextTokens == nil)

    try sendContext(sbd, c.id, 300_000)

    #expect(try recorded(sbd, c.id) == [250_000, 300_000])
  }

  // MARK: Restart

  @Test func theContextSurvivesARestartOfSbd() throws {
    let sbd = try Instance()
    let c = try contextConversation(sbd, 250_000)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try listed(sbd, c.id).contextTokens == 250_000)
  }
}
