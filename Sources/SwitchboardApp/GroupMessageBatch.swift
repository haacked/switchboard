import SwiftUI
import SwitchboardCore

extension Card {
  /// The cards that the Inbox shows for a session: its own, and when it has a
  /// group message, every other session's open group message after them,
  /// oldest first.
  static func inbox(_ session: SessionSummary, all: [SessionSummary]) -> [Card] {
    guard session.cards.contains(where: { $0.kind == .send }) else { return session.cards }
    let others = all.filter { $0.id != session.id }.flatMap(\.cards).filter { $0.kind == .send }
    return session.cards + others.sorted { $0.since < $1.since }
  }
}

/// Sends or cancels several group messages at once. Each card shows below
/// it, so the user reads every message first.
struct GroupMessageBatch: View {
  @EnvironmentObject var model: BoardModel
  let cards: [Card]

  var body: some View {
    if cards.count > 1 {
      HStack {
        Text("\(cards.count) group messages wait for you").font(.headline)
        Spacer()
        Button("Send All") { for card in cards { model.answer(card, behavior: "allow") } }
        Button("Cancel All") { for card in cards { model.answer(card, behavior: "deny") } }
      }
    }
  }
}
