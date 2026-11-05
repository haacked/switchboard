import SwiftUI
import SwitchboardCore

extension SessionSummary {
  /// Whether sbd can merge or enqueue the session's PR: it is Ready to merge
  /// and sbd knows how its repository merges.
  var canMerge: Bool {
    guard state == .readyToMerge, let method = pr?.mergeMethod else { return false }
    return method != .unknown
  }

  var enqueues: Bool { pr?.mergeMethod?.enqueues == true }

  var mergeVerb: String { (pr?.mergeMethod ?? .merge).verb }

  /// The Ready to merge sessions that Merge All merges or enqueues from this
  /// session's card: this one first, then the others, oldest first.
  func readyToMergeSessions(all: [SessionSummary]) -> [SessionSummary] {
    guard canMerge else { return [] }
    let others = all.filter { $0.id != id && $0.canMerge }.sorted { $0.since < $1.since }
    return [self] + others
  }
}

/// The batch button's title, by how the sessions' repositories merge.
func mergeBatchTitle(_ sessions: [SessionSummary]) -> String {
  if sessions.allSatisfy(\.enqueues) { return "Enqueue All" }
  if sessions.contains(where: \.enqueues) { return "Merge and Enqueue All" }
  return "Merge All"
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

/// Merges or enqueues several PRs after one confirmation that lists each of
/// them with what happens to it.
struct MergeBatch: View {
  @EnvironmentObject var model: BoardModel
  let sessions: [SessionSummary]
  @State private var confirming = false

  var body: some View {
    if sessions.count > 1 {
      let title = mergeBatchTitle(sessions)
      HStack {
        Text("\(sessions.count) PRs are ready to merge").font(.headline)
        Spacer()
        Button("\(title)…") { confirming = true }
      }
      .confirmationDialog("\(title) \(sessions.count) PRs?", isPresented: $confirming) {
        Button(title) { for s in sessions { model.merge(s.id) } }
      } message: {
        Text(
          sessions.compactMap { s in
            s.pr.map { "\(s.mergeVerb) #\($0.number) \($0.title) (\($0.repo))" }
          }
          .joined(separator: "\n"))
      }
    }
  }
}

/// The Merge or Enqueue button on a Ready to merge Board card. It asks first,
/// like the card's cleanup and delete buttons, because a merge can't be
/// undone.
struct MergeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  @State private var confirming = false

  private var ref: String { session.pr.map { "#\($0.number)" } ?? "the PR" }

  var body: some View {
    Button {
      confirming = true
    } label: {
      Image(systemName: session.enqueues ? "tray.and.arrow.down" : "arrow.triangle.merge")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .disabled(model.merging.contains(session.id))
    .accessibilityLabel("\(session.mergeVerb) \(ref) of \(session.name)")
    .help(session.enqueues ? "Add the PR to the merge queue…" : "Merge the PR with a merge commit…")
    .confirmationDialog("\(session.mergeVerb) \(ref)?", isPresented: $confirming) {
      Button(session.mergeVerb) { model.merge(session.id) }
    } message: {
      Text(session.pr.map { "\($0.title) (\($0.repo))" } ?? session.name)
    }
  }
}
