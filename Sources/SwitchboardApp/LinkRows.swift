import Foundation
import SwitchboardCore

extension LinkKind {
  /// No SF Symbol shows a brand, so each kind gets a generic one.
  var symbol: String {
    switch self {
    case .slack: "number"
    case .linear: "checkmark.circle"
    case .notion: "doc.text"
    case .google: "doc.richtext"
    case .grafana: "chart.xyaxis.line"
    case .web: "link"
    }
  }

  var label: String {
    switch self {
    case .slack: "Slack"
    case .linear: "Linear"
    case .notion: "Notion"
    case .google: "Google"
    case .grafana: "Grafana"
    case .web: "Web"
    }
  }
}

/// What a list of links shows: one row per link, newest first. The side panel lists a session's links. A Board
/// lane's popover lists its group's links and its live sessions' links.
struct LinkRows {
  enum Owner: Equatable {
    case session(String)
    case group(String)

    var id: String {
      switch self {
      case .session(let id), .group(let id): id
      }
    }
  }

  struct Row: Equatable, Identifiable {
    var link: ExternalLink
    var owner: Owner
    /// The owner as the group's list names it: "group" or the session's name. It is nil in the side panel, which
    /// lists one session's links.
    var ownerName: String? = nil
    var caption: String

    var title: String { LinkRows.title(link) }

    /// The title for VoiceOver. It names the owner, because two rows of the group's list can share a title.
    var spokenTitle: String { ownerName.map { "\(title) from \($0)" } ?? title }

    /// Two sessions that find the same page get the same link id, so the row id also names the owner.
    var id: String { "\(owner.id)/\(link.id)" }

    /// The text of Remove's tooltip. sbd hides a found link and deletes an added one. When it deletes an added
    /// link, it also hides a found link to the same page.
    var removeHelp: String {
      link.by == .found
        ? "Hide this link. Switchboard won't add it again unless you add it by hand."
        : "Remove this link from the list."
    }
  }

  let rows: [Row]

  init(session: SessionSummary, now: Int64 = nowMs()) {
    rows = Self.sorted(
      (session.links ?? []).map {
        Self.row($0, owner: .session(session.id), now: now)
      })
  }

  /// The group's own links, less those that list among its artifacts, and the links of each member that
  /// `liveSessions` holds. `liveSessions` maps a session id to the session.
  init(group: GroupSummary, liveSessions: [String: SessionSummary], now: Int64 = nowMs()) {
    let own = (group.links ?? []).filter { GroupArtifact(link: $0) == nil }.map {
      Self.row($0, owner: .group(group.id), ownerName: "group", now: now)
    }
    let members = group.sessions.compactMap { liveSessions[$0] }.flatMap { s in
      (s.links ?? []).map {
        Self.row($0, owner: .session(s.id), ownerName: s.name, now: now)
      }
    }
    rows = Self.sorted(own + members)
  }

  /// The lane link's title, such as `Links 2`, or nil when there are no rows.
  var linkTitle: String? { rows.isEmpty ? nil : "Links \(rows.count)" }

  /// The link's title, or a short form when sbd filled the title in from the URL: the title that the link's kind
  /// gives, else the URL's host and path.
  static func title(_ link: ExternalLink) -> String {
    guard link.title == (try? ExternalLink.cleanTitle(nil, url: link.url)) else { return link.title }
    if let target = link.linkTarget { return target.title }
    guard let parts = URLComponents(string: link.url), let host = parts.host else { return link.title }
    let path = parts.path == "/" ? "" : parts.path
    return oneLine(host + path, max: ExternalLink.titleLimit)
  }

  /// The caption starts with the owner's name when there is one.
  private static func row(_ link: ExternalLink, owner: Owner, ownerName: String? = nil, now: Int64) -> Row {
    let caption = link.caption(now: now)
    return Row(
      link: link, owner: owner, ownerName: ownerName, caption: ownerName.map { "\($0) · \(caption)" } ?? caption)
  }

  private static func sorted(_ rows: [Row]) -> [Row] {
    rows.sorted { ($1.link.t, $0.owner.id, $0.link.id) < ($0.link.t, $1.owner.id, $1.link.id) }
  }
}
