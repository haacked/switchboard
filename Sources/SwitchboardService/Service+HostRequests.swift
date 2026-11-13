import Foundation
import SwitchboardCore

extension Service {
  /// The one entry for a request that arrived on a host's socket. `handle` sends every request with origin
  /// `.remote(host)` here before any other op code.
  func handleHostRequest(
    _ request: Request, host: String, caller: Caller, hookGone: @escaping () -> Bool
  ) throws -> Response {
    // A request from a host's socket can only be a hook, and `handleHostHook` takes it only for a session
    // that sbd holds on that host.
    guard request.op == "hook" else { throw APIError("a request from \(host) can only be a hook") }
    return try handleHostHook(request.args, from: host, hookGone: hookGone)
  }
}
