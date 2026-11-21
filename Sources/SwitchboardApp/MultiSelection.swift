import SwiftUI
import SwitchboardCore

extension BoardModel {
  /// The sidebar's `List(selection:)`. It shows `multiSelection` while that holds two or more ids, and the set
  /// of `selection` otherwise. A Board selection of one card does not show. A click on a row that already shows
  /// as the only selected one changes nothing, so the setter would not run and the row would not open. A set
  /// with two or more ids replaces `multiSelection` and leaves `selection` alone, so it records no history. A
  /// set with one id or none ends the multi-selection and sets `selection`.
  var sidebarSelection: Binding<Set<String>> {
    Binding(
      get: { self.showsMultiSelection ? self.multiSelection : Set(self.selection.map { [$0] } ?? []) },
      set: { ids in
        if ids.count > 1 {
          self.setMultiSelection(ids)
          return
        }
        if !self.multiSelection.isEmpty { self.multiSelection = [] }
        if self.selection != ids.first { self.selection = ids.first }
      })
  }

  var showsMultiSelection: Bool { multiSelection.count > 1 }

  /// Whether the detail pane shows `MultiSelectionView`. The Board shows its own selection in place.
  var showsMultiSelectionPane: Bool { showsMultiSelection && visibleView != .board }

  /// The multi-selected sessions in the order the sidebar lists them. It includes rows in collapsed sections
  /// and rows that the sidebar's search field hides, because the Board selects cards that the field hides.
  var multiSelected: [SessionSummary] { sidebarRows.filter { multiSelection.contains($0.id) } }

  /// The number of multi-selected sessions that a work-scope plan can delete. sbd skips the others.
  var removableSelectionCount: Int { multiSelected.filter(\.isRemovableWork).count }

  private var sidebarRows: [SessionSummary] {
    let c = conversations
    return c.pinned + c.active + c.archived + Self.sidebarGroups(workBoard).flatMap { $0.rows.map(\.session) }
  }

  /// Sets `multiSelection` to `ids`, the ids that are still listed after a refresh or a filter change. With
  /// `onBoard`, the Board showed before the refresh, so `ids` stay its selection and `selection` stays nil,
  /// which keeps the Board showing. Otherwise one id left becomes `selection`, as the sidebar's set with one id
  /// makes it. With two or more left and no `selection`, the first of them in the sidebar becomes `selection`
  /// first, because setting `selection` empties `multiSelection`. History and the Session menu then still have
  /// a session.
  func keepMultiSelection(_ ids: Set<String>, onBoard: Bool) {
    if !onBoard, ids.count == 1 {
      selection = ids.first
      return
    }
    if !onBoard, ids.count > 1, selection == nil {
      selection = sidebarRows.first { ids.contains($0.id) }?.id ?? ids.min()
    }
    setMultiSelection(ids)
  }

  /// Sets `multiSelection` only when `ids` differ, so an equal set publishes no change.
  func setMultiSelection(_ ids: Set<String>) {
    if multiSelection != ids { multiSelection = ids }
  }
}

/// The detail pane while the sidebar selects two or more sessions.
struct MultiSelectionView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let sessions = model.multiSelected
    VStack(spacing: 12) {
      Text(DoneRemovalText.selected(sessions.count)).font(.title2.bold())
      DeleteSelectedButton(count: sessions.filter(\.isRemovableWork).count)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(sessions) { session in
            HStack {
              Text(session.name).lineLimit(1)
              Spacer()
              StateBadge(state: session.state)
            }
          }
        }
        .frame(maxWidth: 420)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Asks sbd for a plan to delete the multi-selection, and shows it in the removal sheet.
struct DeleteSelectedButton: View {
  @EnvironmentObject var model: BoardModel
  let count: Int

  var body: some View {
    Button(role: .destructive) {
      model.checkSelectionRemoval()
    } label: {
      Label(DoneRemovalText.deleteSessions(count), systemImage: "trash")
    }
    .buttonStyle(.borderless)
    .disabled(count == 0 || model.showingDoneRemoval)
    .help("Delete the selected sessions, with their worktrees, and their branches when the PR merged…")
    .clickAnchor("delete-selected")
  }
}
