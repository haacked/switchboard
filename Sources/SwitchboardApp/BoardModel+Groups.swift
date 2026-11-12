import SwiftUI
import SwitchboardCore

extension BoardModel {
  /// The group that ⇧⌘N starts a session in: the group of the ringed card on the Board, else of the current
  /// Inbox item or the selected session. A group chat names its own group.
  var newSessionGroup: GroupSummary? {
    let id = visibleView == .board ? currentBoardCard : acknowledgeTarget?.id
    guard let session = allSessions.first(where: { $0.id == id }) ?? allFollowups.first(where: { $0.id == id }),
      let group = session.chat ?? session.group
    else { return nil }
    return groups.first { $0.id == group }
  }

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
      "group-add", ["name": .string(name)],
      then: { _ in
        self.actionError = nil
        self.namingGroup = false
      },
      failed: { error in
        self.actionError = "\(error)"
        // The field keeps its focus and its text. Without this announcement, VoiceOver says nothing.
        AccessibilityNotification.Announcement("\(error)").post()
      })
  }

  /// Deletes a group with no sessions, no plans, and no open chat at once, and asks first about any other group.
  func requestDeleteGroup(_ group: GroupSummary) {
    if GroupDeletion.asks(group, hasChat: hasOpenChat(group.id)) {
      confirmingGroupDelete = group
    } else {
      deleteGroup(group.id)
    }
  }

  /// True when the group has a chat that is not done. `group-rm` marks that chat done.
  func hasOpenChat(_ group: String) -> Bool { chat(of: group)?.markedDone == false }

  /// Deletes the group. sbd moves its sessions to no group and leaves them running.
  func deleteGroup(_ id: String) {
    confirmingGroupDelete = nil
    groups.removeAll { $0.id == id }
    perform("group-rm", ["group": .string(id)])
  }
}
