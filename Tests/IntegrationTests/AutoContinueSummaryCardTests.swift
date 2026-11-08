import Foundation
import SwitchboardCore
import Testing

extension AutoContinueTests {
  /// A continue starts a new turn. A new turn drops the card that the session
  /// wrote with `sb summary set`.
  @Test func aSessionWithItsOwnCardIsNotContinued() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    let s = try offerSession(sbd)
    try sbd.setSummary(
      s.id, #"{"summary": "It finished.\nIt needs a call.", "options": [{"label": "Go on", "action": "send"}]}"#)
    try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }
    #expect(try sbd.get(s.id).state == .canContinue)
    try sbd.advanceClock(AutoContinueTests.pastQuiet)
    #expect(try sbd.blocker(s.id) == "an open card")
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
    #expect(try sbd.get(s.id).triage?.source == .session)
  }

  /// Design A test 13. The model's summary of the offer lists decisions, which the user answers first.
  @Test func aSessionWhoseSummaryHasDecisionsIsNotContinued() throws {
    let sbd = try instance()
    try sbd.sb("autocontinue", "on")
    var answer = try #require(JSON.parse(try String(contentsOfFile: decisionsSummaryAnswer, encoding: .utf8))?.object)
    answer["kind"] = "approval"
    answer["options"] = [["label": "Run the tests", "message": "Yes, run the tests.", "recommended": true]]
    try JSON.object(answer).text.write(
      toFile: "\(sbd.home.path)/summary-answer.json", atomically: true, encoding: .utf8)

    let s = try offerSession(sbd)
    try sbd.waitFor(s.id, "the summary's decisions") { $0.triage?.decisions.isEmpty == false }
    try sbd.advanceClock(AutoContinueTests.pastQuiet)

    #expect(try sbd.get(s.id).state == .canContinue)
    #expect(try sbd.blocker(s.id) == "decisions to answer")
    #expect(try sbd.autoContinues(s.id).isEmpty)
    #expect(try sbd.sbdMessages(s.id).isEmpty)
  }
}
