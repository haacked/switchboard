import SwiftUI

extension ReplyOption {
  /// Sends the trimmed text as the option's reply.
  static func submit(_ text: Binding<String>, session: String, ref: String, option number: Int, to model: BoardModel) {
    submit(text) { model.choose(session, ref: ref, option: number, action: .reply, text: $0, sent: $1) }
  }

  /// Hands the trimmed text to `send` with a closure to run once sbd accepts it. The field keeps the text until
  /// then, and empties only if the user didn't change the text meanwhile.
  static func submit(_ text: Binding<String>, send: (String, @escaping () -> Void) -> Void) {
    let sent = trimmed(text.wrappedValue)
    guard !sent.isEmpty else { return }
    send(sent) { if trimmed(text.wrappedValue) == sent { text.wrappedValue = "" } }
  }

  static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
