import SwiftUI
import SwitchboardCore

/// The accounts a session can move to, for a context menu's Move to Account
/// submenu and the session header's account menu.
struct MoveToAccountMenuItems: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    let lock = SessionAccountMenu.groupLock(for: session, groups: model.groups)
    if let lock {
      Text(lock.line)
      Divider()
    }
    ForEach(
      SessionAccountMenu.entries(
        for: session, accounts: model.sessionAccounts, usage: model.usage, groups: model.groups)
    ) { entry in
      Button {
        model.requestAccountMove(session.id, to: entry.folder)
      } label: {
        if entry.checked { Label(entry.title, systemImage: "checkmark") } else { Text(entry.title) }
      }
      .disabled(entry.disabled)
      .help(entry.help ?? "")
    }
    if let lock, model.boardShowsGroup(lock.groupID) {
      Divider()
      Button("Show \(lock.groupName) on the Board") { model.showGroupOnBoard(session) }
    }
  }
}

/// The session header's account, such as `Account: personal`. Its menu moves
/// the session when it can move.
struct SessionAccountControl: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    if let folder = session.account {
      let label = GroupAccountMenu.label(folder, accounts: model.accounts, usage: model.usage)
      Group {
        if SessionAccountMenu.shows(session, accountCount: model.sessionAccounts.count) {
          Menu {
            MoveToAccountMenuItems(session: session)
          } label: {
            Text(label)
          }
          .menuStyle(.borderlessButton)
          .controlSize(.small)
          .fixedSize()
          .help("The Claude account this session runs under. Pick another to move the session to it.")
        } else {
          Text(label).foregroundStyle(.secondary).help("The Claude account this session runs under")
        }
      }
      .font(.caption)
      .accessibilityIdentifier("session-account-\(session.id)")
    }
  }
}
