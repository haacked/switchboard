import SwiftUI
import SwitchboardCore

extension SessionSummary {
  /// The sessions whose merge card the Inbox shows with this one's: this one
  /// first, then every other Ready to merge session, oldest first.
  func mergeCards(all: [SessionSummary]) -> [SessionSummary] {
    guard state == .readyToMerge else { return [] }
    let others = all.filter { $0.id != id && $0.state == .readyToMerge }.sorted { $0.since < $1.since }
    return [self] + others
  }
}

/// gh's error from a failed merge, or nothing.
struct MergeNote: View {
  let session: SessionSummary

  var body: some View {
    if let error = session.mergeError {
      Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        .lineLimit(2).help(error)
    }
  }
}

/// Merges several PRs after one confirmation that lists each of them.
struct MergeBatch: View {
  @EnvironmentObject var model: BoardModel
  let sessions: [SessionSummary]
  @State private var confirming = false

  var body: some View {
    if sessions.count > 1 {
      HStack {
        Text("\(sessions.count) PRs are ready to merge").font(.headline)
        Spacer()
        Button("Merge All…") { confirming = true }
      }
      .confirmationDialog("Merge \(sessions.count) PRs?", isPresented: $confirming) {
        Button("Merge All") { for s in sessions { model.merge(s.id) } }
      } message: {
        Text(sessions.compactMap { s in s.pr.map { "#\($0.number) \($0.title) (\($0.repo))" } }.joined(separator: "\n"))
      }
    }
  }
}

/// The Merge button on a Ready to merge Board card. It asks first, like the
/// card's cleanup and delete buttons, because a merge can't be undone.
struct MergeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var confirming = false

  private var ref: String { session.pr.map { "#\($0.number)" } ?? "the PR" }

  var body: some View {
    Button {
      confirming = true
    } label: {
      Image(systemName: "arrow.triangle.merge")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(model.merging.contains(session.id))
    .accessibilityLabel("Merge \(ref) of \(session.name)")
    .help("Merge the PR with a merge commit…")
    .confirmationDialog("Merge \(ref)?", isPresented: $confirming) {
      Button("Merge") { model.merge(session.id) }
    } message: {
      Text(session.pr.map { "\($0.title) (\($0.repo))" } ?? session.name)
    }
  }
}
