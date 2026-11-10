import SwiftUI
import SwitchboardCore

/// The account that a group's sessions run under, in the group's lane. Its
/// menu sets the account or clears it. Setting one asks first when sessions
/// would move to it.
struct GroupAccountMenu: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary
  @State private var confirming: AccountChoice?

  struct AccountChoice: Identifiable {
    var folder: String
    var moves: [SessionSummary]
    var id: String { folder }
  }

  var body: some View {
    if model.accounts.count > 1 || group.account != nil {
      let rows = AccountMenu.rows(accounts: model.accounts, usage: model.usage)
      Menu {
        ForEach(rows) { row in
          Button {
            choose(row.account.folder)
          } label: {
            if row.account.folder == group.account {
              Label(row.account.name, systemImage: "checkmark")
            } else {
              Text(row.signedOut ? "\(row.account.name) (not signed in)" : row.account.name)
            }
          }
          .disabled(row.signedOut || row.account.folder == group.account)
        }
        if group.account != nil {
          Divider()
          Button("Use the Account for New Sessions") { model.setGroupAccount(group.id, nil) }
        }
      } label: {
        Text(Self.label(group.account, accounts: model.accounts))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .font(.caption)
      .help("The Claude account that this group's sessions run under")
      .accessibilityIdentifier("group-account-\(group.id)")
      .confirmationDialog(
        confirming.map { "Run \(group.name)'s sessions under \(ClaudeAccount.name($0.folder))?" } ?? "",
        isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
        presenting: confirming
      ) { choice in
        Button("Use \(ClaudeAccount.name(choice.folder))") { model.setGroupAccount(group.id, choice.folder) }
        Button("Cancel", role: .cancel) {}
      } message: { choice in
        Text(Self.moveMessage(choice.moves))
      }
    }
  }

  private func choose(_ folder: String) {
    let moves = model.groupAccountMoves(group: group.id, folder: folder)
    if moves.isEmpty {
      model.setGroupAccount(group.id, folder)
    } else {
      confirming = AccountChoice(folder: folder, moves: moves)
    }
  }

  /// Such as `Account: personal`, or `Account: for new sessions` when the
  /// group names none. A folder that sbd no longer lists reads as missing.
  static func label(_ folder: String?, accounts: [AccountInfo]) -> String {
    guard let folder else { return "Account: for new sessions" }
    let name = ClaudeAccount.name(folder)
    return accounts.contains { $0.folder == folder } ? "Account: \(name)" : "Account: \(name) (missing)"
  }

  static func moveMessage(_ moves: [SessionSummary]) -> String {
    let names = moves.map(\.name).joined(separator: ", ")
    let count = moves.count == 1 ? "1 session moves" : "\(moves.count) sessions move"
    return "\(count) to it at the next launch: \(names). Sessions that join the group later move too.\n\n"
      + AccountMove.consequences
  }
}
