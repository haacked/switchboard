import SwiftUI
import SwitchboardCore

/// The lane link that opens a group's notes in the order they were added. It draws nothing when the group has no
/// notes.
struct GroupNotesLink: View {
  let group: GroupSummary

  var body: some View {
    if !group.notes.isEmpty {
      let title = "Notes \(group.notes.count)"
      LanePopoverLink(
        title: title, help: "Show the notes on this group", accessibilityLabel: "\(title) in group \(group.name)",
        identifier: "group-notes-\(group.id)"
      ) {
        ForEach(group.notes, id: \.id) { note in
          NoteRow(note: note).clickAnchor("group-note-\(note.id)")
        }
      }
    }
  }
}
