import Foundation

extension Attention {
  /// The reason with its shell command replaced by words. `toolSummary` writes a Bash call as its command in
  /// backticks. A Working reason is that command and an optional " (N min)".
  /// A permission's reason is "approve " and the command. The command can contain backticks. The
  /// rewrite therefore matches the whole reason rather than the first closing backtick. Other reasons stay as
  /// written, such as a wait note that starts with a code span.
  public static func plainReason(_ reason: String, working: Bool) -> String {
    if working, let match = reason.wholeMatch(of: #/`.+`((?: \((?:<1|\d+) min\))?)/#) {
      return "Running a shell command" + match.1
    }
    if reason.wholeMatch(of: #/approve `.+`/#) != nil { return "approve a shell command" }
    return reason
  }
}
