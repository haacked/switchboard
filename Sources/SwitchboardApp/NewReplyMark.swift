import SwiftUI

/// The mark on a session's tiles when someone else replied in one of its Slack threads since the user last looked.
struct NewReplyMark: View {
  nonisolated static let help = "Someone replied in a Slack thread since you last looked"
  nonisolated static let label = "New Slack reply"
  nonisolated static let symbol = "bubble.left.fill"

  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    Image(systemName: Self.symbol)
      .font(.caption2)
      .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
      .help(Self.help)
      .accessibilityLabel(Self.label)
  }
}
