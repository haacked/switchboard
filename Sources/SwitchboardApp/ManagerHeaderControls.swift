import SwiftUI
import SwitchboardCore

/// The controls in a Manager conversation's header that the Operator and group chats don't show.
struct ManagerHeaderControls: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var ending: ConversationRemovalText?

  var body: some View {
    Button("New Task", systemImage: "plus") { model.openNewSession(parent: session.id) }
      .help("Start a session that this conversation follows")
      .fixedSize()
    // The name shrinks before the button drops to its icon.
    EndConversationButton(session: session, ending: $ending)
      .layoutPriority(1)
      .endConversationDialog($ending, session: session)
  }
}

/// End Conversation…, which sets the confirmation that `endConversationDialog` shows.
struct EndConversationButton: View {
  let session: SessionSummary
  /// The confirmation as it was when the user pressed the button. The end drops only the ids that it lists, so a
  /// wait that lands while the dialog is open makes sbd refuse the end instead of dropping the wait unseen.
  @Binding var ending: ConversationRemovalText?

  private static let title = "End Conversation…"
  private static let icon = "stop.circle"

  var body: some View {
    Button {
      ending = ConversationRemovalText(session, .end)
    } label: {
      // A header too narrow for the title shows only the icon.
      ViewThatFits(in: .horizontal) {
        Label(Self.title, systemImage: Self.icon)
        Label(Self.title, systemImage: Self.icon).labelStyle(.iconOnly)
      }
    }
    .help("Remove this conversation and open a new one in its place")
  }
}

extension View {
  /// The confirmation that ends the conversation and opens a new one in its place. SwiftUI closes a dialog whose
  /// view leaves the screen. So attach it to a view that stays on screen while the dialog is open.
  func endConversationDialog(_ ending: Binding<ConversationRemovalText?>, session: SessionSummary) -> some View {
    modifier(EndConversationDialog(ending: ending, session: session))
  }
}

private struct EndConversationDialog: ViewModifier {
  @EnvironmentObject var model: BoardModel
  @Binding var ending: ConversationRemovalText?
  let session: SessionSummary

  private var isConfirming: Binding<Bool> {
    Binding(get: { ending != nil }, set: { if !$0 { ending = nil } })
  }

  func body(content: Content) -> some View {
    content.confirmationDialog(
      ending?.title ?? "", isPresented: isConfirming, titleVisibility: .visible, presenting: ending
    ) { text in
      Button(text.button, role: .destructive) { model.endConversation(session, new: true, drop: text.drop) }
    } message: { text in
      Text(text.message)
    }
  }
}

/// The confirmation that End Conversation shows for a conversation's summary.
struct ConversationRemovalText: Equatable {
  enum Mode { case end }

  var title: String
  var message: String
  var button: String
  /// The ids of the conversation's own waits, its pause condition, and its schedules, in the order that the message
  /// lists them. sbd refuses the end while the conversation holds one of these that the request does not name.
  var drop: [String]

  init(_ s: SessionSummary, _ mode: Mode) {
    let dropped = s.ownItems
    var parts = [
      "A new conversation opens in its place with the same account, MCP servers, and pin. "
        + "The transcript stays on disk."
    ]
    if !dropped.isEmpty {
      parts.append("Ending drops:\n" + dropped.map { "• \($0.line)" }.joined(separator: "\n"))
    }
    if let handed = s.handedWaits, !handed.isEmpty {
      let waits = handed.count == 1 ? "1 wait" : "\(handed.count) waits"
      parts.append("The \(Manager.operatorName) keeps following \(waits) that this conversation handed it.")
    }
    if !s.cards.isEmpty {
      parts.append(s.cards.count == 1 ? "1 open request closes." : "\(s.cards.count) open requests close.")
    }

    title = "End \(s.name)?"
    message = parts.joined(separator: "\n\n")
    button = "End Conversation"
    drop = dropped.map(\.id)
  }
}
