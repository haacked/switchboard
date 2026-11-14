import Foundation
import SwitchboardCore

extension Service {
  /// The one entry for a request that arrived on a host's socket. `handle` sends every request with origin
  /// `.remote(host)` here before any other op code. A hook goes to `handleHostHook`. Any other op runs only when
  /// `HostScope.authorize` admits it, and then with the request that `authorize` returned.
  func handleHostRequest(
    _ request: Request, host: String, caller: Caller, hookGone: @escaping () -> Bool
  ) throws -> Response {
    switch request.op {
    case "hook":
      return try handleHostHook(request.args, from: host, hookGone: hookGone)
    case "cli":
      throw APIError("sbd does not yet run sb for \(host)")
    default:
      let authorized = try queue.sync {
        try HostScope.authorize(request, host: host, sessions: entries.values.map(\.session))
      }
      afterHostAuthorize?()
      return try route(authorized, origin: .remote(host), caller: caller, hookGone: hookGone)
    }
  }
}
