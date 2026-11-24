import SwitchboardCore

/// What the delete dialog on ContentView shows for the session that `confirmingDelete` holds, and the request that
/// its destructive button sends. It reads only that snapshot, so the request drops and resolves only the items that
/// the dialog lists. A Manager conversation's delete goes through `manager-end`, because `rm-queue` refuses it.
enum DeleteConfirmation {
  case work(SessionSummary, TodoDeletion)
  case conversation(SessionSummary, ConversationRemovalText)

  init(_ s: SessionSummary) {
    self = s.kind == .manager ? .conversation(s, ConversationRemovalText(s, .delete)) : .work(s, TodoDeletion(s))
  }

  var title: String {
    switch self {
    case .work(let s, _): "Delete \(s.name)?"
    case .conversation(_, let text): text.title
    }
  }

  var message: String {
    switch self {
    case .work(let s, let todos): todos.message(before: BoardModel.deletePlan(s).message)
    case .conversation(_, let text): text.message
    }
  }

  var button: String {
    switch self {
    case .work(_, let todos): todos.button("Delete")
    case .conversation(_, let text): text.button
    }
  }

  @MainActor func confirm(_ model: BoardModel) {
    switch self {
    case .work(let s, let todos): model.deleteSession(s, resolve: todos.ids)
    case .conversation(let s, let text): text.confirm(model, s)
    }
  }
}
