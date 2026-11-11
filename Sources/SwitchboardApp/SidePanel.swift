import SwiftUI
import SwitchboardCore

/// What the session view's side panel shows: the session's open waits and its notes.
struct SidePanel {
  struct WaitRow: Identifiable, Equatable {
    let id: String
    /// The text the reason line shows for this wait.
    let text: String
    /// Milliseconds since the epoch.
    let created: Int64
    /// The wait's kind, then who set it.
    let detail: [String]
    /// What happens when the wait resolves.
    let outcome: String

    init(_ wait: Wait) {
      id = wait.id
      text = wait.line
      created = wait.created
      detail = [wait.kind.rawValue, wait.by.rawValue]
      switch wait.then {
      case .resume: outcome = "resumes claude"
      case .notify: outcome = "moves to Needs you"
      }
    }

    /// `age` is how long ago the wait was set, such as `5m`.
    func caption(age: String) -> String { (detail + ["\(age) ago", outcome]).joined(separator: " · ") }
  }

  static let width: CGFloat = 240
  static let noWaits = "No open waits."
  static let noNotes = "No notes."

  /// The open waits, oldest first, which is the order sbd gives them in.
  let waits: [WaitRow]
  let waitsTitle: String
  let hasNotes: Bool
  let notesTitle: String
  /// sbd resolves no wait of a session that is marked Done. Nil unless such a session has an open wait.
  let doneNote: String?

  init(_ s: SessionSummary) {
    waits = s.waits.map(WaitRow.init)
    waitsTitle = Self.title("Waits", s.waits.count)
    hasNotes = !s.notes.isEmpty
    notesTitle = Self.title("Notes", s.notes.count)
    doneNote = s.markedDone && !s.waits.isEmpty ? "Waits don't resolve while the session is marked Done." : nil
  }

  private static func title(_ name: String, _ count: Int) -> String { count > 0 ? "\(name) (\(count))" : name }

  /// True when `width` holds the panel beside content that needs `beside` points.
  /// The panel hides otherwise, so it never makes a terminal narrower than its minimum.
  static func fits(width: CGFloat, beside: CGFloat) -> Bool { width >= beside + Self.width }
}

struct SidePanelView: View {
  let session: SessionSummary

  var body: some View {
    let panel = SidePanel(session)
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        title(panel.waitsTitle)
        if panel.waits.isEmpty { Text(SidePanel.noWaits).foregroundStyle(.secondary) }
        ForEach(panel.waits) { row in
          VStack(alignment: .leading, spacing: 2) {
            Text(row.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(row.caption(age: ago(row.created))).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if let note = panel.doneNote {
          Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        title(panel.notesTitle)
        if !panel.hasNotes { Text(SidePanel.noNotes).foregroundStyle(.secondary) }
        NotesList(session: session)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: SidePanel.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityIdentifier("session-side-panel")
  }

  private func title(_ text: String) -> some View {
    Text(text).font(.caption.bold()).foregroundStyle(.secondary)
  }
}
