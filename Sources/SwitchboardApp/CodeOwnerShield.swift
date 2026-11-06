import SwiftUI
import SwitchboardCore

struct CodeOwnerShield: View {
  let status: CodeOwnerStatus
  @Environment(\.backgroundProminence) private var prominence

  static func symbol(for status: CodeOwnerStatus) -> String {
    status.satisfied ? "checkmark.shield.fill" : "shield"
  }

  static func color(for status: CodeOwnerStatus) -> Color {
    (status.satisfied ? PRStatus.approved : PRStatus.reviewRequired).color
  }

  static func label(for status: CodeOwnerStatus) -> String { status.text(separator: "\n") }

  var body: some View {
    let label = Self.label(for: status)
    Image(systemName: Self.symbol(for: status))
      .font(.caption)
      .foregroundStyle(
        prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.color(for: status))
      )
      .help(label)
      .accessibilityLabel(label)
  }
}
