import Foundation
import SwitchboardCore

/// `sb live [--set N | --next <session>]`.
func live(_ a: Args) {
  var args: [String: JSON] = [:]
  if let value = a.values["--set"] {
    guard let cap = Int(value), cap >= 1 else { die("--set takes a whole number of at least 1") }
    args["cap"] = .number(Double(cap))
  }
  let result: JSON
  if let session = a.values["--next"] {
    guard args.isEmpty else { die("--next and --set go in separate commands") }
    result = call("live-next", ["session": .string(session)])
  } else {
    result = call("live", args)
  }
  if a.json {
    printJSON(result)
    return
  }
  let status = decode(result, as: LiveStatus.self)
  print("\(status.live.count) of \(status.cap) claude processes live, \(status.queued.count) queued")
  if let priority = status.priority, !priority.isEmpty {
    print("priority: \(priority.joined(separator: ", "))".printable)
  }
  for s in status.live {
    let process = s.stopping == true ? "stopping" : s.pid.map { "pid \($0)" } ?? "starting"
    print("  \(s.name)  \(process)  \(s.state.title)\(entry(s.priority))".printable)
  }
  for s in status.queued {
    let reason = s.reason.map { ", \($0)" } ?? ""
    print("  \(s.name)  queued \(ago(s.since)) ago\(reason)\(entry(s.priority))".printable)
  }
}

private func entry(_ priority: String?) -> String { priority.map { "  [\($0)]" } ?? "" }
