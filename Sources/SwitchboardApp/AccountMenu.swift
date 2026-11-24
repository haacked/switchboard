import AppKit
import SwiftUI
import SwitchboardCore

/// One account in the account menu, with its last usage reading.
struct AccountRow: Identifiable, Equatable {
  var account: AccountInfo
  var usage: AccountUsage?
  var id: String { account.folder }

  /// The account's session count, such as `4 sessions`, or nil when it has none.
  var sessionCount: String? {
    let n = account.sessions
    return n > 0 ? "\(n) session\(n == 1 ? "" : "s")" : nil
  }
  var signedOut: Bool { usage?.signedOut == true }
  /// The account's name in a menu that moves sessions to it, which names a signed-out account as such.
  var choiceTitle: String { signedOut ? "\(account.name) (not signed in)" : account.name }
  /// A click on the row makes the account the one for new sessions. Only an account whose agent runs sessions
  /// can become that account.
  var canChoose: Bool { account.agent.runsSessions && !account.active && !signedOut }
  var disabledReason: String? {
    guard account.agent.runsSessions else {
      return "A \(account.agent.displayName) account. \(Agent.onlyClaudeRunsSessions)."
    }
    return signedOut ? "New sessions can't use it until it signs in." : nil
  }
}

/// The toolbar item for the account that new sessions use. Its tooltip names
/// the account and its use of its 5-hour and weekly limits. Its popover lists
/// every account's limits and when each resets, and a click on an account
/// makes it the one for new sessions.
struct AccountMenu: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if Self.shows(accounts: model.accounts, usage: model.usage) {
      let rows = Self.rows(accounts: model.accounts, usage: model.usage)
      let active = rows.first { $0.account.active }
      let warns = Self.warns(active)
      Button {
        model.showingAccounts.toggle()
      } label: {
        // The name and usage text would push New Session into the overflow at 1024 pt. The tooltip shows them.
        Label("Account", systemImage: warns ? Self.warningSymbol : Self.symbol)
          .foregroundStyle(warns ? Self.warningColor : .primary)
      }
      .help(Self.help(active))
      .accessibilityValue(active == nil ? "" : Self.summary(active))
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

  static let symbol = "gauge.with.dots.needle.50percent"
  static let warningSymbol = "exclamationmark.triangle.fill"
  /// Yellow, not the Needs you orange, because orange means that a session needs the user.
  static let warningColor = Color.yellow

  /// Whether the toolbar item shows the warning symbol and color: a limit is
  /// spent, or the read failed with no earlier limits. An account that sbd has
  /// not read yet does not need the user.
  static func warns(_ row: AccountRow?) -> Bool { status(row) != nil }

  /// Why the account needs the user, or nil when it does not.
  static func status(_ row: AccountRow?) -> String? {
    guard let reading = row?.usage else { return nil }
    if reading.failedWithoutLimits { return "usage read failed" }
    if reading.budget().isSpent { return "limit spent" }
    return nil
  }

  /// The start of the tooltip and VoiceOver text: the account's name, its session
  /// percent when the reading has a session limit, and its highest weekly percent.
  static func label(_ row: AccountRow?) -> String {
    guard let row else { return "Account" }
    guard let usage = row.usage, !usage.limits.isEmpty else { return row.account.name }
    var parts = [row.account.name]
    if let session = usage.sessionPercent { parts.append("5h \(Int(session.rounded()))%") }
    parts.append("wk \(Int(usage.weeklyPercent.rounded()))%")
    return parts.joined(separator: " · ")
  }

  /// The label, then why the account needs the user when it does. VoiceOver
  /// reads it as the toolbar item's value.
  static func summary(_ row: AccountRow?) -> String {
    [label(row), status(row)].compactMap { $0 }.joined(separator: ", ")
  }

  /// The toolbar item's tooltip: the summary, then what the item does.
  static func help(_ row: AccountRow?) -> String {
    "\(summary(row)). The Claude account for new sessions, and every account's plan usage, read every few minutes."
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
      Text("New sessions use the selected account, unless their group names one.")
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
        Button("Move \(n) Stopped Session\(n == 1 ? "" : "s") to \(Account.name(ofFolder: plan.account))…") {
          model.offerMove(plan)
        }
      }
      Text(
        "A session that another session starts uses its parent's account. Choosing an account asks whether to move the sessions whose claude is stopped. A session whose group names an account stays on it."
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
          Text(row.account.name).fontWeight(.semibold).foregroundStyle(row.signedOut ? .secondary : .primary)
          Text(row.account.agent.displayName).foregroundStyle(.secondary)
          if let email = row.usage?.email { Text(email).foregroundStyle(.secondary) }
          if let sessions = row.sessionCount {
            Spacer(minLength: 6)
            Text(sessions).monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .font(.callout)
        details
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  /// Puts the warning triangle in the warning color before the text. The text keeps the primary color because
  /// yellow text is hard to read on a light popover.
  private func warning(_ text: String) -> Text {
    Text("\(Text(Image(systemName: AccountMenu.warningSymbol)).foregroundStyle(AccountMenu.warningColor)) \(text)")
  }

  @ViewBuilder private var details: some View {
    let now = nowMs()
    VStack(alignment: .leading, spacing: 2) {
      if let usage = row.usage {
        ForEach(usage.limits, id: \.label) { limit in
          let text = AccountMenu.limitRow(limit, now: now)
          if limit.isSpent(now: now) { warning(text) } else { Text(text).foregroundStyle(.secondary) }
        }
        if let note = usage.noLimitsNote { Text(note).foregroundStyle(.secondary) }
        if let reported = usage.reported(now: now) { Text(reported).foregroundStyle(.secondary) }
        if let error = usage.error {
          Group {
            if usage.failedWithoutLimits { warning(error) } else { Text("✗ \(error)").foregroundStyle(.secondary) }
          }
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
