import Foundation
import SwitchboardCore

/// Lists the shared MCP servers that sbd runs.
func mcp(_ a: Args) {
  let result = call("mcp")
  if a.json {
    printJSON(result)
    return
  }
  let servers = decode(result, as: [MCPServerStatus].self)
  if servers.isEmpty {
    print("No shared MCP servers. Add them under mcpServers in \(client.home.config).")
    return
  }
  let width = servers.map(\.name.count).max() ?? 0
  for s in servers {
    var line = "\(s.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(s.state.rawValue)  \(s.url)"
    if let pid = s.pid { line += "  pid \(pid)" }
    if s.restarts > 0 { line += "  restarts \(s.restarts)" }
    print(line)
    guard s.state == .exited else { continue }
    print(
      "    exited: \(s.lastExit ?? "unknown")\(s.restartAt.map { ". Starts again in \(max(0, $0 - nowMs()) / 1000) s" } ?? "")"
    )
    for line in s.lastOutput ?? [] { print("    \(line)") }
  }
}
