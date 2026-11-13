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
  /// card's when one of the card's marks appears in it. A question's dialog
  /// has no dashed rule. A permission dialog can show a question's mark in
  /// its rows, so a question card never claims a dialog with a dashed rule.
  public static func shows(_ card: Card, _ dialog: [String]) -> Bool {
    if card.kind == .trust { return card.cwd != nil && trustFolder(dialog) == card.cwd }
    guard card.kind == .permission else {
      if dialog.contains(where: isDashedRule) { return false }
      return card.marks.contains { mark in dialog.contains { $0.contains(mark) } }
    }
    if let call = FileCall(card) { return call.shows(dialog, cwd: card.cwd) }
    guard let (shown, command) = commandBlock(card, dialog) else { return false }
    return words(shown.joined(separator: " ")) == words(command)
  }

  /// Whether the dialog may be the card's. `DialogWatch` uses it to decide
  /// which open card a dialog belongs to. Claude Code breaks a token that is
  /// wider than the pane in the middle, so this ignores white space. `shows`
  /// decides what sbd may type. A file tool's `shows` already ignores white
  /// space.
  public static func mayShow(_ card: Card, _ dialog: [String]) -> Bool {
    guard card.kind == .permission, FileCall(card) == nil else { return shows(card, dialog) }
    guard let (shown, command) = commandBlock(card, dialog) else { return false }
    return squeezed(shown.joined()) == squeezed(command)
  }

  /// The card's dialog on the screen, which sbd may type into. It throws why
  /// sbd may not when `shows` rejects the screen's dialog or no dialog
  /// shows. A dialog starts with a full-width rule, so a dialog without one
  /// lost its top lines to the pane's height. The trust dialog shows only a
  /// folder, so any other trust dialog gets the refusal that the terminal
  /// doesn't show the card's dialog.
  public static func typingDialog(_ card: Card, screen: String?) throws -> [String] {
    func notShown() -> APIError {
      APIError("the terminal doesn't show card \(card.id)'s dialog. Answer it in the terminal")
    }
    guard let screen, let dialog = dialog(screen) else { throw notShown() }
    if shows(card, dialog) { return dialog }
    if card.kind == .trust { throw notShown() }
    guard let top = dialog.first, isRule(top) else {
      throw APIError(
        "the top of card \(card.id)'s dialog scrolled off the terminal, so sbd can't check which call it answers. "
          + "Make the terminal taller, or answer it there")
    }
    throw APIError(
      "the terminal shows a dialog that sbd can't match to card \(card.id), such as one whose path the pane cuts. "
        + "Widen the terminal, or answer it there")
  }

  /// The lines between the Bash dialog's two dashed rules, and the card's
  /// command. Every tool's dialog has the dashed rules, so the title must
  /// be Bash's. Claude Code adds a suffix to the title for a command that
  /// runs outside the sandbox or on another machine.
  private static func commandBlock(_ card: Card, _ dialog: [String]) -> (ArraySlice<String>, String)? {
    guard card.findable, let command = card.input["command"]?.string, let block = dashedBlock(dialog),
      let title = block.head.first, title == "Bash command" || title.hasPrefix("Bash command (")
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

  /// The folder that Claude Code's workspace trust dialog names, or nil when
  /// the dialog is another. The title "Accessing workspace:" follows the
  /// dialog's top rule. The folder is the lines after the title up to the
  /// next blank line. Claude Code breaks a path that is wider than the pane
  /// in the middle, so the lines join with no separator.
  public static func trustFolder(_ dialog: [String]) -> String? {
    let lines = dialog.map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count > 2, isRule(lines[0]), lines[1] == "Accessing workspace:" else { return nil }
    let folder = lines[2...].drop { $0.isEmpty }.prefix { !$0.isEmpty }.joined()
    return folder.hasPrefix("/") ? folder : nil
  }

  /// Whether a menu item is the trust dialog's Yes.
  public static func isTrustYes(_ item: String) -> Bool {
    item.range(of: "^(\\d+\\. )?Yes, I trust this folder$", options: .regularExpression) != nil
  }

  /// Whether a menu item is the trust dialog's No, which exits claude.
  public static func isTrustNo(_ item: String) -> Bool {
    item.range(of: "^(\\d+\\. )?No, exit$", options: .regularExpression) != nil
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

  /// Whether Claude Code's prompt box holds no typed text, read from a
  /// screen that `capture-pane -e -J` captured with its colors. The box is
  /// the lines from a line that starts with ❯ and a no-break space down to
  /// the next full-width rule, below the last rule that such a line follows.
  /// A past prompt and a menu item put a plain space after their ❯. Claude
  /// Code draws its placeholder and its prompt suggestion dim (SGR 2), so
  /// dim text does not count as typed. A draft can start on a later line of
  /// the box. Without a box, as while a dialog or a menu shows, the answer
  /// is false.
  public static func promptIsEmpty(_ coloredScreen: String) -> Bool {
    let lines = styledLines(coloredScreen)
    let plain = lines.map { String($0.map(\.char)) }
    guard let top = plain.indices.dropLast().last(where: { isRule(plain[$0]) && plain[$0 + 1].hasPrefix("❯\u{A0}") }),
      let bottom = plain[(top + 1)...].firstIndex(where: isRule)
    else { return false }
    let box = lines[(top + 1)..<bottom].joined().dropFirst()
    return box.allSatisfy { $0.dim || $0.char.isWhitespace }
  }

  /// The screen's lines, each character with whether SGR 2 dims it. The
  /// attributes carry across lines, as tmux prints them.
  static func styledLines(_ screen: String) -> [[(char: Character, dim: Bool)]] {
    var lines: [[(char: Character, dim: Bool)]] = [[]]
    var dim = false
    var chars = screen.makeIterator()
    while let c = chars.next() {
      switch c {
      case "\n":
        lines.append([])
      case "\u{1B}":
        switch chars.next() {
        case "[":
          var body = ""
          while let p = chars.next() {
            if ("\u{40}"..."\u{7E}").contains(p) {
              if p == "m" { sgrDim(body, &dim) }
              break
            }
            body.append(p)
          }
        case "]":
          // An OSC sequence, such as a hyperlink, ends with BEL or ESC \.
          while let p = chars.next(), p != "\u{07}" {
            if p == "\u{1B}" {
              _ = chars.next()
              break
            }
          }
        default:
          break
        }
      default:
        lines[lines.count - 1].append((c, dim))
      }
    }
    return lines
  }

  /// Applies one SGR sequence's parameters to the dim state. The color
  /// parameters 38, 48, and 58 take operands, such as `5;N` or `2;R;G;B`,
  /// which are not attributes.
  private static func sgrDim(_ body: String, _ dim: inout Bool) {
    var params = body.split(separator: ";", omittingEmptySubsequences: false).makeIterator()
    while let p = params.next() {
      switch p {
      case "", "0", "22": dim = false
      case "2": dim = true
      case "38", "48", "58":
        let operands = params.next() == "5" ? 1 : 3
        for _ in 0..<operands { _ = params.next() }
      default: break
      }
    }
  }

  static func isRule(_ line: String) -> Bool {
    line.range(of: "^─{10,}$", options: .regularExpression) != nil
  }

  static func isDashedRule(_ line: String) -> Bool {
    line.range(of: "^╌{10,}$", options: .regularExpression) != nil
  }
}

/// Decides when a card's dialog has left the screen. A check is a miss for a
/// card when the screen shows no dialog, or when `mayShow` gives the dialog
/// to another watched card. A dialog that no watched card may show is not a
/// miss, because it may be the card's own dialog with its title scrolled off
/// or its path cut by a narrow pane. Such a dialog resets the run of misses,
/// so a later miss can't complete a run that began before it. It doesn't
/// count as a sighting either. A card's dialog has left after two misses in a
/// row, when an earlier check showed the dialog or the card's hook closed.
/// The second miss keeps a card through a redraw, such as when a terminal
/// attaches and resizes the pane. A card whose hook is open stays until a
/// check shows its dialog, because Claude Code may not have drawn it yet.
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
    let watched = open.filter(DialogWatch.watches)
    let claims = watched.map { card in dialog.map { ClaudeScreen.mayShow(card, $0) } ?? false }
    let claimed = claims.contains(true)
    var next: [Int64: Sighting] = [:]
    var left: [Int64] = []
    for (card, mayShow) in zip(watched, claims) {
      var s = sightings[card.id] ?? Sighting()
      if mayShow {
        s = Sighting(seen: true, misses: 0)
      } else if dialog != nil, !claimed {
        s.misses = 0
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
