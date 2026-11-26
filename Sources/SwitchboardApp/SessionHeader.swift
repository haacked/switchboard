import SwiftUI
import SwitchboardCore

/// The top of a session view: the name and state, the reason, and one line of links. The session's actions are in
/// the window toolbar, which `SessionToolbarItems` fills.
struct SessionHeader: View {
  let session: SessionSummary
  /// The group whose conversations a Conversations menu lists, for a group chat whose view has no room for the
  /// conversations column. Nil shows no menu.
  let conversationsMenu: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(session.name).font(.title3.bold())
          .lineLimit(1)
          .truncationMode(.tail)
          .help(session.name)
          .contextMenu { CopyLinkMenuItem(session: session) }
        StateBadge(state: session.state).fixedSize()
        Text(SessionHeaderLine.caption(for: session))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
        Spacer(minLength: 8)
        // The toolbar has no room for Notes at 1024 pt.
        NotesButton(session: session, always: true).fixedSize()
        // These controls truncate or drop to an icon before they push the row past the header's width.
        SessionAccountControl(session: session).lineLimit(1)
        if session.kind.runsInManagerFolder { MCPServerMenu(session: session) }
        if session.kind == .manager { ManagerHeaderControls(session: session) }
        if let group = conversationsMenu { GroupConversationsMenu(group: group, current: session.id) }
      }
      InlineText(plain: session.reason).foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(session.reason)
        .textSelection(.enabled)
      HStack(spacing: 8) {
        ForEach(SessionHeaderLine.links(for: session), id: \.kind) { link($0) }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      CleanupNote(session: session)
      BranchSwitchNote(session: session)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .clickAnchor("session-header")
  }

  /// The branch or folder truncates first, then the PR's line. The repo and the issue never truncate.
  @ViewBuilder private func link(_ item: SessionHeaderLine.Item) -> some View {
    switch item.kind {
    case .repo:
      Text(item.text).fontWeight(.medium).lineLimit(1).fixedSize().help(item.help)
    case .pr:
      HStack(spacing: 4) {
        if let url = item.url { Link(item.text, destination: url).lineLimit(1).help(item.help) }
        if let owners = session.pr?.codeOwners { CodeOwnerShield(status: owners).fixedSize() }
        if let count = session.pr?.commitCount {
          Text("\(count) \(count == 1 ? "commit" : "commits")").fixedSize()
        }
      }
      .layoutPriority(1)
    case .issue:
      IssueBadge(session: session).fixedSize()
    case .branch, .folder:
      Text(item.text)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(item.help)
        .textSelection(.enabled)
    }
  }
}

/// What the header shows beside the name and on its line of links.
enum SessionHeaderLine {
  struct Item: Equatable {
    enum Kind: Hashable { case repo, pr, issue, branch, folder }
    var kind: Kind
    var text: String
    var help: String
    var url: URL?
  }

  /// Whether claude runs, and the permission mode when sbd knows it.
  static func caption(for s: SessionSummary) -> String {
    let run = s.live ? "claude running" : "claude stopped"
    return s.permissionMode.map { "\(run) · \(PermissionMode.title($0)) mode" } ?? run
  }

  /// The repo, the PR, the issue, and the branch, in that order. The folder shows in place of a missing branch, and
  /// names itself in the branch's help otherwise. A PR whose url is not https has no link, so it is left out.
  static func links(for s: SessionSummary) -> [Item] {
    var items: [Item] = []
    if let repo = RepoLabels.label(for: s) {
      items.append(Item(kind: .repo, text: repo, help: "The repo this session works in"))
    }
    if let pr = s.pr, let url = pr.link {
      items.append(Item(kind: .pr, text: pr.line, help: "\(pr.repo): \(pr.title)", url: url))
    }
    if let issues = s.issues, !issues.isEmpty {
      let prRepo = s.pr?.repo
      items.append(
        Item(
          kind: .issue, text: IssueBadge.label(for: issues, prRepo: prRepo),
          help: IssueBadge.tooltip(for: issues, prRepo: prRepo)))
    }
    if let branch = s.branch {
      items.append(Item(kind: .branch, text: branch, help: "Folder: \(s.cwd)"))
    } else {
      items.append(Item(kind: .folder, text: s.cwd, help: "The session's folder"))
    }
    return items
  }
}
