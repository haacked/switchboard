import SwiftUI
import SwitchboardCore

extension BoardModel {
  /// The group that ⇧⌘N starts a session in: the group of the ringed card on the Board, else of the current
  /// Inbox item or the selected session. A chat's group is the one it manages.
  var newSessionGroup: GroupSummary? {
    let session = visibleView == .board ? allBoard.first { $0.id == currentBoardCard } : acknowledgeTarget
    guard let group = session?.chat ?? session?.group else { return nil }
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
      then: { result in
        self.actionError = nil
        self.namingGroup = false
        self.showAnsweredGroup(result)
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

  /// Makes a description that Claude wrote the user's: sbd saves the same text with `by: you`. The Board shows the
  /// new author before sbd answers.
  func acceptGroupDescription(_ id: String) {
    guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].descriptionBy == .claude,
      let text = groups[index].description
    else { return }
    groups[index].descriptionBy = .you
    perform("group-describe", ["group": .string(id), "text": .string(text), "by": .string(Author.you.rawValue)])
  }

  /// Adds a link to the group. A blank title leaves sbd to use the URL. `added` runs once sbd stores the link. It
  /// sends nothing and reports why when sbd would refuse the URL or the title.
  func addGroupLink(_ id: String, url: String, title: String, added: (() -> Void)? = nil) {
    var args: [String: JSON] = ["group": .string(id), "by": .string(Author.you.rawValue)]
    do {
      let clean = try GroupLink.cleanURL(url)
      args["url"] = .string(clean)
      let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty { args["title"] = .string(try GroupLink.cleanTitle(title, url: clean)) }
    } catch {
      actionError = "\(error)"
      return
    }
    perform("group-link-add", args, then: { _ in added?() })
  }

  func removeGroupLink(_ id: String, link: String) {
    perform("group-link-rm", ["group": .string(id), "link": .string(link), "by": .string(Author.you.rawValue)])
  }
}
