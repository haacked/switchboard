import SwiftUI
import SwitchboardCore

/// A field that sends the session's Claude a message.
struct MessageField: View {
  /// See SessionViewState for why this isn't `@State`.
  final class Draft: ObservableObject {
    @Published var text = ""
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
        .onSubmit(send)
      Button("Send", action: send)
        .keyboardShortcut(shortcut)
        .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func send() {
    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    model.send(session, text)
    draft.text = ""
  }
}
