import AppKit

/// Shift+Return in the Claude terminal. SwiftTerm sends the same CR for Shift+Return as for Return. Claude Code
/// submits the prompt on CR. Claude Code inserts a new line on ESC CR, which is what its `/terminal-setup`
/// configures in other terminals. tmux passes ESC CR through as Alt+Enter whatever key mode the pane's program
/// asked for. A CSI u Shift+Return reaches the program only while it has asked for extended keys, and otherwise
/// tmux turns it into a plain CR.
enum TerminalReturnKey {
  static let newline: [UInt8] = [0x1b, 0x0d]

  /// Whether the key is a Shift+Return that should send `newline`. Keypad Enter keeps its CR. While an input
  /// method holds marked text, Return belongs to it. In the kitty keyboard protocol, SwiftTerm encodes
  /// Shift+Return itself.
  static func sendsNewline(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool, kittyKeyboard: Bool)
    -> Bool
  {
    keyCode == 36 && !composing && !kittyKeyboard
      && modifiers.intersection([.shift, .control, .option, .command]) == .shift
  }
}
