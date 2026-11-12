import AppKit
import SwiftUI
import SwitchboardCore

/// The message that an In review card's Nudge button copies, which asks the
/// reviewers to take a look at the PR.
enum Nudge {
  /// How long a PR waits in review before its card offers Nudge, in milliseconds.
  static let delay: Int64 = 4 * 3_600_000

  static func shows(_ s: SessionSummary, now: Int64) -> Bool {
    guard let board = s.board, board.column == .inReview, s.pr != nil, !MergeBoard.isDone(s) else { return false }
    return now - board.since >= delay
  }

  /// The nudge for the session's PR and the placement's reviewers, or nil while the card offers no Nudge.
  static func text(for s: SessionSummary, now: Int64) -> String? {
    guard shows(s, now: now), let pr = s.pr, let board = s.board else { return nil }
    return text(pr: pr, reviewers: board.reviewers ?? [], waited: now - board.since)
  }

  static func text(pr: PRSummary, reviewers: [String], waited: Int64) -> String {
    let mentions = englishList(reviewers.map { mention($0, pr: pr) })
    let ask = mentions.isEmpty ? "Could you" : "\(mentions) could you"
    let title = pr.title.isEmpty ? "" : " (\(pr.title))"
    return "\(ask) take a look at #\(pr.number)\(title)? It has waited for review for \(duration(waited)). \(pr.url)"
  }

  /// The reviewer as GitHub mentions it. sbd does not record whether a bare
  /// name from a review request is a login or a team's slug. It counts as a
  /// team only when a code owner group names that team in the repo's org,
  /// because GitHub asks only teams of the repo's own org.
  static func mention(_ reviewer: String, pr: PRSummary) -> String {
    if reviewer.hasPrefix("@") { return reviewer }
    if reviewer.contains("/") { return "@\(reviewer)" }
    let org = pr.repo.split(separator: "/").first.map(String.init) ?? ""
    let team = "@\(org)/\(reviewer)".lowercased()
    let owners = pr.codeOwners?.groups.flatMap(\.owners) ?? []
    return owners.contains { $0.lowercased() == team } ? "@\(org)/\(reviewer)" : "@\(reviewer)"
  }

  /// Whole hours below a day, then whole days, both rounded down.
  private static func duration(_ ms: Int64) -> String {
    let hours = max(0, ms) / 3_600_000
    if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
    let days = hours / 24
    return days == 1 ? "1 day" : "\(days) days"
  }
}

/// Copies the card's nudge to the clipboard. It shows a check mark for a moment after.
struct NudgeButton: View {
  let session: SessionSummary
  @State private var copied = false

  var body: some View {
    Button {
      guard let text = Nudge.text(for: session, now: nowMs()) else { return }
      DraftCopy.copy(text)
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(DraftView.copiedSeconds))
        copied = false
      }
    } label: {
      Image(systemName: copied ? "checkmark" : "hand.wave")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityLabel(session.nudgeButtonLabel)
    .accessibilityValue(copied ? "Copied" : "")
    .help(copied ? "Copied" : "Copy a message that asks the reviewers to take a look")
  }
}
