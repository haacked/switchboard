import SwiftUI
import SwitchboardCore

extension Wait {
  /// The wait's kind, who set it, how long ago, and what happens when it resolves.
  /// `age` is how long ago the wait was set, such as `5m`.
  func caption(age: String) -> String {
    [kind.rawValue, by.rawValue, "\(age) ago", then.outcome].joined(separator: " · ")
  }
}

extension Wait.Then {
  /// What sbd does when the wait resolves, such as "resumes claude".
  var outcome: String {
    switch self {
    case .resume: "resumes claude"
    case .notify: "moves to Needs you"
    case .caller: "ends sb wait --block"
    }
  }
}

/// What the session view's side panel shows: the session's open waits, its schedules, its notes, its artifacts, and
/// its links.
struct SidePanel {
  static let width: CGFloat = 240
  static let noWaits = "No open waits."
  static let noNotes = "No notes."
  static let noArtifacts = "No artifacts."
  static let noLinks = "No links."

  let waitsCount: Int
  /// The panel leaves out the Schedules section of a session without a schedule.
  /// Schedules come from `sb schedule` and the MCP tools, so an empty section would offer nothing to do.
  let showsSchedules: Bool
  let schedulesCount: Int
  let hasNotes: Bool
  let notesCount: Int
  /// sbd resolves no wait and runs no schedule while the session is marked Done.
  /// Nil unless such a session has an open wait or a schedule.
  let doneCaption: String?
  /// The title counts only the artifacts that no delete removed.
  let artifactsCount: Int
  /// True when the session lists any artifact, a removed one included.
  let hasArtifacts: Bool
  let artifacts: [SessionArtifact]
  let links: [LinkRows.Row]

  init(_ s: SessionSummary, now: Int64 = nowMs()) {
    let schedules = s.schedules ?? []
    waitsCount = s.waits.count
    showsSchedules = !schedules.isEmpty
    schedulesCount = schedules.count
    hasNotes = !s.notes.isEmpty
    notesCount = s.notes.count
    doneCaption =
      s.markedDone && !(s.waits.isEmpty && schedules.isEmpty)
      ? "Waits and schedules don't run on their own while the session is marked Done." : nil
    artifacts = (s.artifacts ?? []).newestFirst
    hasArtifacts = !artifacts.isEmpty
    artifactsCount = artifacts.count(where: { $0.removed == nil })
    links = LinkRows(session: s, now: now).rows
  }

  /// True when `width` holds the panel beside content that needs `beside` points.
  /// The panel hides otherwise, so it never makes a terminal narrower than its minimum.
  static func fits(width: CGFloat, beside: CGFloat) -> Bool { width >= beside + Self.width }
}

struct SidePanelView: View {
  @Environment(\.sessionNames) private var names
  let session: SessionSummary

  var body: some View {
    let panel = SidePanel(session)
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ListSectionHeader(title: "Waits", count: panel.waitsCount, inset: false)
        if session.waits.isEmpty { Text(SidePanel.noWaits).foregroundStyle(.secondary) }
        ForEach(session.waits, id: \.id) { wait in
          VStack(alignment: .leading, spacing: 2) {
            InlineText(wait.lineText(names: names)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(wait.caption(age: ago(wait.created))).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if panel.showsSchedules {
          Divider()
          ListSectionHeader(title: "Schedules", count: panel.schedulesCount, inset: false)
          ScheduleList(session: session)
        }
        if let caption = panel.doneCaption {
          Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        ListSectionHeader(title: "Notes", count: panel.notesCount, inset: false)
        if !panel.hasNotes { Text(SidePanel.noNotes).foregroundStyle(.secondary) }
        NotesList(session: session)
        Divider()
        ListSectionHeader(title: "Artifacts", count: panel.artifactsCount, inset: false)
        if !panel.hasArtifacts { Text(SidePanel.noArtifacts).foregroundStyle(.secondary) }
        ForEach(panel.artifacts, id: \.url) { artifact in
          PanelRow(
            title: artifact.title,
            open: artifact.removed == nil
              ? URL(string: artifact.url).map {
                PanelRow.Open(url: $0, help: artifact.url, label: "Open artifact \(artifact.title)")
              } : nil,
            caption: artifact.caption())
        }
        Divider()
        ListSectionHeader(title: "Links", count: panel.links.count, inset: false)
        if panel.links.isEmpty { Text(SidePanel.noLinks).foregroundStyle(.secondary) }
        ForEach(panel.links) { row in
          LinkRowView(row: row, anchor: "panel-link-\(row.link.id)")
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: SidePanel.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityIdentifier("session-side-panel")
    .clickAnchor("session-side-panel")
  }
}
