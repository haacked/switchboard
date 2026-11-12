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
  let window = report.since.map { "since \(Wait.formatTime($0))" } ?? "in the last 30 days"
  print("the activity log is \(report.enabled ? "on" : "off"), with \(report.events) events \(window)")
  section("resumes, from launch to SessionStart", report.resumes) { r in
    timingRow("\(r.trigger) (\(r.userCaused ? "you" : "sbd"))", r.count, r.medianMs, r.p90Ms, r.maxMs)
  }
  section("time to a usable terminal", report.terminalReady) {
    timingRow($0.name, $0.count, $0.medianMs, $0.p90Ms, $0.maxMs)
  }
  section("time in each place while the app was in front", report.places) { p in
    "  \(pad(p.place))\(String(format: "%4d", p.visits)) visits  \(minutes(p.ms))"
  }
  section("how you moved between places", report.navigation) { countRow($0) }
  section("commands, by the input that ran them", report.commands) { c in
    let vias = c.vias.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) \($0.value)" }
    return "  \(pad(c.name))\(String(format: "%4d", c.count))  \(vias.joined(separator: ", "))"
  }
  if report.sends > 0 {
    print("")
    print("messages you wrote: \(report.sends), with \(report.repeatedSends.count) texts sent more than once")
    for r in report.repeatedSends {
      let to = r.sessions > 0 ? "to \(r.sessions) sessions" : "as group messages"
      print("  \(r.count) times \(to), closest \(seconds(r.minGapMs)) apart")
    }
  }
  section("errors", report.errors) { countRow($0) }
  section("window sizes", report.windowSizes) { countRow($0) }
}

private func section<T>(_ title: String, _ rows: [T], _ line: (T) -> String) {
  guard !rows.isEmpty else { return }
  print("")
  print("\(title):")
  for row in rows { print(line(row)) }
}

private func pad(_ s: String) -> String { s.padding(toLength: 22, withPad: " ", startingAt: 0) }

private func timingRow(_ name: String, _ count: Int, _ median: Int64, _ p90: Int64, _ max: Int64) -> String {
  "  \(pad(name))\(String(format: "%4d", count))  median \(seconds(median))  p90 \(seconds(p90))  max \(seconds(max))"
}

private func countRow(_ c: ActivityCount) -> String { "  \(pad(c.name))\(String(format: "%4d", c.count))" }

private func seconds(_ ms: Int64) -> String { String(format: "%.1f s", Double(ms) / 1000) }

private func minutes(_ ms: Int64) -> String { String(format: "%.0f min", Double(ms) / 60_000) }
