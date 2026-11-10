import Foundation
import SwitchboardCore

extension BoardModel {
  /// Shows the Board in group lanes with its new group name field open.
  func startNewGroup() {
    UserDefaults.standard.set(BoardLanes.group.rawValue, forKey: BoardLanes.storageKey)
    show(.board)
    namingGroup = true
  }

  /// Creates an empty group and closes the name field. When sbd refuses the
  /// name, such as one that another group has, the field stays open.
  func createGroup(_ name: String) {
    perform(
      "group-add", ["name": .string(name)], then: { _ in self.namingGroup = false },
      failed: { self.actionError = "\($0)" })
  }

  /// Deletes a group with no sessions and no plans at once, and asks first about any other group.
  func requestDeleteGroup(_ group: GroupSummary) {
    if GroupDeletion.asks(group) {
      confirmingGroupDelete = group
    } else {
      deleteGroup(group.id)
    }
  }

  /// Deletes the group. sbd moves its sessions to no group and leaves them running.
  func deleteGroup(_ id: String) {
    confirmingGroupDelete = nil
    groups.removeAll { $0.id == id }
    perform("group-rm", ["group": .string(id)])
  }
}
