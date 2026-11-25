import Foundation
import SwitchboardCore

/// How the Loops view orders its rows. Both orders keep the loops that need attention on top.
enum LoopSort: String, CaseIterable {
  /// Core's attention order: failed, overdue, due, active, held, then paused.
  case status
  /// By session name, then the attention order.
  case session

  var title: String {
    switch self {
    case .status: "Status"
    case .session: "Session"
    }
  }
}

/// One loop in the Loops view, with its session and its status.
struct LoopRow: Identifiable {
  let session: SessionSummary
  let schedule: Schedule
  let status: ScheduleStatus

  var id: String { schedule.id }

  static func attentionOrder(_ a: LoopRow, _ b: LoopRow) -> Bool {
    ScheduleStatus.attentionOrder((a.status, a.schedule), (b.status, b.schedule))
  }

  func caption(now: Int64) -> ScheduleCaption {
    ScheduleCaption(schedule, status: status, hold: session.scheduleHold, now: now)
  }
}

extension SessionSummary {
  /// The name, with the host when the session runs on one, as the Loops view and the loop editor show it.
  var nameWithHost: String { host.map { "\(name) · \($0)" } ?? name }
}

extension BoardModel {
  /// The shown sessions that have a loop, by name. The Loops view's session filter lists them.
  var loopSessions: [SessionSummary] {
    sessions.filter { !$0.allSchedules.isEmpty }.sorted(by: Self.byName)
  }

  /// `loopSessionFilter` while a shown session with that id has a loop, else nil. A filter whose session lost its
  /// last loop therefore lists every loop.
  var loopSessionChoice: String? {
    loopSessionFilter.flatMap { id in loopSessions.contains { $0.id == id } ? id : nil }
  }

  /// The loops of the shown sessions that `loopSessionChoice` picks, in `loopSort`'s order.
  func loopRows(now: Int64) -> [LoopRow] {
    let choice = loopSessionChoice
    let rows = allLoopRows(now: now).filter { choice == nil || $0.session.id == choice }
    switch loopSort {
    case .status:
      return rows.sorted(by: LoopRow.attentionOrder)
    case .session:
      return rows.sorted { a, b in
        if a.status.needsAttention != b.status.needsAttention { return a.status.needsAttention }
        if a.session.id != b.session.id { return Self.byName(a.session, b.session) }
        return LoopRow.attentionOrder(a, b)
      }
    }
  }

  /// The loops of the sessions that the filter hides. The Loops view's empty state names them.
  var hiddenLoopCount: Int {
    let filter = filter
    return allSessions.filter { !$0.isBeingRemoved && !filter.shows($0) }
      .reduce(0) { $0 + $1.allSchedules.count }
  }

  /// The loops of every shown session that need attention. The tab's session filter does not change it.
  func loopAttentionCount(now: Int64) -> Int {
    allLoopRows(now: now).filter(\.status.needsAttention).count
  }

  /// The loop that an Edit… request names, from every listed session, or nil for New Loop… or a loop that is gone.
  func editedSchedule(_ request: LoopEditorRequest) -> Schedule? {
    guard case .edit(let id) = request else { return nil }
    return allSessions.lazy.flatMap(\.allSchedules).first { $0.id == id }
  }

  /// The focused loop while the list shows it, else the first row.
  var currentLoop: LoopRow? { currentLoop(in: loopRows(now: nowMs())) }

  func currentLoop(in rows: [LoopRow]) -> LoopRow? {
    rows.first { $0.id == loopFocus } ?? rows.first
  }

  func moveLoop(by step: Int, wrap: Bool = true) {
    let rows = loopRows(now: nowMs())
    guard let next = ListStep.step(rows.map(\.id), from: currentLoop(in: rows)?.id, by: step, wrap: wrap) else {
      return
    }
    loopFocus = next
    loopJumps += 1
  }

  /// Selects the session of a loop or of an activity entry. The operator has no sidebar row, so it opens its
  /// transcript instead.
  func showLoopSession(_ session: SessionSummary) {
    if session.kind == .operator { openOperator() } else { showInSidebar(session) }
  }

  /// Reads the operator's newest activity events off the main thread. With no operator, the list empties.
  func loadBackgroundActivity() {
    guard let id = operatorSession?.id else {
      if !backgroundActivity.isEmpty { backgroundActivity = [] }
      return
    }
    let send = send
    let args: [String: JSON] = [
      "session": .string(id), "kinds": .array(BackgroundActivity.kinds.map(JSON.string)),
      "limit": .number(Double(BackgroundActivity.limit)),
    ]
    Task { [weak self] in
      let events = await Task.detached { try? JSONCoding.convert(send("events", args), to: [Event].self) }.value
      guard let self, let events else { return }
      let entries = BackgroundActivity.entries(events)
      if backgroundActivity != entries { backgroundActivity = entries }
    }
  }

  private func allLoopRows(now: Int64) -> [LoopRow] {
    sessions.flatMap { session in
      let hold = session.scheduleHold
      return session.allSchedules.map {
        LoopRow(session: session, schedule: $0, status: ScheduleStatus($0, hold: hold, now: now))
      }
    }
  }

  static func byName(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
    switch a.name.localizedStandardCompare(b.name) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.id < b.id
    }
  }
}
