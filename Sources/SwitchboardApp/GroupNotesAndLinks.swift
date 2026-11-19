import AppKit
import SwiftUI
import SwitchboardCore

/// The lane link that opens a group's notes. It draws nothing when the group has no notes.
struct GroupNotesLink: View {
  let group: GroupSummary

  var body: some View {
    if !group.notes.isEmpty {
      let title = "Notes \(group.notes.count)"
      GroupLaneLink(
        title: title, help: "Show the notes on this group", label: "\(title) in group \(group.name)",
        id: "group-notes-\(group.id)", width: 340
      ) { GroupNoteList(group: group) }
    }
  }
}

/// A group's notes in the order they were added.
struct GroupNoteList: View {
  let group: GroupSummary

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(group.notes, id: \.id) { note in
          NoteRow(note: note).clickAnchor("group-note-\(note.id)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .frame(maxHeight: 360)
  }
}

/// The lane link that opens a group's links. A group without links shows it too, so the user can add the first.
struct GroupLinksLink: View {
  let group: GroupSummary

  var body: some View {
    let count = group.links?.count ?? 0
    let (title, help, label) =
      count > 0
      ? ("Links \(count)", "Show, add, and remove this group's links", "Links \(count) in group \(group.name)")
      : ("Add a link", "Add a link, such as an RFC or a design doc", "Add a link to group \(group.name)")
    GroupLaneLink(title: title, help: help, label: label, id: "group-links-\(group.id)", width: 360) {
      GroupLinkList(group: group)
    }
  }
}

/// A group's links, each with a remove button, and the fields that add one.
struct GroupLinkList: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary
  @State private var url = ""
  @State private var title = ""

  var body: some View {
    let links = group.links ?? []
    VStack(alignment: .leading, spacing: 8) {
      ForEach(links) { link in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Button {
            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
          } label: {
            Text(verbatim: link.title).lineLimit(1).truncationMode(.middle)
          }
          .buttonStyle(.link)
          .help(link.url)
          Spacer(minLength: 0)
          Button {
            model.removeGroupLink(group.id, link: link.id)
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Remove this link from the group")
          .accessibilityLabel("Remove the link \(link.title)")
          .clickAnchor("group-link-rm-\(link.id)")
        }
      }
      if !links.isEmpty { Divider() }
      TextField("Link URL", text: $url).onSubmit(add)
      HStack(spacing: 8) {
        TextField("Link title (optional)", text: $title).onSubmit(add)
        Button("Add", action: add)
          .disabled(!hasURL)
          .clickAnchor("group-link-add-\(group.id)")
      }
    }
    .padding(12)
  }

  private var hasURL: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func add() {
    guard hasURL else { return }
    let sent = (url, title)
    model.addGroupLink(group.id, url: url, title: title) {
      // A failed request keeps the text. The user can then fix it and send it again.
      if (url, title) == sent { (url, title) = ("", "") }
    }
  }
}
