import SwitchboardCore

extension BoardModel {
  /// What a Manager conversation's status strip shows. The counts read the org-filtered lists that the Dock
  /// badge and the Board read.
  struct ManagerStatus: Equatable {
    var needsYou: Int
    var readyToMerge: Int
    var working: Int
    /// The sessions that the conversation started and that entered their state after the user's last message
    /// to it, newest first. It is nil while the log has not loaded. It is also nil when the log holds no user
    /// message that has a time and is not a notice or a built-in command's output.
    var changed: [SessionSummary]?
  }

  func managerStatus(for conversation: SessionSummary) -> ManagerStatus {
    let work = workBoard
    let cutoff = chatLogs[conversation.id]?.last {
      $0.role == .user && !$0.isNotice && $0.commandOutput == nil && $0.t != nil
    }?.t
    return ManagerStatus(
      needsYou: needsUser.count,
      readyToMerge: work.count(where: { $0.state == .readyToMerge }),
      working: work.count(where: { $0.state == .working }),
      // A child that the org filter hides still counts, because choosing it widens the filter.
      changed: cutoff.map { cutoff in
        listedBoard.filter { $0.parent == conversation.id && $0.since > cutoff }
          .sorted { ($0.since, $0.id) > ($1.since, $1.id) }
      })
  }

  /// Ends the conversation. With `new`, it opens a new one in its place and selects it. `drop` names the
  /// conversation's own waits, pause condition, and schedules that the user saw in the confirmation. sbd refuses the
  /// end when the conversation holds an id that `drop` does not name, and the refusal shows in the error banner.
  func endConversation(_ s: SessionSummary, new: Bool, drop: [String]) {
    var args: [String: JSON] = ["session": .string(s.id), "drop": .array(drop.map(JSON.string))]
    if new { args["new"] = true }
    perform("manager-end", args) { value in
      if let id = value["started"]?["id"]?.string { self.selectUnlisted(id) }
    }
  }

  /// Hides the conversation's end hint until the hint's key changes, as when another spawned session reaches Done.
  func dismissEndHint(_ id: String) {
    perform("manager-hint", ["session": .string(id), "dismiss": true])
  }
}
