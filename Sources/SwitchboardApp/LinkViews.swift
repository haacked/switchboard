import SwiftUI
import SwitchboardCore

/// One link with its kind's icon, Open, and Remove.
struct LinkRowView: View {
  @EnvironmentObject var model: BoardModel
  let row: LinkRows.Row
  /// The row's click anchor. The Remove button's anchor adds `-remove`.
  let anchor: String

  var body: some View {
    PanelRow(
      icon: PanelRow.Icon(symbol: row.link.kind.symbol, label: row.link.kind.label),
      title: row.title,
      open: URL(string: row.link.url).map {
        PanelRow.Open(url: $0, help: row.link.url, label: "Open link \(row.spokenTitle)")
      },
      caption: row.caption,
      titleLines: 2,
      titleHelp: row.link.url
    ) {
      Button("Remove") { model.removeLink(row) }
        .buttonStyle(.link).font(.caption)
        .help(row.removeHelp)
        .accessibilityLabel("Remove link \(row.spokenTitle)")
        .clickAnchor("\(anchor)-remove")
    }
    .clickAnchor(anchor)
  }
}

/// The lane link that opens a group's links and its live sessions' links, with fields that add a link to the group.
/// A group without links shows it too, so the user can add the first.
struct GroupLinksLink: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    let links = LinkRows(group: group, liveSessions: model.sessionsByID)
    let (help, label) =
      links.rows.isEmpty
      ? ("Add a link, such as an RFC or a design doc", "Add a link to group \(group.name)")
      : ("Show the links of this group and its sessions", "\(links.linkTitle) in group \(group.name)")
    LanePopoverLink(
      title: links.linkTitle, help: help, accessibilityLabel: label,
      identifier: "group-links-\(group.id)"
    ) {
      ForEach(links.rows) { row in
        LinkRowView(row: row, anchor: "group-link-\(row.owner.id)-\(row.link.id)")
      }
      if !links.rows.isEmpty { Divider() }
      GroupLinkForm(group: group.id)
    }
  }
}

/// The fields that add a link to a group.
struct GroupLinkForm: View {
  @EnvironmentObject var model: BoardModel
  let group: String
  @State private var url = ""
  @State private var title = ""

  var body: some View {
    TextField("Link URL", text: $url).onSubmit(add)
    HStack(spacing: 8) {
      TextField("Link title (optional)", text: $title).onSubmit(add)
      Button("Add", action: add)
        .disabled(!hasURL)
        .clickAnchor("add-group-link-\(group)")
    }
  }

  private var hasURL: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func add() {
    guard hasURL else { return }
    let sent = (url, title)
    model.addGroupLink(group, url: url, title: title) {
      // A failed request keeps the text. The user can then fix it and send it again.
      if (url, title) == sent { (url, title) = ("", "") }
    }
  }
}
