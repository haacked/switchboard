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
        .onSubmit(send)
      Button("Send", action: send)
        .keyboardShortcut(shortcut)
        .disabled(
          model.sending.contains(session)
            || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func send() { draft.submit(session, to: model) }
}
