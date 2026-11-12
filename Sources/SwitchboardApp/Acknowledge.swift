import SwiftUI
import SwitchboardCore

extension SessionSummary {
  /// The title of the button or menu item that acknowledges the item or undoes that.
  var acknowledgeTitle: String { acknowledged == true ? "Undo Acknowledge" : "Acknowledge" }

  /// Whether the session's item only tells the user something: it needs
  /// you, no card or dialog waits for an answer, and it offers no option
  /// and no decisions to step through. An item with options has its own
  /// primary button, and the step view's Next and Submit take ⇧⌘Return.
  var isInformational: Bool {
    guard state == .needsYou, cards.isEmpty, !openPrompt, let item = triage else { return false }
    return item.options.isEmpty && !item.hasDecisionList
  }
}

/// Acknowledge, which takes the session's item out of the Inbox without
/// changing the session, or Undo Acknowledge for an acknowledged session.
struct AcknowledgeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  var primary = false
  /// Drawn as an option's box, as on a decision card, rather than as a plain button.
  var boxed = false

  private var undo: Bool { session.acknowledged == true }

  /// What the button does. It sits among options that send text, so it says that it sends nothing.
  static func detail(undo: Bool) -> String {
    undo
      ? "Puts the session back in the Inbox."
      : "Sends nothing. The item leaves the Inbox until its reason changes or a new turn starts."
  }

  var body: some View {
    let button = Button {
      model.acknowledge(session.id, undo: undo)
    } label: {
      if boxed {
        OptionCardLabel(
          mark: .go, title: session.acknowledgeTitle, description: Self.detail(undo: undo), shortcut: primary)
      } else {
        Text(session.acknowledgeTitle)
      }
    }
    .disabled(model.acknowledging.contains(session.id))
    .help(undo ? Self.detail(undo: true) : "\(Self.detail(undo: false)) (⇧⌘A)")
    .primaryShortcut(primary)
    if boxed { button.buttonStyle(OptionCardStyle(prominent: primary)) } else { button.buttonStyle(.bordered) }
  }
}
