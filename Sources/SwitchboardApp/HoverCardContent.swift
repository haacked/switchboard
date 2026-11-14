import Foundation
import SwitchboardCore

/// What a session's hover card says. It leaves out each fact the session
/// lacks, and the facts that a tile already shows plainly, such as the state.
struct HoverCardContent: Equatable {
  struct PRChip: Equatable {
    var text: String
    var status: PRStatus
  }

  var title: String
  /// Muted lines under the title: the repo and branch, the issues, then the group, account, and last activity.
  var details: [String]
  var pr: PRChip?
  /// What the session is doing or waits on, in one line of plain text.
  var summary: String?

  /// The account appears only when the session records an account other than
  /// `activeAccount`. A session without a recorded account runs under sbd's
  /// own account, which the app can't name.
  init(
    _ s: SessionSummary, activeAccount: String, names: SessionNames = SessionNames(live: [:], removed: [:]),
    now: Int64 = nowMs()
  ) {
    title = s.name
    let repo = s.pr?.repo ?? s.repoFolder.map { ($0 as NSString).lastPathComponent }
    let branch = s.branch == s.name ? nil : s.branch
    let issues = s.issues ?? []
    let account = s.account.map(ClaudeAccount.normalize)
    let meta = [
      s.groupName,
      account.flatMap { $0 == ClaudeAccount.normalize(activeAccount) ? nil : "\(ClaudeAccount.name($0)) account" },
      s.waitsToStart || s.lastActivity <= 0 ? nil : "active \(ago(s.lastActivity, now: now)) ago",
    ]
    details = [
      Self.joined([repo, branch]),
      issues.count > 1 ? "Issues " + issues.map { $0.label(from: s.pr?.repo) }.joined(separator: ", ") : nil,
      Self.joined(meta),
    ].compactMap { $0 }
    pr = s.pr.map { PRChip(text: $0.line, status: $0.status) }
    summary = Self.summary(s, names: names)
  }

  /// Every fact in one string, for VoiceOver, which reads no hover card.
  var accessibilityText: String {
    ([title] + details + [pr?.text, summary].compactMap { $0 }).joined(separator: ". ")
  }

  private static func joined(_ parts: [String?]) -> String? {
    let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    return text.isEmpty ? nil : text
  }

  /// The triage summary, else the reason, else the start of the last reply.
  /// The reply can run to many kilobytes, so only its start goes through `oneLine`.
  /// Names replace ids before `capitalized`, which would stop an id at the start from matching.
  private static func summary(_ s: SessionSummary, names: SessionNames) -> String? {
    let candidates = [
      s.triage?.summary,
      Attention.plainReason(s.reason, working: s.state == .working),
      s.lastReply.map { String($0.drop(while: \.isWhitespace).prefix(400)) },
    ]
    guard
      let text = candidates.lazy.compactMap({ $0.map { oneLine(names.plainText($0), max: 160) } }).first(where: {
        !$0.isEmpty
      })
    else { return nil }
    return Triage.capitalized(text)
  }
}
