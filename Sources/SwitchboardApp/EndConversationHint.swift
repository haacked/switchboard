import SwiftUI
import SwitchboardCore

/// The row in a Manager conversation's status strip that suggests ending it, with End Conversation… and a button
/// that dismisses the suggestion.
struct EndConversationHint: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let hint: EndHint
  /// The parent shows the confirmation. This row leaves the screen once sbd stops sending the hint.
  @Binding var ending: ConversationRemovalText?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lightbulb")
        .accessibilityHidden(true)
      Text(hint.text)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      EndConversationButton(session: session, ending: $ending)
        .labelStyle(.titleOnly)
        .fixedSize()
      Button("Dismiss", systemImage: "xmark") { model.dismissEndHint(session.id) }
        .labelStyle(.iconOnly)
        .accessibilityLabel("Dismiss the end suggestion")
        .help("Hide this suggestion until another spawned session is done or the context grows further")
    }
  }
}
