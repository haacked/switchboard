import SwitchboardCore

/// What the delete dialog on ContentView shows for the session that `confirmingDelete` holds, and the request that
/// its destructive button sends. It reads only that snapshot, so the request resolves only the to-dos that the
/// dialog lists.
struct DeleteConfirmation {
  let session: SessionSummary
  let title: String
  let message: String
  let button: String
  private let todos: TodoDeletion

  init(_ s: SessionSummary) {
    session = s
    todos = TodoDeletion(s)
    title = "Delete \(s.name)?"
    message = todos.message(before: BoardModel.deletePlan(s).message)
    button = todos.button("Delete")
  }

  @MainActor func confirm(_ model: BoardModel) {
    model.deleteSession(session, resolve: todos.ids)
  }
}
