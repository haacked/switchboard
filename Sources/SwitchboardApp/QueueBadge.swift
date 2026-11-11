import SwiftUI
import SwitchboardCore

/// Where a merge queue holds the PR, on the session's tiles. The PR number's
/// color shows only the review state. Without the badge, an approved PR in
/// the queue looks the same as one that nobody queued.
struct QueueBadge: View {
  let pr: PRSummary
  @Environment(\.backgroundProminence) private var prominence

  /// nil is GitHub's merge queue, which reports no state.
  static func color(for queue: TrunkQueueState?) -> Color {
    switch queue {
    case .passed: PRStatus.approved.color
    case .failing, .removed: PRStatus.changesRequested.color
    case .submitted, .pending, .testing, .queued, .merged, .unknown, nil: AttentionState.waiting.color
    }
  }

  var body: some View {
    if let word = pr.queueWord, let phrase = pr.queuePhrase {
      Label(word, systemImage: "arrow.triangle.merge")
        .labelStyle(.titleAndIcon)
        .font(.caption2.bold())
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(
          prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.color(for: pr.queue))
        )
        .help(phrase)
        .accessibilityLabel("Merge queue: \(word)")
    }
  }
}
