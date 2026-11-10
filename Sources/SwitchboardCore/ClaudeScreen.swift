import Foundation

/// Reads the text of Claude Code's screen, as the terminal host captures it.
/// The rules come from Claude Code 2.1.317's permission and question dialogs.
public enum ClaudeScreen {
  /// The lines of the dialog at the bottom of the screen, or nil when none
  /// shows. Claude Code hides the prompt box while a dialog shows, and every
  /// dialog ends with a footer that offers Esc to cancel. The dialog starts at
  /// the first full-width rule below the conversation. The conversation also
  /// shows the tool call, so its lines are not part of the dialog.
  public static func dialog(_ screen: String) -> [String]? {
    let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let footer = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      lines[footer].contains("Esc to cancel")
    else { return nil }
    let below = lines[..<footer].lastIndex(where: isConversation).map { $0 + 1 } ?? 0
    let start = lines[below..<footer].firstIndex(where: isRule) ?? below
    return Array(lines[start...footer])
  }

  /// Whether the dialog is the card's. A Bash dialog shows its whole command
  /// between two dashed rules, and the command must equal the card's, so
  /// that Yes never approves a command that only starts the same. Claude Code
  /// wraps a long command, so the lines join with a space. Runs of white
  /// space count as one. A file tool's dialog must name the card's file and
  /// show its change, as `FileCall` describes. A question dialog is the
  /// card's when one of the card's marks appears in it.
  public static func shows(_ card: Card, _ dialog: [String]) -> Bool {
    guard card.kind == .permission else {
      return card.marks.contains { mark in dialog.contains { $0.contains(mark) } }
    }
    if let call = FileCall(card) { return call.shows(dialog, cwd: card.cwd) }
    guard let (shown, command) = commandBlock(card, dialog) else { return false }
    return words(shown.joined(separator: " ")) == words(command)
  }

  /// Whether the dialog may be the card's. `DialogWatch` keeps a card while
  /// this holds. Claude Code breaks a token that is wider than the pane in
  /// the middle, so this ignores white space. `shows` decides what sbd may
  /// type. A file tool's `shows` already ignores white space.
  public static func mayShow(_ card: Card, _ dialog: [String]) -> Bool {
    guard card.kind == .permission, FileCall(card) == nil else { return shows(card, dialog) }
    guard let (shown, command) = commandBlock(card, dialog) else { return false }
    return squeezed(shown.joined()) == squeezed(command)
  }

  /// The lines between the Bash dialog's two dashed rules, and the card's
  /// command. Every tool's dialog has the dashed rules, so the title must
  /// be Bash's.
  private static func commandBlock(_ card: Card, _ dialog: [String]) -> (ArraySlice<String>, String)? {
    guard card.findable, let command = card.input["command"]?.string, let block = dashedBlock(dialog),
      block.head.first == "Bash command"
    else { return nil }
    return (block.rows, command)
  }

  /// The lines above a dialog's first dashed rule, without its leading rule
  /// and blank lines, and the lines between its first two dashed rules.
  static func dashedBlock(_ dialog: [String]) -> (head: [String], rows: ArraySlice<String>)? {
    guard let open = dialog.firstIndex(where: isDashedRule),
      let close = dialog[(open + 1)...].firstIndex(where: isDashedRule)
    else { return nil }
    let head = dialog[..<open].map { $0.trimmingCharacters(in: .whitespaces) }.drop { $0.isEmpty || isRule($0) }
    return (Array(head), dialog[(open + 1)..<close])
  }

  /// The text without any white space.
  static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

  private static func words(_ text: String) -> [Substring] {
    text.split(whereSeparator: \.isWhitespace)
  }

  /// The dialog's highlighted menu item, without its ❯ marker.
  public static func highlighted(_ dialog: [String]) -> String? {
    guard let line = dialog.last(where: { $0.range(of: "^ *❯ ", options: .regularExpression) != nil }) else {
      return nil
    }
    return line.replacingOccurrences(of: "^ *❯ ", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Whether a menu item is a permission dialog's plain Yes.
  public static func isYes(_ item: String) -> Bool {
    item.range(of: "^(\\d+\\. )?Yes$", options: .regularExpression) != nil
  }

  /// A line of the conversation: a reply or tool call (⏺), a tool's result
  /// (⎿), or a past prompt (❯). A menu item also starts with ❯, followed by
  /// its number.
  static func isConversation(_ line: String) -> Bool {
    line.range(of: "^(⏺|  ⎿|❯ (?![0-9]+\\. ))", options: .regularExpression) != nil
  }

  static func isRule(_ line: String) -> Bool {
    line.range(of: "^─{10,}$", options: .regularExpression) != nil
  }

  static func isDashedRule(_ line: String) -> Bool {
    line.range(of: "^╌{10,}$", options: .regularExpression) != nil
  }
}

/// Decides when a card's dialog has left the screen. A card's dialog has left
/// when two checks in a row don't show it, and either an earlier check showed
/// it or the card's hook closed. A card whose dialog Claude Code hasn't drawn
/// yet stays. A hook closes only after its dialog was drawn, so a card whose
/// hook closed before any check saw its dialog still goes. The second check
/// keeps a card through a redraw, such as when a terminal attaches and
/// resizes the pane.
public struct DialogWatch: Equatable, Sendable {
  struct Sighting: Equatable, Sendable {
    var seen = false
    var misses = 0
  }

  private var sightings: [Int64: Sighting] = [:]

  public init() {}

  /// Whether a card can show a dialog that sbd finds on the screen.
  public static func watches(_ card: Card) -> Bool { !card.deferred && card.findable }

  /// Takes one screen and the cards that may show on it, and returns the ids
  /// of the cards whose dialog left. It forgets every other card.
  public mutating func check(_ open: [Card], screen: String) -> [Int64] {
    let dialog = ClaudeScreen.dialog(screen)
    var next: [Int64: Sighting] = [:]
    var left: [Int64] = []
    for card in open where DialogWatch.watches(card) {
      var s = sightings[card.id] ?? Sighting()
      if let dialog, ClaudeScreen.mayShow(card, dialog) {
        s = Sighting(seen: true, misses: 0)
      } else {
        s.misses += 1
      }
      if s.misses >= 2 && (s.seen || card.hookClosed) {
        left.append(card.id)
      } else {
        next[card.id] = s
      }
    }
    sightings = next
    return left
  }
}
