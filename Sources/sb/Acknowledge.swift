import Foundation
import SwitchboardCore

/// Runs `ack`, which takes a session's item out of the Inbox until its reason
/// changes or a new turn starts, or with `--undo` puts it back. It runs inside
/// Claude Code, so the Manager can use it. sbd refuses the caller's own session.
func acknowledge(_ a: Args) {
  var extra = callerArg
  if a.switches.contains("--undo") { extra["undo"] = true }
  sessionCommand("ack", a, extra: extra)
}

/// `caller` set to the session that runs `sb`, when one does. sbd refuses
/// some requests from a session, such as acknowledging itself.
var callerArg: [String: JSON] {
  ProcessInfo.processInfo.environment["SB_SESSION_ID"].map { ["caller": .string($0)] } ?? [:]
}

extension SessionSummary {
  /// The reason line, marked when the user acknowledged it.
  var reasonLine: String { acknowledged == true ? "\(reason) (acknowledged)" : reason }
}
