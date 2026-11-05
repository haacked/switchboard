import SwiftUI
import SwitchboardCore

extension SessionSummary {
  /// Whether the user can acknowledge the session's item, or undo that.
  var canAcknowledge: Bool { acknowledged == true || AttentionState.inbox.contains(state) }

  /// The title of the button or menu item that acknowledges the item or undoes that.
  var acknowledgeTitle: String { acknowledged == true ? "Undo Acknowledge" : "Acknowledge" }

  /// Whether the session's item only tells the user something: it needs
  /// you, no card or dialog waits for an answer, and it offers no option.
  /// An item with options has its own primary button.
  var isInformational: Bool {
    guard state == .needsYou, cards.isEmpty, !openPrompt, let item = triage else { return false }
    return item.options.isEmpty
  }
}

/// Acknowledge, which takes the session's item out of the Inbox without
/// changing the session, or Undo Acknowledge for an acknowledged session.
struct AcknowledgeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  var primary = false

  private var undo: Bool { session.acknowledged == true }

  var body: some View {
    let button = Button(session.acknowledgeTitle) { model.acknowledge(session.id, undo: undo) }
      .disabled(model.acknowledging.contains(session.id))
      .help(
        undo
          ? "Put the session back in the Inbox"
          : "Mark it as seen. It leaves the Inbox until its reason changes or a new turn starts (⇧⌘A)")
    if primary {
      button.buttonStyle(.borderedProminent).keyboardShortcut(OptionButton.primaryShortcut)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}
