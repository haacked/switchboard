import AppKit
import SwiftUI

/// The shortcuts that move between the app's lists and terminals. The Session menu lists them.
///
/// Each one carries ⌘, because a focused terminal keeps every other key. SwiftTerm offers a ⌘ key to the
/// menu bar before the terminal's program, as long as `shouldSendCommandKeyToTerminal` stays nil.
enum NavShortcuts {
  /// A US keyboard sends ⇧⌘] as "}" with ⌘ and ⇧. A menu item that stores "]" with ⇧⌘ does not match that
  /// event, so these store the shifted characters, as Safari's Show Next Tab does.
  static let nextSession = KeyboardShortcut("}", modifiers: .command)
  static let previousSession = KeyboardShortcut("{", modifiers: .command)
  static let focusList = KeyboardShortcut("l", modifiers: .command)
  static let focusTerminal = KeyboardShortcut("t", modifiers: .command)

  static let all = [nextSession, previousSession, focusList, focusTerminal]
}

enum BoardDirection: Equatable {
  case up, down, left, right
}

enum NavAction: Equatable {
  case move(BoardDirection)
  case open
}

enum NavKey {
  /// The move or open that a plain arrow or Return asks for. A key with ⌘, ⌥, ⌃, or ⇧ gives nil, so menu
  /// shortcuts and text selection keep it. SwiftUI adds the function and numeric pad flags to arrow keys,
  /// so only those four modifiers count.
  static func action(_ key: KeyEquivalent, modifiers: EventModifiers) -> NavAction? {
    guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return nil }
    switch key {
    case .upArrow: return .move(.up)
    case .downArrow: return .move(.down)
    case .leftArrow: return .move(.left)
    case .rightArrow: return .move(.right)
    case .return: return .open
    default: return nil
    }
  }
}

/// The list that ⌘L focuses.
enum ListFocus: Equatable {
  case sidebar, inbox, board
}

enum ListStep {
  /// The id `step` places from `current`. With `wrap`, the step goes around the ends, else it stops at them.
  /// A `current` that is nil or not in `ids` acts as a place before the first id for a forward step and after
  /// the last id for a backward one.
  static func step(_ ids: [String], from current: String?, by step: Int, wrap: Bool) -> String? {
    guard !ids.isEmpty else { return nil }
    let n = ids.count
    let i = current.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : n)
    let next = wrap ? ((i + step) % n + n) % n : min(max(i + step, 0), n - 1)
    return ids[next]
  }
}

/// The Board's open cards as `lanes[lane][column]`, each cell a stack of card ids from top to bottom.
struct BoardGrid: Equatable {
  var lanes: [[[String]]]

  /// Lane by lane, column by column, top to bottom in a cell.
  var readingOrder: [String] { lanes.flatMap { $0.flatMap { $0 } } }
  var first: String? { readingOrder.first }
  var last: String? { readingOrder.last }

  func contains(_ id: String) -> Bool { position(of: id) != nil }

  /// The card an arrow moves to from `id`.
  ///
  /// - ↓ and ↑ move through the stack. Past its end, they go to the nearest lane in that direction that has
  ///   a card, to the cell in the same column or else the nearest column with cards, where a tie goes left.
  /// - ← and → go to the nearest column in that direction with cards, in the same lane, at the same stack
  ///   index clamped to the cell's last card.
  /// - A move with nowhere to go stays on `id`. A nil or unknown `id` gives the first card for ↓ and →, and
  ///   the last card for ↑ and ←.
  func move(from id: String?, _ direction: BoardDirection) -> String? {
    guard let id, let (lane, column, index) = position(of: id) else {
      return direction == .down || direction == .right ? first : last
    }
    let cell = lanes[lane][column]
    switch direction {
    case .down:
      if index + 1 < cell.count { return cell[index + 1] }
      for row in lanes[(lane + 1)...] {
        if let c = Self.nearestColumn(in: row, to: column) { return row[c].first }
      }
    case .up:
      if index > 0 { return cell[index - 1] }
      for row in lanes[..<lane].reversed() {
        if let c = Self.nearestColumn(in: row, to: column) { return row[c].last }
      }
    case .left, .right:
      let row = lanes[lane]
      let columns =
        direction == .right ? Array(row.indices.dropFirst(column + 1)) : Array(row.indices.prefix(column).reversed())
      if let c = columns.first(where: { !row[$0].isEmpty }) { return row[c][min(index, row[c].count - 1)] }
    }
    return id
  }

  private func position(of id: String) -> (lane: Int, column: Int, index: Int)? {
    for (l, row) in lanes.enumerated() {
      for (c, cell) in row.enumerated() {
        if let i = cell.firstIndex(of: id) { return (l, c, i) }
      }
    }
    return nil
  }

  private static func nearestColumn(in row: [[String]], to column: Int) -> Int? {
    row.indices.filter { !row[$0].isEmpty }.min { (abs($0 - column), $0) < (abs($1 - column), $1) }
  }
}

extension View {
  /// Takes keyboard focus each time the model asks the list `list` to take it.
  func takesListFocus(_ list: ListFocus, _ focused: FocusState<Bool>.Binding, model: BoardModel) -> some View {
    onChange(of: model.listFocusRequests) {
      guard model.listFocusTarget == list else { return }
      // A terminal is an AppKit first responder that SwiftUI's focus state does not track. The state can
      // therefore still read true while the terminal has the keys, and setting it to true again does nothing.
      NSApp.keyWindow?.makeFirstResponder(nil)
      focused.wrappedValue = false
      DispatchQueue.main.async { focused.wrappedValue = true }
    }
  }
}
