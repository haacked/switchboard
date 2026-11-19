import SwiftUI
import SwitchboardCore

/// What a group's artifact list shows: one row per artifact in sbd's order, and the lane link's title.
struct GroupArtifactRows {
  enum Action: Equatable {
    case useAsPlan
    /// One of the group's artifact plans names the artifact.
    case plan
    case removed
  }

  struct Row: Equatable, Identifiable {
    var artifact: GroupArtifact
    var sessionLabel: String
    var caption: String
    var action: Action

    var id: String { artifact.url }
  }

  let rows: [Row]
  /// The link's title, such as `Artifacts 2`, which counts the artifacts that no delete removed. The title leaves out a
  /// count of zero. It is nil when the group has no artifacts.
  let linkTitle: String?

  /// `liveNames` maps each live session's id to its current name. A removed session's row keeps its own name.
  init(group: GroupSummary, liveNames: [String: String], now: Int64 = nowMs()) {
    let artifacts = group.artifacts ?? []
    let planLinks = (group.plans ?? []).compactMap { $0.source.kind == .artifact ? $0.source.url : nil }
    rows = artifacts.map { artifact in
      // A plan stays attached after a delete removes its artifact, so "Plan" wins over "Removed".
      let action: Action =
        planLinks.contains(where: artifact.names) ? .plan : artifact.removed == nil ? .useAsPlan : .removed
      return Row(
        artifact: artifact, sessionLabel: "by \(liveNames[artifact.session] ?? artifact.sessionName)",
        caption: artifact.caption(now: now), action: action)
    }
    linkTitle = Self.linkTitle(group)
  }

  static func linkTitle(_ group: GroupSummary) -> String? {
    guard let artifacts = group.artifacts, !artifacts.isEmpty else { return nil }
    let live = artifacts.count(where: { $0.removed == nil })
    return live > 0 ? "Artifacts \(live)" : "Artifacts"
  }
}

/// The lane link that opens a group's artifact list. It draws nothing when the group has no artifacts.
struct GroupArtifactsLink: View {
  let group: GroupSummary

  var body: some View {
    if let title = GroupArtifactRows.linkTitle(group) {
      GroupLaneLink(
        title: title, help: "Show the artifacts that this group's sessions published",
        label: "\(title) in group \(group.name)", id: "group-artifacts-\(group.id)", width: 420
      ) { GroupArtifactList(group: group) }
    }
  }
}

/// A group's artifacts in the popover, each with Use as plan, Plan, or Removed.
struct GroupArtifactList: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    let names = Dictionary(model.allSessions.map { ($0.id, $0.name) }) { first, _ in first }
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(GroupArtifactRows(group: group, liveNames: names).rows) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              // The title is untrusted text from the tool result, so it never renders as Markdown.
              if row.artifact.removed == nil, let url = URL(string: row.artifact.url) {
                Button {
                  NSWorkspace.shared.open(url)
                } label: {
                  Text(verbatim: row.artifact.title)
                }
                .buttonStyle(.link)
                .help(row.artifact.url)
              } else {
                Text(verbatim: row.artifact.title)
              }
              Text(verbatim: "\(row.sessionLabel) · \(row.caption)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            action(row)
          }
        }
      }
      .padding(12)
    }
    .frame(maxHeight: 360)
  }

  @ViewBuilder private func action(_ row: GroupArtifactRows.Row) -> some View {
    switch row.action {
    case .useAsPlan:
      Button("Use as plan") { model.useArtifactAsPlan(url: row.artifact.url, group: group.id) }
        .controlSize(.small)
        .disabled(model.isUsingAsPlan(url: row.artifact.url, group: group.id))
        .help("Attach the artifact as this group's plan. The group's chat reads it, which may start the chat.")
        .accessibilityLabel("Use \(row.artifact.title) as plan")
    case .plan:
      Text("Plan").font(.caption).foregroundStyle(.secondary)
    case .removed:
      Text("Removed").font(.caption).foregroundStyle(.secondary)
    }
  }
}
