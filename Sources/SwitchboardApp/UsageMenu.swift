import SwiftUI
import SwitchboardCore

/// The active account's use of its 5-hour and weekly limits, with a menu of
/// every account's limits and when each resets.
struct UsageMenu: View {
  @EnvironmentObject var model: BoardModel

  private var active: AccountUsage? {
    let folder = model.accounts.first(where: \.active)?.folder
    return model.usage.first { $0.folder == folder }
  }

  var body: some View {
    if !model.usage.isEmpty {
      Menu {
        ForEach(model.usage, id: \.folder) { reading in
          Section([reading.name, reading.email].compactMap { $0 }.joined(separator: " · ")) {
            if let error = reading.error { Text("✗ \(error)") }
            ForEach(reading.limits, id: \.label) { Text(Self.row($0)) }
          }
        }
      } label: {
        Label(Self.label(active), systemImage: "gauge.with.dots.needle.50percent")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(active?.budget() == .left || active == nil ? .primary : AttentionState.needsYou.color)
      }
      .help("Claude plan usage per account, read every few minutes")
    }
  }

  /// The toolbar text: the session's percent and the highest weekly percent.
  static func label(_ reading: AccountUsage?) -> String {
    guard let reading, !reading.limits.isEmpty else { return "Usage" }
    let session = reading.limits.first { $0.kind == "session" }?.percent ?? 0
    let week = reading.limits.filter { $0.kind != "session" }.map(\.percent).max() ?? 0
    return "5h \(Int(session.rounded()))% · wk \(Int(week.rounded()))%"
  }

  static func row(_ limit: UsageLimit, now: Int64 = nowMs()) -> String {
    let resets = limit.resetsAt.map { " · resets \(Usage.until($0, now: now))" } ?? ""
    return "\(limit.label): \(Int(limit.percent.rounded()))%\(resets)"
  }
}
