import SwiftUI

extension ReplyOption {
  /// Sends the trimmed text as the option's reply. The field keeps the text until sbd accepts the reply.
  /// It then empties unless the user changed the text meanwhile.
  static func submit(_ text: Binding<String>, session: String, ref: String, option number: Int, to model: BoardModel) {
    let sent = trimmed(text.wrappedValue)
    guard !sent.isEmpty else { return }
    model.choose(session, ref: ref, option: number, action: .reply, text: sent) {
      if trimmed(text.wrappedValue) == sent { text.wrappedValue = "" }
    }
  }

  static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
