import Foundation
import SwitchboardCore

/// Runs `ack`, which takes a session's item out of the Inbox until its reason
/// changes or a new turn starts, or with `--undo` puts it back. It runs inside
/// Claude Code, so the Manager can use it. sbd refuses the caller's own session.
func acknowledge(_ a: Args) {
  var extra: [String: JSON] = [:]
  if a.switches.contains("--undo") { extra["undo"] = true }
  if let caller = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { extra["caller"] = .string(caller) }
  sessionCommand("ack", a, extra: extra)
}

extension SessionSummary {
  /// The reason line, marked when the user acknowledged it.
  var reasonLine: String { acknowledged == true ? "\(reason) (acknowledged)" : reason }
}
