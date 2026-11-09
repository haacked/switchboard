import AppKit
import SwiftUI
import SwitchboardCore

/// One account in the account menu, with its last usage reading.
struct AccountRow: Identifiable, Equatable {
  var account: AccountInfo
  var usage: AccountUsage?
  var id: String { account.folder }

  var title: String { "\(account.name) (\(account.sessions))" }
  var signedOut: Bool { usage?.signedOut == true }
  /// A click on the row makes the account the one for new sessions.
  var canChoose: Bool { !account.active && !signedOut }
  var disabledReason: String? { signedOut ? "New sessions can't use it until it signs in." : nil }
}

/// The toolbar control that names the account for new sessions, with its use
/// of its 5-hour and weekly limits. Its popover lists every account's limits
/// and when each resets, and a click on an account makes it the one for new
/// sessions.
struct AccountMenu: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if Self.shows(accounts: model.accounts, usage: model.usage) {
      let rows = Self.rows(accounts: model.accounts, usage: model.usage)
      let active = rows.first { $0.account.active }
      Button {
        model.showingAccounts.toggle()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "gauge.with.dots.needle.50percent")
          Text(Self.label(active))
          Image(systemName: "chevron.down").imageScale(.small)
        }
        .foregroundStyle(Self.needsYou(active) ? AttentionState.needsYou.color : .primary)
      }
      .help("The Claude account for new sessions, and every account's plan usage, read every few minutes")
      .popover(isPresented: $model.showingAccounts, arrowEdge: .bottom) {
        AccountList(rows: rows)
      }
    }
  }

  static func rows(accounts: [AccountInfo], usage: [AccountUsage]) -> [AccountRow] {
    accounts.map { account in AccountRow(account: account, usage: usage.first { $0.folder == account.folder }) }
  }

  /// The menu shows once sbd has listed the accounts, when there is a reading
  /// to show or another account to choose.
  static func shows(accounts: [AccountInfo], usage: [AccountUsage]) -> Bool {
    !accounts.isEmpty && (!usage.isEmpty || accounts.count > 1)
  }

  /// Whether the label takes the needs-you color: a limit is spent, or the
  /// read failed with no earlier limits. An account that sbd has not read yet
  /// does not need the user.
  static func needsYou(_ row: AccountRow?) -> Bool {
    guard let reading = row?.usage else { return false }
    return reading.budget().isSpent || reading.failedWithoutLimits
  }

  /// The toolbar text: the account's name, its session percent, and its
  /// highest weekly percent.
  static func label(_ row: AccountRow?) -> String {
    guard let row else { return "Account" }
    guard let limits = row.usage?.limits, !limits.isEmpty else { return row.account.name }
    let session = limits.first { $0.kind == "session" }?.percent ?? 0
    let week = limits.filter { $0.kind != "session" }.map(\.percent).max() ?? 0
    return "\(row.account.name) · 5h \(Int(session.rounded()))% · wk \(Int(week.rounded()))%"
  }

  static func limitRow(_ limit: UsageLimit, now: Int64 = nowMs()) -> String {
    let resets = limit.resetsAt.map { " · resets \(Usage.until($0, now: now))" } ?? ""
    return "\(limit.label): \(Int(limit.percent.rounded()))%\(resets)"
  }
}

/// The popover of the account menu.
private struct AccountList: View {
  @EnvironmentObject var model: BoardModel
  var rows: [AccountRow]
  @State private var maxListHeight: CGFloat = 400

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("New sessions use the selected account.")
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
      Divider()
      ScrollView { blocks }
        .frame(maxHeight: maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      footer
    }
    .frame(width: 400)
    .onAppear {
      maxListHeight = Self.maxListHeight()
      model.readMovable()
      model.rereadUsage()
    }
  }

  /// The list scrolls so that it stops above the bottom of the main window.
  /// The header, the footer, and the toolbar take about 200 points.
  private static func maxListHeight() -> CGFloat {
    max(160, (NSApp.switchboardWindow?.contentLayoutRect.height ?? 600) - 200)
  }

  private var blocks: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows) { row in
        if row.id != rows.first?.id { Divider().padding(.horizontal, 12) }
        AccountBlock(row: row) { model.useAccount(row.account.folder) }
      }
    }
    .padding(.vertical, 4)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let plan = model.movable, !plan.moved.isEmpty {
        let n = plan.moved.count
        Button("Move \(n) Stopped Session\(n == 1 ? "" : "s") to \(ClaudeAccount.name(plan.account))…") {
          model.offerMove(plan)
        }
      }
      Text(
        "A session that another session starts uses its parent's account. Choosing an account asks whether to move the sessions whose claude is stopped."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
  }
}

/// One account's block: a click chooses it, unless it is the active account.
/// The block of an account with no login is text that can be selected, so its
/// login command can be copied.
private struct AccountBlock: View {
  var row: AccountRow
  var choose: () -> Void
  @State private var hovering = false

  var body: some View {
    if row.signedOut {
      content.textSelection(.enabled).help(help)
    } else {
      Button {
        if row.canChoose { choose() }
      } label: {
        content
          .contentShape(Rectangle())
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.accentColor.opacity(hovering && row.canChoose ? 0.15 : 0))
              .padding(.horizontal, 4))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityAddTraits(row.account.active ? .isSelected : [])
      .help(help)
    }
  }

  private var content: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "checkmark")
        .font(.callout.weight(.semibold))
        .opacity(row.account.active ? 1 : 0)
        .accessibilityHidden(!row.account.active)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(row.title).fontWeight(.semibold).foregroundStyle(row.signedOut ? .secondary : .primary)
          if let email = row.usage?.email { Text(email).foregroundStyle(.secondary) }
        }
        .font(.callout)
        details
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  @ViewBuilder private var details: some View {
    let now = nowMs()
    VStack(alignment: .leading, spacing: 2) {
      if let usage = row.usage {
        ForEach(usage.limits, id: \.label) { limit in
          Text(AccountMenu.limitRow(limit, now: now))
            .foregroundStyle(limit.isSpent(now: now) ? AttentionState.needsYou.color : .secondary)
        }
        if let error = usage.error {
          Text("✗ \(error)")
            .foregroundStyle(usage.failedWithoutLimits ? AttentionState.needsYou.color : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("No usage reading yet").foregroundStyle(.secondary)
      }
      if let reason = row.disabledReason { Text(reason).foregroundStyle(.secondary) }
    }
    .font(.caption)
  }

  private var help: String {
    if row.account.active { return "New sessions use \(row.account.name)" }
    if let reason = row.disabledReason { return reason }
    return "Use \(row.account.name) for new sessions"
  }
}
