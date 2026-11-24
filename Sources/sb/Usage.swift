import Foundation
import SwitchboardCore

func usageCommand(_ a: Args) {
  if a.positional.first == "headless" { return headlessUsage(a) }
  let result = call("usage", ["refresh": true], timeout: 90)
  if a.json { return printJSON(result) }
  let readings = decode(result, as: [AccountUsage].self)
  for (i, reading) in readings.enumerated() {
    if i > 0 { print("") }
    let folder = (reading.folder as NSString).abbreviatingWithTildeInPath
    print(
      ([reading.name, reading.agent.rawValue, reading.email].compactMap { $0 } + [folder]).joined(separator: " · "))
    if let error = reading.error { print("  ✗ \(error)") }
    for limit in reading.limits { print(usageRow(limit)) }
    if let note = reading.noLimitsNote { print("  \(note)") }
    if let reported = reading.reported() { print("  \(reported)") }
  }
}

func usageRow(_ limit: UsageLimit) -> String {
  let percent = Int(limit.percent.rounded())
  let filled = min(20, max(0, Int((limit.percent / 5).rounded())))
  let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
  var row =
    "  \(limit.label.padding(toLength: 20, withPad: " ", startingAt: 0))\(String(format: "%3d%%", percent))  \(bar)"
  if let resets = limit.resetsAt {
    row += "  resets \(Wait.formatTime(resets)) (\(Usage.until(resets)))"
  }
  return row
}

/// `sb usage headless [--since 7d]`: the calls and tokens of sbd's own `claude -p` calls, per day and kind.
private func headlessUsage(_ a: Args) {
  let since = a.values["--since"] ?? "7d"
  let result = call("headless-usage", sinceArgs(since))
  if a.json { return printJSON(result) }
  let report = decode(result, as: HeadlessUsageReport.self)
  guard !report.rows.isEmpty else { return print("sbd made no claude -p calls in the last \(since)") }
  report.table.forEach { print($0) }
}
