import AppKit
import SwiftUI

extension View {
  /// Return calls `send`, and Shift+Return inserts a new line at the cursor. Use it on a text field with a vertical
  /// axis, which shows up to four lines of the text.
  func sendsOnReturn(_ send: @escaping () -> Void) -> some View { modifier(ReturnKey(send: send)) }
}

struct ReturnKey: ViewModifier {
  let send: () -> Void

  func body(content: Content) -> some View {
    content
      .lineLimit(1...4)
      // The key handler does not see keypad Enter, which sends here. An input method that passes Return on after composing also sends here.
      .onSubmit(send)
      // The handler also takes key repeats. A held Shift+Return would otherwise reach onSubmit and send.
      .onKeyPress(.return, phases: [.down, .repeat]) { press in
        // SwiftUI calls this before the input method sees the key. The check for marked text has to happen here.
        switch Self.action(modifiers: press.modifiers, composing: Self.editorIsComposing) {
        case .send:
          send()
        case .newline:
          Self.editor?.insertNewlineIgnoringFieldEditor(nil)
        case nil:
          return .ignored
        }
        return .handled
      }
  }

  /// The field editor of the window that the key went to. An app that is not active has no key window.
  private static var editor: NSTextView? {
    (NSApp.currentEvent?.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView
  }

  /// Whether an input method holds marked text in the focused field.
  static var editorIsComposing: Bool { editor?.hasMarkedText() == true }

  enum Action { case send, newline }

  /// What Return does in the field. Nil leaves the key to the field. On Return while composing, the
  /// field confirms the input method's marked text. On Option+Return, it inserts a new line.
  /// Command+Return reaches a Send button's shortcut.
  static func action(modifiers: EventModifiers, composing: Bool) -> Action? {
    guard !composing else { return nil }
    switch modifiers.intersection([.shift, .command, .option, .control]) {
    case []: return .send
    case .shift: return .newline
    default: return nil
    }
  }
}
