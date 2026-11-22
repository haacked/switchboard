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
        PanelRow.Open(
          url: $0, help: row.link.url, label: "Open link \(row.spokenTitle)", action: { model.openLink(row) })
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

/// The lane link that opens a group's links and its live sessions' links. It draws nothing when there are none.
struct GroupLinksLink: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    let links = LinkRows(group: group, liveSessions: model.sessionsByID)
    if let title = links.linkTitle {
      LanePopoverLink(
        title: title, help: "Show the links of this group and its sessions",
        accessibilityLabel: "\(title) in group \(group.name)", identifier: "group-links-\(group.id)"
      ) {
        ForEach(links.rows) { row in
          LinkRowView(row: row, anchor: "group-link-\(row.owner.id)-\(row.link.id)")
        }
      }
    }
  }
}
