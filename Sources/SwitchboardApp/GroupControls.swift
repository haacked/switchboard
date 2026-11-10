import SwiftUI
import SwitchboardCore

/// The row after the Board's group lanes. A "New Group" button opens a name
/// field. Return creates the group, and Escape or Return on a blank name
/// closes the field. A name that sbd refuses keeps the field open.
struct NewGroupRow: View {
  @EnvironmentObject var model: BoardModel
  @State private var name = ""
  @FocusState private var focused: Bool

  var body: some View {
    if model.namingGroup {
      TextField("Group name", text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: BoardView.labelWidth)
        .focused($focused)
        .onAppear { focused = true }
        .onDisappear { name = "" }
        .onSubmit { if isBlank { close() } else { model.createGroup(name) } }
        .onExitCommand(perform: close)
        .onChange(of: focused) { _, now in if !now && isBlank { close() } }
        .accessibilityLabel("New group name")
        .accessibilityIdentifier("new-group-field")
    } else {
      Button {
        model.startNewGroup()
      } label: {
        Label("New Group", systemImage: "plus")
      }
      .buttonStyle(.link)
      .help("Create an empty group, then move sessions into it")
      .accessibilityIdentifier("new-group")
    }
  }

  private var isBlank: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func close() { model.namingGroup = false }
}

extension View {
  /// Asks whether to delete the group in `confirmingGroupDelete`.
  func groupDeleteDialog(_ model: BoardModel) -> some View {
    confirmationDialog(
      "Delete \(model.confirmingGroupDelete?.name ?? "this group")?",
      isPresented: Binding(
        get: { model.confirmingGroupDelete != nil }, set: { if !$0 { model.confirmingGroupDelete = nil } }),
      presenting: model.confirmingGroupDelete
    ) { group in
      Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
    } message: { group in
      Text(GroupDeletion.message(group, hasChat: model.chat(of: group.id) != nil))
    }
  }
}

enum GroupDeletion {
  /// True when the group has sessions or plans. Deleting it moves the sessions and detaches the plans.
  static func asks(_ group: GroupSummary) -> Bool { !group.sessions.isEmpty || !(group.plans ?? []).isEmpty }

  /// What deleting the group does to its sessions, its chat, and its plans.
  static func message(_ group: GroupSummary, hasChat: Bool) -> String {
    var lines: [String] = []
    switch group.sessions.count {
    case 0: break
    case 1: lines.append("Its session moves to Ungrouped and keeps running.")
    case let n: lines.append("Its \(n) sessions move to Ungrouped and keep running.")
    }
    if hasChat { lines.append("Its chat is marked done.") }
    if !(group.plans ?? []).isEmpty { lines.append("Switchboard detaches its plans. The plan documents stay.") }
    return lines.joined(separator: " ")
  }
}
