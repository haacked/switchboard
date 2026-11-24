import Foundation
import SwitchboardCore

/// One account in a session's Move to Account menu.
struct SessionAccountEntry: Identifiable, Equatable {
  var folder: String
  /// The account's name and usage, as the account menu's tooltip reads it.
  var title: String
  /// The session runs under this account.
  var checked: Bool
  var disabled: Bool
  /// Why the entry is disabled.
  var help: String?
  var id: String { folder }
}

/// The group whose account a session follows. sbd refuses to move the session
/// to any other account.
struct GroupLock: Equatable {
  var groupID: String
  var groupName: String
  var folder: String
  var accountName: String { Account.name(ofFolder: folder) }
  var line: String { "Its group, \(groupName), runs on \(accountName). Change the group's account instead." }
}

/// The entries of a session's Move to Account menu. They mirror the refusals
/// of sbd's `account-move`, which still decides each move.
enum SessionAccountMenu {
  /// A host session runs under the host's Claude login, and a session that
  /// has not started has no conversation to move.
  static func shows(_ s: SessionSummary, accountCount: Int) -> Bool {
    accountCount > 1 && s.host == nil && !s.cwd.isEmpty
  }

  /// The group's account, by sbd's rule: a group chat follows the group it
  /// belongs to, and a work session follows its own group.
  static func groupLock(for s: SessionSummary, groups: [GroupSummary]) -> GroupLock? {
    guard let id = s.chat ?? s.group, let group = groups.first(where: { $0.id == id }), let folder = group.account
    else { return nil }
    return GroupLock(groupID: id, groupName: group.name, folder: folder)
  }

  static func entries(
    for s: SessionSummary, accounts: [AccountInfo], usage: [AccountUsage], groups: [GroupSummary]
  ) -> [SessionAccountEntry] {
    let current = s.account.map(ClaudeAccount.init(folder:))
    let lock = groupLock(for: s, groups: groups)
    return AccountMenu.rows(accounts: accounts, usage: usage).map { row in
      let folder = row.account.folder
      let checked = current == ClaudeAccount(folder: folder)
      var entry = SessionAccountEntry(
        folder: folder, title: row.signedOut ? row.choiceTitle : AccountMenu.label(row), checked: checked,
        disabled: checked || row.signedOut, help: row.signedOut ? row.usage?.error : nil)
      // sbd compares the group's folder to the target's as text.
      if !checked, let lock, lock.folder != folder {
        entry.disabled = true
        entry.help = lock.line
      }
      return entry
    }
  }
}

/// A move of one session that waits for the user to confirm it.
struct SessionAccountMove: Equatable {
  var session: String
  var name: String
  var folder: String
  var title: String
  var message: String
  var button: String
  /// The move stops the session's claude first.
  var stop: Bool

  enum Decision: Equatable {
    case refuse(String)
    case confirm(SessionAccountMove)
    case move
  }

  /// What a click on `target` does, given sbd's dry run of the move. A running
  /// claude asks before the move stops it. A Manager conversation, the
  /// operator, and a group chat always ask, because the move changes what they
  /// load.
  static func decide(session s: SessionSummary, target: String, plan: AccountMove) -> Decision {
    let to = Account.name(ofFolder: target)
    if let blocked = plan.blocked.first(where: { $0.session == s.id }) {
      return .refuse(refusal(s.name, to: target, blocked.reason))
    }
    guard s.live || s.kind != .work else { return .move }
    var lines: [String] = []
    if s.live { lines.append("It restarts on the new account with its next message.") }
    if s.kind != .work {
      lines += managerLines(s, to: to, dropped: plan.mcpDropped?[s.id] ?? [])
    }
    lines.append(AccountMove.resumeConsequences)
    return .confirm(
      SessionAccountMove(
        session: s.id, name: s.name, folder: target,
        title: s.live ? "Stop \(s.name) and move it to \(to)?" : "Move \(s.name) to \(to)?",
        message: lines.joined(separator: "\n\n"), button: s.live ? "Stop and Move" : "Move", stop: s.live))
  }

  /// The banner text for a move that sbd refuses.
  static func refusal(_ name: String, to folder: String, _ reason: String) -> String {
    "Can't move \(name) to \(Account.name(ofFolder: folder)): \(reason)"
  }

  /// What a Manager conversation, the operator, or a group chat loses or
  /// changes on another account.
  private static func managerLines(_ s: SessionSummary, to: String, dropped: [String]) -> [String] {
    let from = s.account.map(Account.name(ofFolder:)) ?? "its account"
    var lines: [String] = []
    if !dropped.isEmpty {
      lines.append(
        "\(to) has no MCP server named \(englishList(dropped)), so \(s.name) starts without them.")
    }
    if s.kind.runsInManagerFolder {
      // "may": an account whose projects folder links to another's shares the memory.
      lines.append(
        "Claude Code keeps the Manager folder's memory in each account, so \(s.name) may read different memory on \(to)."
      )
    }
    // A conversation with its own server list runs with --strict-mcp-config, which loads no claude.ai connectors.
    if s.mcp == nil {
      lines.append(
        "Claude.ai connectors, such as Slack, belong to each account's claude.ai login. A connector that only \(from) has won't be there."
      )
    }
    return lines
  }
}
