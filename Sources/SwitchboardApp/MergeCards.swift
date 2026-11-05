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

/// A Ready to merge session's PR, with Merge and Dismiss. Merge runs
/// `gh pr merge --merge` in sbd. Dismiss keeps the session out of Ready to
/// merge until the PR's head commit changes.
struct MergeCard: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    if let pr = session.pr {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: "#\(pr.number)").font(.headline)
          Text(pr.title).fontWeight(.medium).lineLimit(2).textSelection(.enabled)
        }
        Text([session.name, pr.repo, "checks \(pr.checks?.lowercased() ?? "unknown")"].joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
        MergeNote(session: session, lines: 4)
        HStack {
          Button("Merge") { model.merge(session.id) }
          Button("Dismiss") { model.merge(session.id, dismiss: true) }
            .help("Hide the merge card until the PR gets a new commit")
        }
        .disabled(model.merging.contains(session.id))
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(AttentionState.readyToMerge.color.opacity(0.07)))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(AttentionState.readyToMerge.color.opacity(0.35)))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Merge #\(pr.number)")
    }
  }
}

/// gh's error from a failed merge, or nothing.
struct MergeNote: View {
  let session: SessionSummary
  let lines: Int

  var body: some View {
    if let error = session.mergeError {
      Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        .lineLimit(lines).help(error)
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

/// The Merge button on a Ready to merge Board card.
struct MergeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    Button {
      model.merge(session.id)
    } label: {
      Image(systemName: "arrow.triangle.merge")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(model.merging.contains(session.id))
    .accessibilityLabel("Merge \(session.pr.map { "#\($0.number)" } ?? "the PR") of \(session.name)")
    .help("Merge the PR with a merge commit")
  }
}
