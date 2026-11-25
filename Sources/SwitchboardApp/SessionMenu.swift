import SwiftUI
import SwitchboardCore

/// An action of a session row's context menu. `divider` separates the destructive actions that follow it.
enum SessionMenuAction: Hashable {
  case highlight
  case snooze
  case copyLink
  case notes
  case rename
  case pause
  case resume
  case startNow
  case stop
  case moveToAccount
  case unlinkParent(String)
  case divider
  case cleanUp
  case delete(String)
  case deleteSelection(count: Int)
}

enum SessionMenu {
  /// The actions in menu order: the non-destructive ones, then a divider and the destructive ones, with the delete
  /// last. `selectionCount` is the removable count of the sidebar's multi-selection when the row belongs to it, and
  /// nil otherwise. A row in a multi-selection offers to delete the selection instead of the row alone. A session
  /// whose delete failed offers no Delete, because its Inbox item has Retry and Keep. A docket row offers Delete
  /// only in Done, because the confirmation describes a session that runs claude in a worktree. A Manager
  /// conversation and a group chat's conversation offer Rename, and Delete through `manager-end`. The Operator
  /// offers neither.
  /// `movesAccount` is true when the session can move to another account. `parentName` names the parent that the
  /// session can be unlinked from, and is nil when it has none.
  static func actions(
    for s: SessionSummary, selectionCount: Int?, movesAccount: Bool = false, parentName: String? = nil
  ) -> [SessionMenuAction] {
    var safe: [SessionMenuAction] = []
    if HighlightMenuItem.title(for: s) != nil { safe.append(.highlight) }
    if s.canSnooze { safe.append(.snooze) }
    safe.append(.copyLink)
    safe.append(.notes)
    if s.kind.isUserConversation { safe.append(.rename) }
    if s.pause != nil {
      safe.append(.resume)
    } else if s.canPause {
      safe.append(.pause)
    }
    if s.queued == true { safe.append(.startNow) }
    if s.live && s.pause == nil { safe.append(.stop) }
    if movesAccount { safe.append(.moveToAccount) }
    if let parentName { safe.append(.unlinkParent("Unlink from \(parentName)")) }
    var destructive: [SessionMenuAction] = []
    if CleanupOffer.canCleanUp(s) { destructive.append(.cleanUp) }
    if let selectionCount {
      destructive.append(.deleteSelection(count: selectionCount))
    } else if s.removal == nil && (s.isRemovableDone || (s.isRemovableWork && s.docket == nil)) {
      destructive.append(.delete("Delete \(BoardModel.deletePlan(s).summary)…"))
    } else if s.removal == nil && s.kind.isUserConversation {
      destructive.append(.delete(ConversationRemovalText.deleteTitle))
    }
    return destructive.isEmpty ? safe : safe + [.divider] + destructive
  }

  /// The `selectionCount` that row `id` passes to `actions`. A row gets `removableSelection` back only when it
  /// belongs to a multi-selection.
  static func selectionCount(
    for id: String, removableSelection: Int?, showsMultiSelection: Bool, multiSelection: Set<String>
  ) -> Int? {
    guard let removableSelection, showsMultiSelection, multiSelection.contains(id) else { return nil }
    return removableSelection
  }
}

/// The context menu items that every session row shares: the actions before the divider, the row's `extra` items,
/// and then the destructive actions. Delete… opens the delete confirmation on ContentView.
struct SessionMenuItems<Extra: View>: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  /// The removable count of the sidebar's multi-selection, which the sidebar reads once for every row.
  var removableSelection: Int? = nil
  @ViewBuilder var extra: () -> Extra

  var body: some View {
    let selectionCount = SessionMenu.selectionCount(
      for: session.id, removableSelection: removableSelection, showsMultiSelection: model.showsMultiSelection,
      multiSelection: model.multiSelection)
    let actions = SessionMenu.actions(
      for: session, selectionCount: selectionCount,
      movesAccount: SessionAccountMenu.shows(session, accountCount: model.sessionAccounts.count),
      parentName: model.linkedParentName(of: session))
    let split = actions.firstIndex(of: .divider) ?? actions.endIndex
    ForEach(actions[..<split], id: \.self, content: item)
    extra()
    ForEach(actions[split...], id: \.self, content: item)
  }

  @ViewBuilder private func item(_ action: SessionMenuAction) -> some View {
    let id = session.id
    switch action {
    case .highlight:
      HighlightMenuItem(session: session)
    case .snooze:
      SnoozeMenuItems(session: session)
    case .copyLink:
      CopyLinkMenuItem(session: session)
    case .notes:
      Button("Notes…") { model.editingNotes = id }
    case .rename:
      Button("Rename…") { model.renaming = id }
    case .pause:
      PauseMenuItems(id: id)
    case .resume:
      Button("Resume") { model.resume(id) }.help(PauseBanner.resumeHelp)
    case .startNow:
      Button("Start Now") { model.startNow(id) }
        .disabled(model.startingNow.contains(id))
        .help(BoardModel.startNowHelp)
    case .stop:
      Button("Stop Claude") { model.stop(id) }.help(BoardModel.stopHelp)
    case .moveToAccount:
      Menu("Move to Account") { MoveToAccountMenuItems(session: session) }
    case .unlinkParent(let title):
      Button(title) { model.unlinkParent(id) }.help(BoardModel.unlinkHelp)
    case .divider:
      Divider()
    case .cleanUp:
      Button("Clean Up: Delete the Worktree and Branch…") { model.confirmingCleanup = id }
        .disabled(model.cleaningUp.contains(id))
    case .delete(let title):
      Button(title, role: .destructive) { model.confirmingDelete = session }
        .disabled(model.deleting.contains(id))
    case .deleteSelection(let count):
      Button(DoneRemovalText.deleteSessions(count), role: .destructive) { model.checkSelectionRemoval() }
        .disabled(count == 0 || model.showingDoneRemoval)
    }
  }
}

extension SessionMenuItems where Extra == EmptyView {
  init(session: SessionSummary, removableSelection: Int? = nil) {
    self.init(session: session, removableSelection: removableSelection) { EmptyView() }
  }
}
