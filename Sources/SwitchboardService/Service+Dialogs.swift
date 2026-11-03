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
  /// The delivery of an answer that sbd typed into the terminal.
  static let typed = "terminal"

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
    let pane = paneName(card.session, .claude)
    guard case .running = claudeState(card.session), let dialog = cardDialog(card, pane) else {
      throw APIError("the terminal doesn't show card \(card.id)'s dialog. Answer it in the terminal")
    }
    switch answer {
    case .yes: try pickYes(card, pane, dialog)
    case .escape: try host.press(pane, ["Escape"])
    }
  }

  /// Holds the paste queue until the card's dialog has left the screen, at
  /// most 3 s, so that a message pasted next reaches Claude Code's prompt.
  func afterDialogCloses(_ card: Card) {
    let pane = paneName(card.session, .claude)
    pasteQueue.async { [self] in
      let deadline = Date() + 3
      while Date() < deadline, cardDialog(card, pane) != nil { usleep(100_000) }
    }
  }

  /// Moves the highlight up to Yes, then presses Enter. Yes is the menu's
  /// first item, so Up moves toward it. This runs on the state queue, so it
  /// gives up when Claude Code hasn't moved the highlight to Yes within 1 s.
  private func pickYes(_ card: Card, _ pane: String, _ dialog: [String]) throws {
    let deadline = Date() + 1
    var item = ClaudeScreen.highlighted(dialog)
    while let current = item, !ClaudeScreen.isYes(current), Date() < deadline {
      try host.press(pane, ["Up"])
      repeat {
        usleep(50_000)
        item = cardDialog(card, pane).flatMap(ClaudeScreen.highlighted)
      } while item == current && Date() < deadline
    }
    guard let item, ClaudeScreen.isYes(item) else {
      throw APIError("can't pick Yes in card \(card.id)'s dialog. Answer it in the terminal")
    }
    try host.press(pane, ["Enter"])
  }

  /// The lines of the card's dialog, or nil when the screen doesn't show it.
  private func cardDialog(_ card: Card, _ pane: String) -> [String]? {
    guard let screen = try? host.screen(pane), let dialog = ClaudeScreen.dialog(screen),
      ClaudeScreen.shows(card, dialog)
    else { return nil }
    return dialog
  }
}
