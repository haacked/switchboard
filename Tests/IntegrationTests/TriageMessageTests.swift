import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct TriageMessageTests {
  private let sections = ["summary", "action", "details"]

  /// A session that holds a permission prompt for `touch x`.
  private func held(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.new(prompt: "perm touch x")
    return try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty && $0.triage != nil }
  }

  @Test func triageJSONCarriesTheThreeSectionsOfAPermissionCard() throws {
    let sbd = try Instance()
    let s = try held(sbd)

    let list = try #require(JSON.parse(try sbd.sb("triage", "--json"))?.array)

    let message = try #require(list.first { $0["id"]?.string == s.id }?["triage"]?["message"])
    #expect(Set(message.object?.keys.map { $0 } ?? []) == Set(sections))
    #expect(message["summary"]?["text"]?.string == "Claude asks to run `touch x`.")
    #expect(
      message["action"]?["options"]?.array?.compactMap { $0["label"]?.string } == [
        "Allow", "Deny", PermissionMode.approveLabel,
      ])
    #expect(message["action"]?["primary"]?.int == 0)
    #expect(message["details"]?["toolInput"]?["tool"]?.string == "Bash")
    #expect(message["details"]?["toolInput"]?["text"]?.string == "touch x")
    #expect(message["details"]?["openByDefault"]?.bool == false)
  }

  @Test func getAndLsCarryTheSameMessageAsTriage() throws {
    let sbd = try Instance()
    let s = try held(sbd)

    let fromTriage = try #require(try sbd.triage().first { $0.id == s.id }?.triage?.message)
    let fromGet = try #require(
      try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("get", "--json", s.id)).triage?.message)
    let fromLs = try #require(
      try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json")).first { $0.id == s.id }?
        .triage?.message)

    #expect(fromGet == fromTriage)
    #expect(fromLs == fromTriage)
  }

  @Test func theMCPTriageToolReturnsTheSameSections() throws {
    let sbd = try Instance()
    let s = try held(sbd)
    let mcp = try MCPClient(sbd)

    let listed = try mcp.call("triage").decode([SessionSummary].self)

    let message = try #require(listed.first { $0.id == s.id }?.triage?.message)
    #expect(message == (try #require(try sbd.triage().first { $0.id == s.id }?.triage?.message)))
    #expect(message.summary.text == "Claude asks to run `touch x`.")
  }

  @Test func aSessionCardKeepsThreeSummaryLinesAndTheReplyInDetails() throws {
    let sbd = try Instance()
    let s = try sbd.endedSession()
    let card = JSON.object([
      "summary": "One.\nTwo.\nThree.\nFour.",
      "options": [["label": "Go on", "action": "send", "message": "Go on.", "recommended": true]],
    ])

    let result = try sbd.setSummary([s.id], card.text)

    #expect(result.status == 0)
    #expect(result.stdout.contains("lines after the first 3 of the summary"))
    let message = try #require(
      try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }.triage?.message)
    #expect(message.summary.text == "One.\nTwo.\nThree.")
    #expect(message.action.options.map(\.label) == ["Go on"])
    #expect(message.action.primary == 0)
    #expect(message.details.lastReply == "Done: hello")
  }

  @Test func theTextListingNamesTheSectionsInOrder() throws {
    let sbd = try Instance()
    _ = try held(sbd)

    let text = try sbd.sb("triage")

    let headings = ["Summary:", "Action:", "Details:"].map { text.range(of: $0)?.lowerBound }
    #expect(headings.allSatisfy { $0 != nil })
    #expect(headings.compactMap { $0 } == headings.compactMap { $0 }.sorted())
    #expect(text.contains("Details: tool input"))
  }

  @Test func lsJSONKeepsTheFlatFieldsBesideTheMessage() throws {
    let sbd = try Instance()
    let s = try held(sbd)

    let list = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)

    let triage = try #require(list.first { $0["id"]?.string == s.id }?["triage"])
    for key in ["title", "kind", "summary", "options", "callouts", "multiSelect", "decisions", "source", "ref"] {
      #expect(triage[key] != nil, "\(key)")
    }
    #expect(triage["summary"] == triage["message"]?["summary"]?["text"])
    #expect(triage["options"] == triage["message"]?["action"]?["options"])
    #expect(triage["callouts"] == triage["message"]?["summary"]?["callouts"])
    #expect(triage["multiSelect"] == triage["message"]?["action"]?["multiSelect"])
  }

  @Test func aDecisionListIsInTheActionAndTheTextNamesSbDecide() throws {
    let sbd = try Instance()
    let s = try sbd.decisionSession()

    let message = try #require(
      try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("get", "--json", s.id)).triage?.message)
    #expect(message.action.decisions.map(\.header) == ["Database", "Name", "Icons"])

    let text = try sbd.sb("triage")
    #expect(text.contains("3 decisions, answered one at a time: sb decide \(s.id)"))
    #expect(!text.contains("none, except Acknowledge: sb ack \(s.id)"))
  }
}
