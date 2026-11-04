import SwiftUI
import SwitchboardCore

/// A field that sends the session's Claude a message.
struct MessageField: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Draft: ObservableObject {
    @Published var text = ""

    /// Sends the trimmed text and empties the field once sbd accepts it, unless the user changed it meanwhile.
    @MainActor func submit(_ session: String, to model: BoardModel) {
      let sent = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sent.isEmpty else { return }
      model.send(session, sent) { [weak self] in self?.clear(ifStill: sent) }
    }

    /// Empties the field unless the user changed it after `sent` was sent.
    func clear(ifStill sent: String) {
      if text.trimmingCharacters(in: .whitespacesAndNewlines) == sent { text = "" }
    }
  }

  @EnvironmentObject var model: BoardModel
  let session: String
  var shortcut: KeyboardShortcut?
  @StateObject private var draft = Draft()

  var body: some View {
    HStack {
      TextField("Message Claude…", text: $draft.text, axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        .onKeyPress(.return, phases: .down) { press in
          // SwiftUI calls this before the input method sees the key. The check for marked text has to happen here.
          let editor = NSApp.keyWindow?.firstResponder as? NSTextView
          switch Self.keyAction(modifiers: press.modifiers, composing: editor?.hasMarkedText() == true) {
          case .send:
            send()
          case .newline:
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
          case nil:
            return .ignored
          }
          return .handled
        }
      Button("Send", action: send)
        .keyboardShortcut(shortcut)
        .disabled(
          model.sending.contains(session)
            || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func send() { draft.submit(session, to: model) }

  enum KeyAction { case send, newline }

  /// What Return does in the field. Nil leaves the key to the field. Return then confirms an input
  /// method's marked text, Option+Return inserts a new line, and Command+Return reaches the Send
  /// button's shortcut.
  static func keyAction(modifiers: EventModifiers, composing: Bool) -> KeyAction? {
    guard !composing else { return nil }
    switch modifiers.intersection([.shift, .command, .option, .control]) {
    case []: return .send
    case .shift: return .newline
    default: return nil
    }
  }
}
