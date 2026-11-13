import SwiftUI
import SwitchboardCore

extension Wait {
  /// The wait's kind, who set it, how long ago, and what happens when it resolves.
  /// `age` is how long ago the wait was set, such as `5m`.
  func caption(age: String) -> String {
    let outcome: String
    switch then {
    case .resume: outcome = "resumes claude"
    case .notify: outcome = "moves to Needs you"
    }
    return [kind.rawValue, by.rawValue, "\(age) ago", outcome].joined(separator: " · ")
  }
}

/// What the session view's side panel shows: the session's open waits and its notes.
struct SidePanel {
  static let width: CGFloat = 240
  static let noWaits = "No open waits."
  static let noNotes = "No notes."

  let waitsTitle: String
  let hasNotes: Bool
  let notesTitle: String
  /// sbd resolves no wait on its own while the session is marked Done. Nil unless such a session has an open wait.
  let doneCaption: String?

  init(_ s: SessionSummary) {
    waitsTitle = Self.title("Waits", s.waits.count)
    hasNotes = !s.notes.isEmpty
    notesTitle = Self.title("Notes", s.notes.count)
    doneCaption =
      s.markedDone && !s.waits.isEmpty ? "Waits don't resolve on their own while the session is marked Done." : nil
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
        if session.waits.isEmpty { Text(SidePanel.noWaits).foregroundStyle(.secondary) }
        ForEach(session.waits, id: \.id) { wait in
          VStack(alignment: .leading, spacing: 2) {
            InlineText(plain: wait.line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(wait.caption(age: ago(wait.created))).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if let caption = panel.doneCaption {
          Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    Text(text).font(.caption.bold()).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
  }
}
