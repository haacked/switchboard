import SwiftUI
import SwitchboardCore

/// The list of slash commands that a message field shows while its text is `/` and part of a command name. Each
/// field holds its own, because several views show one draft.
@MainActor
final class SlashCompletion: ObservableObject {
  enum Action: Equatable {
    case move(Int)
    case accept
    case send
    case close
    /// The field takes the key and does nothing.
    case discard
  }

  /// The row that the arrows last moved to. `highlight(in:)` falls back to the first row.
  @Published private var highlighted: String?
  /// The text at which Esc closed the list. It stays closed until the text changes.
  @Published private var dismissed: String?
  /// The key whose down press accepted a row, and the text that the accept gave. The key's repeats do nothing while
  /// the text stays the same.
  private var accepting: (key: KeyEquivalent, text: String)?

  func highlight(in rows: [SlashCommand]) -> String? {
    SearchPanelKeys.current(highlighted, in: rows.map(\.name))
  }

  func move(_ step: Int, in rows: [SlashCommand]) {
    highlighted = ListStep.step(rows.map(\.name), from: highlight(in: rows), by: step, wrap: false)
  }

  /// A changed text or session shows the list again from its first row. The accepted key stays, because the accept
  /// itself changes the text before the key's first repeat.
  func reset() {
    highlighted = nil
    dismissed = nil
  }

  func dismiss(at text: String) { dismissed = text }

  func isOpen(text: String, rows: [SlashCommand], focused: Bool, composing: Bool) -> Bool {
    focused && !composing && !rows.isEmpty && Self.query(text) != nil && dismissed != text
  }

  /// The text after a `/` at the start, while the text holds no whitespace.
  static func query(_ text: String) -> String? {
    guard text.first == "/", !text.contains(where: \.isWhitespace) else { return nil }
    return String(text.dropFirst())
  }

  /// The trailing space ends the query, so the list closes.
  static func accepted(_ name: String) -> String { "/\(name) " }

  /// What a press does to the list. A row is accepted only on a key's down press, so that a held Tab or Return
  /// accepts once and its repeats neither move focus nor send.
  func press(
    _ key: KeyEquivalent, modifiers: EventModifiers, isRepeat: Bool, composing: Bool, open: Bool, text: String,
    highlighted: String?
  ) -> Action? {
    if isRepeat, !composing, let accepting, accepting.key == key, accepting.text == text { return .discard }
    let action = Self.action(
      key: key, modifiers: modifiers, composing: composing, open: open, text: text, highlighted: highlighted)
    // A repeat that would accept is left to the field. Any other repeat keeps its action.
    if isRepeat { return action == .accept ? nil : action }
    accepting = action == .accept ? highlighted.map { (key, Self.accepted($0)) } : nil
    return action
  }

  /// What a key does to the list. Nil leaves the key to the field: every key while the list is closed or an input
  /// method composes, and every key with ⌘, ⌥, ⌃, or ⇧, as `NavKey` decides. Return sends when the text already
  /// names the highlighted row, so `/clear` then Return sends at once.
  static func action(
    key: KeyEquivalent, modifiers: EventModifiers, composing: Bool, open: Bool, text: String, highlighted: String?
  ) -> Action? {
    guard open, !composing, NavKey.isPlain(modifiers), let highlighted else { return nil }
    switch key {
    case .downArrow: return .move(1)
    case .upArrow: return .move(-1)
    case .tab: return .accept
    case .return: return text == "/\(highlighted)" ? .send : .accept
    case .escape: return .close
    default: return nil
    }
  }
}
