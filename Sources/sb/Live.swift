import Foundation
import SwitchboardCore

/// `sb live [--set N]`. It prints this Mac's cap, then a line for each remote host that has a session.
func live(_ a: Args) {
  var args: [String: JSON] = [:]
  if let value = a.values["--set"] {
    guard let cap = Int(value), cap >= 1 else { die("--set takes a whole number of at least 1") }
    args["cap"] = .number(Double(cap))
  }
  let result = call("live", args)
  if a.json {
    printJSON(result)
    return
  }
  let status = decode(result, as: LiveStatus.self)
  printCap(nil, cap: status.cap, live: status.live, queued: status.queued)
  for row in status.hosts ?? [] { printCap(row.host, cap: row.cap, live: row.live, queued: row.queued) }
}

/// The line of one site's cap, this Mac's when `host` is nil, and a line for each of its sessions.
private func printCap(
  _ host: String?, cap: Int, live: [LiveStatus.LiveSession], queued: [LiveStatus.QueuedStart]
) {
  let site = host.map { "\($0): " } ?? ""
  print("\(site)\(live.count) of \(cap) claude processes live, \(queued.count) queued".printable)
  for s in live {
    print("  \(s.name)  \(s.pid.map { "pid \($0)" } ?? "starting")  \(s.state.title)".printable)
  }
  for s in queued {
    print("  \(s.name)  queued \(ago(s.since)) ago".printable)
  }
}
