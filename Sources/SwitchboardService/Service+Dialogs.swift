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
    let due: [(id: String, pane: String, terminals: TerminalHost)] = queue.sync {
      entries.keys.sorted().compactMap { id in
        guard entries[id]?.facts.cards.contains(where: DialogWatch.watches) == true, case .running = claudeState(id)
        else { return nil }
        guard let terminals = try? site(of: id).terminals() else { return nil }
        return (id, paneName(id, .claude), terminals)
      }
    }
    guard !due.isEmpty else { return }
    let screens = due.map { ($0.id, try? $0.terminals.screen($0.pane)) }
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
    case .escape: try site(of: card.session).terminals().press(pane, ["Escape"])
    }
  }

  /// Waits up to 3 s for the card's session to show no dialog, and returns
  /// whether it got there. A paste ends with Enter, and Enter answers any
  /// dialog that still shows. This runs on the state queue.
  func dialogClosed(_ card: Card) -> Bool {
    let pane = paneName(card.session, .claude)
    guard let terminals = try? site(of: card.session).terminals() else { return false }
    let deadline = Date() + 3
    while true {
      if let screen = try? terminals.screen(pane), ClaudeScreen.dialog(screen) == nil { return true }
      if Date() >= deadline { return false }
      usleep(100_000)
    }
  }

  /// Moves the highlight up to Yes, then presses Enter. Yes is the menu's
  /// first item, so Up moves toward it. This runs on the state queue, so it
  /// gives up when Claude Code hasn't moved the highlight to Yes within 1 s.
  private func pickYes(_ card: Card, _ pane: String, _ dialog: [String]) throws {
    let terminals = try site(of: card.session).terminals()
    let deadline = Date() + 1
    var item = ClaudeScreen.highlighted(dialog)
    while let current = item, !ClaudeScreen.isYes(current), Date() < deadline {
      try terminals.press(pane, ["Up"])
      repeat {
        usleep(50_000)
        item = cardDialog(card, pane).flatMap(ClaudeScreen.highlighted)
      } while item == current && Date() < deadline
    }
    guard let item, ClaudeScreen.isYes(item) else {
      throw APIError("can't pick Yes in card \(card.id)'s dialog. Answer it in the terminal")
    }
    try terminals.press(pane, ["Enter"])
  }

  /// The lines of the card's dialog, or nil when the screen doesn't show it.
  private func cardDialog(_ card: Card, _ pane: String) -> [String]? {
    guard let screen = try? site(of: card.session).terminals().screen(pane), let dialog = ClaudeScreen.dialog(screen),
      ClaudeScreen.shows(card, dialog)
    else { return nil }
    return dialog
  }
}
