import Foundation

extension MCPToolServer {
  /// Sends one of the schedule requests. A scoped server adds its group and
  /// its caller, and sbd then acts only on the group's sessions and on the
  /// caller. An unscoped server sends neither, because sbd refuses a `group`
  /// that is not a group's id.
  func scheduleCall(_ op: String, _ request: [String: JSON], _ scoped: Scoped?) throws -> JSON {
    var request = request
    if let scoped {
      request["group"] = .string(scoped.group.id)
      if let caller { request["caller"] = .string(caller) }
    }
    return try client.call(op, request)
  }

  /// The arguments of `keys`, with the runner that `ScheduleRequest.runner` reads from `headless` and `script`, and a
  /// `script` sent as the request's `prompt`. sbd refuses `runner` on an edit of a schedule that runs otherwise.
  func scheduleRequest(_ args: JSON, _ keys: [String]) throws -> [String: JSON] {
    var request = pick(args, keys)
    let runner = try ScheduleRequest.runner(
      headless: args["headless"]?.bool == true, script: args["script"] != nil, prompt: args["prompt"] != nil)
    if let runner { request["runner"] = .string(runner.rawValue) }
    if let script = args["script"] { request["prompt"] = script }
    return request
  }
}
