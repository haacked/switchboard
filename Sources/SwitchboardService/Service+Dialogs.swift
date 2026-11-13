import Foundation
import SwitchboardCore

/// What sbd types into Claude Code's dialog for a card whose hook closed.
enum TypedAnswer {
  /// Picks Yes in a permission dialog.
  case yes
  /// Cancels the dialog. A denial's message or a question's answers then go
  /// to the session as a message.
  case escape(then: String?)
}

extension Service {
  /// Records `dialog_closed` for each card whose dialog left Claude Code's
  /// screen, as `DialogWatch` decides. Claude Code keeps the held request
  /// open after Yes or a pick, and closes it on No and Escape, so an open
  /// request marks the event `allowed`. It captures the screens off the state
  /// queue.
  func closeGoneDialogs() {
    let due: [(id: String, pane: String)] = queue.sync {
      entries.keys.sorted().compactMap { id in
        guard entries[id]?.facts.cards.contains(where: DialogWatch.watches) == true, case .running = claudeState(id)
        else { return nil }
        return (id, paneName(id, .claude))
      }
    }
    guard !due.isEmpty else { return }
    let screens = due.map { ($0.id, try? host.screen($0.pane)) }
    queue.sync {
      for case (let id, let screen?) in screens {
        guard let cards = entries[id]?.facts.cards, let left = entries[id]?.dialogs.check(cards, screen: screen)
        else { continue }
        for card in left {
          var data: [String: JSON] = ["card": .number(Double(card))]
          if let request = held[card], !request.hookGone() { data["allowed"] = true }
          record(id, "dialog_closed", .object(data))
        }
      }
    }
  }

  /// Types the answer into the card's dialog. It refuses when the screen
  /// doesn't show the card's dialog, because the keys would answer another.
  func type(_ answer: TypedAnswer, _ card: Card) throws {
    let (pane, dialog) = try shownDialog(card)
    switch answer {
    case .yes: try pick("Yes", card, pane, dialog, ClaudeScreen.isYes, key: "Up")
    case .escape: try host.press(pane, ["Escape"])
    }
  }

  /// Picks Trust or Exit in the trust card's dialog, then waits up to 3 s for
  /// that dialog to leave. The dialog lists No, exit first and highlights it,
  /// so Enter alone exits claude. Claude can show another startup dialog
  /// after Trust, so only the card's own dialog counts.
  func typeTrust(_ trust: Bool, _ card: Card) throws {
    let (pane, dialog) = try shownDialog(card)
    if trust {
      try pick("Trust", card, pane, dialog, ClaudeScreen.isTrustYes, key: "Down")
    } else {
      try pick("Exit", card, pane, dialog, ClaudeScreen.isTrustNo, key: "Up")
    }
    let deadline = Date() + 3
    while cardDialog(card, pane) != nil {
      if Date() >= deadline { throw APIError("card \(card.id)'s dialog still shows. Answer it in the terminal") }
      usleep(100_000)
    }
  }

  /// The card's pane and the lines of its dialog. It throws why when the
  /// screen doesn't show the card's dialog, because keys would answer another.
  private func shownDialog(_ card: Card) throws -> (pane: String, dialog: [String]) {
    let pane = paneName(card.session, .claude)
    var screen: String?
    if case .running = claudeState(card.session) { screen = try? host.screen(pane) }
    return (pane, try ClaudeScreen.typingDialog(card, screen: screen))
  }

  /// Waits up to 3 s for the card's session to show no dialog, and returns
  /// whether it got there. A paste ends with Enter, and Enter answers any
  /// dialog that still shows. This runs on the state queue.
  func dialogClosed(_ card: Card) -> Bool {
    let pane = paneName(card.session, .claude)
    let deadline = Date() + 3
    while true {
      if let screen = try? host.screen(pane), ClaudeScreen.dialog(screen) == nil { return true }
      if Date() >= deadline { return false }
      usleep(100_000)
    }
  }

  /// Moves the highlight with `key` until it rests on the item that `wanted`
  /// matches, then presses Enter. This runs on the state queue, so it gives
  /// up when Claude Code hasn't moved the highlight there within 1 s, and
  /// presses no Enter.
  private func pick(
    _ name: String, _ card: Card, _ pane: String, _ dialog: [String], _ wanted: (String) -> Bool, key: String
  ) throws {
    let deadline = Date() + 1
    var item = ClaudeScreen.highlighted(dialog)
    while let current = item, !wanted(current), Date() < deadline {
      try host.press(pane, [key])
      repeat {
        usleep(50_000)
        item = cardDialog(card, pane).flatMap(ClaudeScreen.highlighted)
      } while item == current && Date() < deadline
    }
    guard let item, wanted(item) else {
      throw APIError("can't pick \(name) in card \(card.id)'s dialog. Answer it in the terminal")
    }
    try host.press(pane, ["Enter"])
  }

  /// The lines of the card's dialog, or nil when the screen doesn't show it.
  private func cardDialog(_ card: Card, _ pane: String) -> [String]? {
    try? ClaudeScreen.typingDialog(card, screen: try? host.screen(pane))
  }
}
