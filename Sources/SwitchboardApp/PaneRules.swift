import CoreGraphics

// Focus, edit-menu, and mouse decisions of the Ghostty pane that need neither libghostty nor a window,
// so unit tests can cover them. GhosttyPane.swift connects them to AppKit and libghostty.

enum PaneFocus {
  enum KeyboardHolder {
    /// The window itself, or no responder.
    case nobody
    case thisPane
    /// A text field or the other pane.
    case someoneElse
  }

  /// libghostty draws the cursor hollow and stops sending focus reports unless this is true.
  static func surfaceIsFocused(windowIsKey: Bool, isFirstResponder: Bool) -> Bool {
    windowIsKey && isFirstResponder
  }

  /// A new Claude pane takes the keyboard when nothing has it. The shell pane waits for a click, and a
  /// pane never takes the keyboard from a text field or from the other pane.
  static func claimsKeyboard(isClaudePane: Bool, keyboardHolder: KeyboardHolder) -> Bool {
    isClaudePane && keyboardHolder == .nobody
  }
}

enum PaneEdit {
  enum Action { case copy, paste, selectAll }

  static func isEnabled(_ action: Action, hasSelection: Bool, pasteboardHasText: Bool) -> Bool {
    switch action {
    case .copy: hasSelection
    case .paste: pasteboardHasText
    case .selectAll: true
    }
  }
}

enum PaneMouse {
  /// Tells libghostty the pointer left the pane, so hover state such as a link underline clears.
  static let exitPosition = CGPoint(x: -1, y: -1)

  /// A program that turned on mouse reporting takes the right click. Otherwise it opens the Copy, Paste, and Select All menu.
  static func rightClickOpensMenu(consumedByTerminal: Bool) -> Bool { !consumedByTerminal }
}
