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
    /// message that is not a notice and has a time.
    var changed: [SessionSummary]?
  }

  func managerStatus(for conversation: SessionSummary) -> ManagerStatus {
    let work = workBoard
    let cutoff = chatLogs[conversation.id]?.last { $0.role == .user && !$0.isNotice && $0.t != nil }?.t
    return ManagerStatus(
      needsYou: needsUser.count,
      readyToMerge: work.count(where: { $0.state == .readyToMerge }),
      working: work.count(where: { $0.state == .working }),
      // A child that the org filter hides still counts, because choosing it widens the filter.
      changed: cutoff.map { cutoff in
        allBoard.filter { $0.parent == conversation.id && $0.since > cutoff }
          .sorted { ($0.since, $0.id) > ($1.since, $1.id) }
      })
  }
}
