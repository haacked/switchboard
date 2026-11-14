import Foundation
import SwitchboardCore

extension Service {
  /// The one entry for a request that arrived on a host's socket. `handle` sends every request with origin
  /// `.remote(host)` here before any other op code. A hook goes to `handleHostHook`, and `cli` to `hostCLI`. Any
  /// other op runs only when `HostScope.authorize` admits it, and then with the request that `authorize`
  /// returned. `reply` gets the answer, and it throws only before it replies.
  func handleHostRequest(
    _ request: Request, host: String, caller: Caller, hookGone: @escaping () -> Bool, reply: (Response) -> Void
  ) throws {
    switch request.op {
    case "hook":
      reply(try handleHostHook(request.args, from: host, hookGone: hookGone))
    case "cli":
      try hostCLI(request.args, host: host, cancelled: hookGone, reply: reply)
    default:
      let authorized = try queue.sync {
        try HostScope.authorize(request, host: host, sessions: entries.values.map(\.session))
      }
      afterHostAuthorize?()
      reply(try route(authorized, origin: .remote(host), caller: caller, hookGone: hookGone))
    }
  }
}

extension Service {
  /// Runs this Mac's `sb` for a host's `cli` request and answers its exit status and both streams in base64.
  /// `sb` runs in the host's sandbox with the environment that `HostCLI.environment` builds, so each request
  /// that it makes arrives on the host's socket and passes through `HostScope`. It runs off the state queue,
  /// because those requests need that queue. `cancelled` reports that the box's client closed its connection.
  /// It calls `reply` while the run holds its slot, so a client that doesn't read its answers holds at most
  /// `HostCLIRunner.slotsPerHost` of them.
  func hostCLI(
    _ args: JSON, host: String, cancelled: @escaping () -> Bool, reply: (Response) -> Void
  ) throws {
    let request = try HostCLIRequest.parse(args)
    let runner = hostCLIRunner
    let socket = try HostServer.socketPath(for: host, in: home)
    let profile = try HostCLI.profile(sb: runner.program, socket: socket)
    // `sb` reaches the socket through this folder. The sandbox denies reading a link on the way to it.
    let folder = (socket as NSString).deletingLastPathComponent
    let hostHome = HostCLI.resolvedPath(folder) ?? folder
    try runner.run(
      host: host, profile: profile, argv: request.argv,
      environment: HostCLI.environment(
        hostHome: hostHome, host: host, cwd: request.cwd, session: request.session, claudecode: request.claudecode),
      cwd: hostHome, stdin: request.stdin, cancelled: cancelled
    ) { output in
      reply(
        .success([
          "status": .number(Double(output.status)), "stdout": .string(output.stdout.base64EncodedString()),
          "stderr": .string(output.stderr.base64EncodedString()),
        ]))
    }
  }
}
