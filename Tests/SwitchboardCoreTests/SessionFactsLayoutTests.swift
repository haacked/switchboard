import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct SessionFactsLayoutTests {
  /// sbd evaluates `SessionFacts` by value on server threads with 512 KB stacks.
  @Test func sessionFactsStaysSmallEnoughForServerThreads() {
    #expect(MemoryLayout<SessionFacts>.size <= 2560)
  }

  @Test func theHeldAskEncodesAsTheAskItself() throws {
    let decisions = [1, 2].map {
      PendingDecision(number: $0, header: "D\($0)", question: "Which?", options: [.init(label: "A")])
    }
    let item = TriageItem(
      title: "Pick one", kind: .decision, summary: "Two choices", decisions: decisions, source: .rule, ref: "rule:x")
    let ask = DecisionAsk(
      ref: "rule:x", number: 2, askId: "q1", text: "Why A?", message: "Question about decision 2",
      verdict: .init(state: .needsYou, reason: "Pick one"), item: item)
    var facts = SessionFacts()
    #expect(try JSON(encoding: facts)["heldAsk"] == nil)

    facts.apply(
      Event(
        id: 1, session: "s1", t: 0, kind: "decisions_opened",
        data: ["decisions": try JSON(encoding: decisions), "ref": "rule:x"]))
    facts.apply(Event(id: 2, session: "s1", t: 1, kind: "decision_asked", data: try JSON(encoding: ask)))

    #expect(try JSON(encoding: facts)["heldAsk"] == JSON(encoding: ask))
    let decoded = try JSONCoding.convert(facts, to: SessionFacts.self)
    #expect(decoded == facts)
  }
}
