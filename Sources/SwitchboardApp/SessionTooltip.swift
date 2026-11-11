import Foundation
import SwitchboardCore

extension SessionSummary {
  /// The text a session tile shows on hover, one fact per line. It leaves out
  /// each fact the session lacks. The account line appears only when the
  /// session records an account other than `activeAccount`. A session without
  /// a recorded account runs under sbd's own account, which the app can't name.
  func tooltip(activeAccount: String, now: Int64 = nowMs()) -> String {
    let repoName = pr?.repo ?? repoFolder.map { ($0 as NSString).lastPathComponent }
    let place = [repoName, branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    let shownIssues = issues ?? []
    let account = self.account.map(ClaudeAccount.normalize)
    let lines: [String?] = [
      name,
      place,
      pr?.line,
      pr?.title,
      shownIssues.count > 1
        ? "Issues " + shownIssues.map { $0.label(from: pr?.repo) }.joined(separator: ", ") : nil,
      reason.isEmpty ? state.title : "\(state.title): \(reason)",
      excerpt,
      groupName.flatMap { $0.isEmpty ? nil : "Group: \($0)" },
      account.flatMap { $0 == ClaudeAccount.normalize(activeAccount) ? nil : "Account: \(ClaudeAccount.name($0))" },
      waitsToStart || lastActivity <= 0 ? nil : "Last activity \(ago(lastActivity, now: now)) ago",
    ]
    return lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// The triage summary, else the start of the last reply, in one line. The
  /// reply can run to many kilobytes, so only its start goes through `oneLine`.
  private var excerpt: String? {
    if let summary = triage.map({ oneLine($0.summary, max: 160) }), !summary.isEmpty {
      return "Summary: " + summary
    }
    if let reply = lastReply.map({ oneLine(String($0.drop(while: \.isWhitespace).prefix(400)), max: 160) }),
      !reply.isEmpty
    {
      return "Last reply: " + reply
    }
    return nil
  }
}
