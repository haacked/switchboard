import Foundation
import SwitchboardCore

/// Runs the stdio MCP server: one JSON-RPC message per line on stdin, and one reply per line on stdout.
func mcpServer(_ a: Args) {
  let caller = ProcessInfo.processInfo.environment["SB_SESSION_ID"]
  let server: MCPToolServer
  do {
    server =
      try a.values["--group"].map { try MCPToolServer.scoped(to: $0, client: client, caller: caller) }
      ?? MCPToolServer(client: client, caller: caller)
  } catch {
    die("\(error)")
  }
  while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
    print(reply)
    fflush(stdout)
  }
}
