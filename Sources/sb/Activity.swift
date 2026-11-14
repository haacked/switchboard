import Foundation
import SwitchboardCore

/// `sb activity [on|off|status|report|clear] [--since 3d]`.
func activity(_ a: Args) {
  switch a.positional.first ?? "status" {
  case "on": activityStatus(a, call("activity", ["enabled": true]))
  case "off": activityStatus(a, call("activity", ["enabled": false]))
  case "status": activityStatus(a, call("activity"))
  case "clear": activityStatus(a, call("activity-clear"))
  case "report": activityReport(a)
  default: die("activity takes on, off, status, report, or clear")
  }
}

private func activityStatus(_ a: Args, _ result: JSON) {
  if a.json { return printJSON(result) }
  let status = decode(result, as: ActivityStatus.self)
  var line = "the activity log is \(status.enabled ? "on" : "off"), with \(status.events) events"
  if let oldest = status.oldest { line += " since \(Wait.formatTime(oldest))" }
  print(line)
}

private func activityReport(_ a: Args) {
  var args: [String: JSON] = [:]
  if let since = a.values["--since"] {
    guard let ms = Wait.durationMs(since) else { die("--since takes a duration such as 1w, 3d, or 12h") }
    args["durationMs"] = .number(Double(ms))
  }
  let result = call("activity-report", args)
  if a.json { return printJSON(result) }
  let report = decode(result, as: ActivityReport.self)
  let window =
    report.since.map { "since \(Wait.formatTime($0))" }
    ?? "in the last \(ActivityLog.retentionMs / Attention.dayMs) days"
  print("the activity log is \(report.enabled ? "on" : "off"), with \(report.events) events \(window)")
  guard !report.resumes.isEmpty else { return print("it holds no resumes") }
  print("")
  print("resumes, from launch to SessionStart:")
  for r in report.resumes {
    let who = r.userCaused ? "you" : "sbd"
    print(
      "  \(r.trigger.padding(toLength: 14, withPad: " ", startingAt: 0))\(who)  \(String(format: "%4d", r.count))  median \(seconds(r.medianMs))  p90 \(seconds(r.p90Ms))  max \(seconds(r.maxMs))"
    )
  }
}

private func seconds(_ ms: Int64) -> String { String(format: "%.1f s", Double(ms) / 1000) }
