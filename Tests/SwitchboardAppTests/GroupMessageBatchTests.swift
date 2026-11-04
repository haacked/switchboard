import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct GroupMessageBatchTests {
  func card(_ id: Int64, _ session: String, kind: Card.Kind, since: Int64) throws -> Card {
    var json: [String: JSON] = [
      "id": .number(Double(id)), "session": .string(session), "kind": .string(kind.rawValue), "tool": "send_group",
      "summary": "", "input": [:], "questions": [], "since": .number(Double(since)), "deferred": false,
      "hookClosed": false,
    ]
    if kind == .send {
      json["send"] = ["group": "g1", "groupName": "Flags", "text": "Rebase.", "targets": [], "expires": 0]
    }
    return try JSONCoding.convert(JSON.object(json), to: Card.self)
  }

  func session(_ id: String, _ cards: [Card]) -> SessionSummary {
    var s = needsItem(id, card: true)
    s.cards = cards
    return s
  }

  @Test func aSessionWithAGroupMessageShowsEveryOtherGroupMessageAfterItsOwnCardsOldestFirst() throws {
    let a = session("a", [try card(1, "a", kind: .permission, since: 50), try card(2, "a", kind: .send, since: 60)])
    let b = session("b", [try card(3, "b", kind: .send, since: 30)])
    let c = session("c", [try card(4, "c", kind: .send, since: 10), try card(5, "c", kind: .permission, since: 5)])

    #expect(Card.inbox(a, all: [a, b, c]).map(\.id) == [1, 2, 4, 3])
  }

  @Test func aSessionWithoutAGroupMessageShowsOnlyItsOwnCards() throws {
    let a = session("a", [try card(1, "a", kind: .permission, since: 50)])
    let b = session("b", [try card(2, "b", kind: .send, since: 30)])

    #expect(Card.inbox(a, all: [a, b]).map(\.id) == [1])
  }
}
