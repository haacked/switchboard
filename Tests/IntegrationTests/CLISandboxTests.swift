import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A listener that the test owns. It answers each connection's first line with the answer for its op, then closes
/// the connection, and it records every line it read.
private final class CannedListener: @unchecked Sendable {
  let path: String
  private let fd: Int32
  private let answers: [String: JSON]
  private let lock = NSLock()
  private var received: [JSON] = []
  private var stopped = false
  private let done = DispatchSemaphore(value: 0)

  init(_ path: String, answers: [String: JSON]) throws {
    self.path = path
    self.answers = answers
    fd = try UnixSocket.listen(path: path)
    Thread.detachNewThread { [self] in serve() }
  }

  private func serve() {
    defer { done.signal() }
    while !lock.withLock({ stopped }) {
      var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&waiting, 1, 100) == 1 else { continue }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      UnixSocket.configure(client, timeout: 5)
      var reader = UnixSocket.LineReader(fd: client)
      if let line = try? reader.next(), let request = JSON.parse(String(decoding: line, as: UTF8.self)) {
        lock.withLock { received.append(request) }
        let answer: JSON = ["ok": true, "result": answers[request["op"]?.string ?? ""] ?? .null]
        try? UnixSocket.write(client, Data((answer.text + "\n").utf8))
      }
      close(client)
    }
  }

  /// Every request line that reached the listener, oldest first.
  var requests: [JSON] { lock.withLock { received } }

  func stop() {
    lock.withLock { stopped = true }
    _ = done.wait(timeout: .now() + 2)
    close(fd)
  }
}

/// The real path of the built `sb`. The sandbox's exec rule names a real path, and `.build/debug` is a link.
private let sbBinary = real("\(Instance.bin)/sb")

/// The answer that the canned listener gives to `ping`.
private let cannedPing: JSON = ["version": "canned", "pid": 4242, "home": "/canned/home"]

/// A valid 1×1 PNG.
private let png = Data([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49,
  0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

/// A private stand-in for sbd's home under a short /tmp folder, so every socket path stays under the 104-byte
/// limit: `sbd.sock` stands in for sbd's own socket, and `hosts/mini/sbd.sock` and `hosts/other/sbd.sock` for two
/// hosts' sockets. Each socket has a canned listener. `launchctl` records its arguments in `launchctl.log`, and
/// `agents` stands in for `~/Library/LaunchAgents`. Nothing here touches `~/.sb` or the user's launchd.
private final class SandboxBench {
  let root: String
  let sbd: CannedListener
  let mini: CannedListener
  let other: CannedListener
  let profile: String

  init() throws {
    var template = Array("/tmp/sbt-XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    root = String(cString: dir)
    for folder in ["hosts/mini", "hosts/other", "agents", "pictures"] {
      try FileManager.default.createDirectory(
        atPath: "\(root)/\(folder)", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let answers: [String: JSON] = ["ping": cannedPing, "send": ["delivery": "sent"]]
    sbd = try CannedListener("\(root)/sbd.sock", answers: answers)
    mini = try CannedListener("\(root)/hosts/mini/sbd.sock", answers: answers)
    other = try CannedListener("\(root)/hosts/other/sbd.sock", answers: answers)
    // The listener comes first, because the profile names the socket's real path.
    profile = try HostCLI.profile(sb: sbBinary, socket: mini.path)
    try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"\(root)/launchctl.log\"\n".utf8)
      .write(to: URL(fileURLWithPath: launchctl))
    chmod(launchctl, 0o755)
  }

  func close() {
    for listener in [sbd, mini, other] { listener.stop() }
    try? FileManager.default.removeItem(atPath: root)
  }

  var hostHome: String { "\(root)/hosts/mini" }
  var launchctl: String { "\(root)/launchctl" }
  var launchctlLog: String { "\(root)/launchctl.log" }
  var plist: String { "\(root)/agents/com.haacked.switchboard.sbd.plist" }

  /// The environment that sbd gives the subprocess for mini, with nothing of this test process.
  func environment(session: String? = nil, claudecode: String? = nil) -> [String: String] {
    HostCLI.environment(
      hostHome: hostHome, host: "mini", cwd: "/home/u/worktrees/x", session: session, claudecode: claudecode)
  }

  /// The environment of a `service` case: the recorder in place of launchctl, and the test's folder in place of
  /// `~/Library/LaunchAgents`, so a sandbox regression records a call and boots out nothing.
  func serviceEnvironment(hostMode: Bool) -> [String: String] {
    var env = environment()
    env["SB_LAUNCHCTL"] = launchctl
    env["SB_LAUNCH_AGENTS"] = "\(root)/agents"
    // Host mode refuses `service` before it does anything. Without SB_CLI_HOST, the sandbox is the only guard.
    if !hostMode { env["SB_CLI_HOST"] = nil }
    return env
  }

  /// Runs `sb` once under the profile in mini's folder, as sbd's runner does.
  func sandboxed(_ argv: [String], env: [String: String], stdin: Data = Data()) throws -> CommandResult {
    try runCommand(
      "/usr/bin/sandbox-exec", ["-p", profile, sbBinary] + argv, env: env, input: stdin, timeout: 30, cwd: hostHome)
  }

  /// Runs `sb` once with no sandbox, as the control for a denial. Only harmless reads run this way.
  func unsandboxed(_ argv: [String], env: [String: String]) throws -> CommandResult {
    try runCommand(sbBinary, argv, env: env, input: Data(), timeout: 30, cwd: hostHome)
  }
}

private func withSandbox(_ body: (SandboxBench) throws -> Void) throws {
  let bench = try SandboxBench()
  defer { bench.close() }
  try body(bench)
}

/// The sandbox's recent denials, for the message of a failed positive control.
private func sandboxLog() -> String {
  let r = try? runCommand(
    "/usr/bin/log", ["show", "--last", "30s", "--style", "compact", "--predicate", #"sender == "Sandbox""#],
    timeout: 20)
  return r.map { String($0.stdout.suffix(4_000)) } ?? "log show failed"
}

/// The real `sb` under `HostCLI.profile`, with `HostCLI.environment`. Each case runs `sb` once against sockets
/// that the test owns, with no sbd and no ssh stub. The two positive controls show that `sb` starts and reaches
/// mini's socket under the profile, so a denial below fails because of the sandbox and not because `sb` never
/// ran. Each denial that reads something harmless is paired with the same run without the profile, which reaches
/// the resource.
@Suite(.blocking(timeLimit: .seconds(60))) struct CLISandboxTests {
  // MARK: Positive controls

  @Test func sbStartsUnderTheProfile() throws {
    try withSandbox { b in
      let r = try b.sandboxed(["version"], env: b.environment())

      #expect(r.status == 0 && !r.stdout.isEmpty, "\(text(r))\n\(r.status == 0 ? "" : sandboxLog())")
    }
  }

  @Test func sbUnderTheProfileReachesTheHostsSocket() throws {
    try withSandbox { b in
      let r = try b.sandboxed(["ping", "--json"], env: b.environment())

      #expect(r.status == 0, "\(text(r))\n\(r.status == 0 ? "" : sandboxLog())")
      #expect(JSON.parse(r.stdout) == cannedPing, "\(r.stdout)")
      #expect(b.mini.requests.map { $0["op"] } == ["ping"])
    }
  }

  /// The profile built from a path through a link names the real path, which the exec of the real `sb` matches.
  @Test func aProfileBuiltFromALinkedSbPathStillRunsTheRealSb() throws {
    try withSandbox { b in
      try FileManager.default.createSymbolicLink(
        atPath: "\(b.root)/bin", withDestinationPath: (sbBinary as NSString).deletingLastPathComponent)
      let profile = try HostCLI.profile(sb: "\(b.root)/bin/sb", socket: b.mini.path)

      let r = try runCommand(
        "/usr/bin/sandbox-exec", ["-p", profile, sbBinary, "ping", "--json"], env: b.environment(), input: Data(),
        timeout: 30, cwd: b.hostHome)

      #expect(r.status == 0, "\(text(r))")
      #expect(JSON.parse(r.stdout) == cannedPing, "\(r.stdout)")
    }
  }

  // MARK: Reads of this Mac's files

  @Test func sendWithAnImageReadsTheMacFileOnlyWithoutTheSandbox() throws {
    try withSandbox { b in
      let picture = "\(b.root)/pictures/shot.png"
      try png.write(to: URL(fileURLWithPath: picture))
      let argv = ["send", "s1", "--image", picture, "look"]

      let control = try b.unsandboxed(argv, env: b.environment())
      let reached = b.mini.requests
      let denied = try b.sandboxed(argv, env: b.environment())

      #expect(control.status == 0, "\(text(control))")
      #expect(reached.count == 1 && reached.first?["args"]?["images"]?.array?.count == 1, "\(reached)")
      #expect(denied.status == 1, "\(text(denied))")
      #expect(denied.stderr.contains("can't read shot.png: Operation not permitted"), "\(denied.stderr)")
      #expect(
        b.mini.requests.count == reached.count, "the sandboxed sb sent \(b.mini.requests.dropFirst(reached.count))")
    }
  }

  // MARK: Other sockets

  /// The environment can't name sbd's own socket, but a regression that let it would still find the connect denied.
  @Test func aConnectToSbdsOwnSocketIsDeniedUnderTheProfile() throws {
    try withSandbox { b in
      var env = b.environment()
      env["SB_HOME"] = b.root

      let control = try b.unsandboxed(["ping", "--json"], env: env)
      let reached = b.sbd.requests.count
      let denied = try b.sandboxed(["ping", "--json"], env: env)

      #expect(control.status == 0, "\(text(control))")
      #expect(reached == 1)
      #expect(denied.status == 1, "\(text(denied))")
      #expect(denied.stderr.contains("Operation not permitted"), "\(denied.stderr)")
      #expect(b.sbd.requests.count == reached)
    }
  }

  @Test func aConnectToAnotherHostsSocketIsDeniedUnderTheProfile() throws {
    try withSandbox { b in
      var env = b.environment()
      env["SB_HOME"] = "\(b.root)/hosts/other"

      let control = try b.unsandboxed(["ping", "--json"], env: env)
      let reached = b.other.requests.count
      let denied = try b.sandboxed(["ping", "--json"], env: env)

      #expect(control.status == 0, "\(text(control))")
      #expect(reached == 1)
      #expect(denied.status == 1, "\(text(denied))")
      #expect(denied.stderr.contains("Operation not permitted"), "\(denied.stderr)")
      #expect(b.other.requests.count == reached)
    }
  }

  // MARK: launchd

  /// `service uninstall` ignores the failures of launchctl and of the removal, so its exit status says nothing.
  /// The recorder and the plist show what ran.
  @Test func serviceUninstallUnderTheProfileRunsNoLaunchctlAndRemovesNoPlist() throws {
    try withSandbox { b in
      try Data("mine".utf8).write(to: URL(fileURLWithPath: b.plist))

      let r = try b.sandboxed(["service", "uninstall"], env: b.serviceEnvironment(hostMode: false))

      #expect(!FileManager.default.fileExists(atPath: b.launchctlLog), "launchctl ran: \(text(r))")
      #expect(FileManager.default.contents(atPath: b.plist) == Data("mine".utf8), "the plist changed: \(text(r))")
    }
  }

  /// `service install` first checks that sbd is executable next to `sb`. The sandbox denies that check, so `sb`
  /// reports no sbd although the file is there. A sandbox that allowed the check would deny the plist's write.
  @Test func serviceInstallUnderTheProfileRunsNoLaunchctlAndWritesNoPlist() throws {
    try withSandbox { b in
      let sbd = "\((sbBinary as NSString).deletingLastPathComponent)/sbd"
      try #require(FileManager.default.isExecutableFile(atPath: sbd), "no sbd next to the built sb at \(sbd)")

      let r = try b.sandboxed(["service", "install"], env: b.serviceEnvironment(hostMode: false))

      #expect(!FileManager.default.fileExists(atPath: b.launchctlLog), "launchctl ran: \(text(r))")
      #expect(!FileManager.default.fileExists(atPath: b.plist), "sb wrote the plist: \(text(r))")
      #expect(r.status == 1, "\(text(r))")
      #expect(
        r.stderr.contains("no sbd next to sb at \(sbd)") || r.stderr.contains("Operation not permitted")
          || r.stderr.contains("permission"),
        "sb failed for a reason other than the sandbox: \(r.stderr)")
    }
  }

  // MARK: Host mode

  /// Host mode refuses these commands with a clear message before they do anything. Each run is under the profile
  /// and with the recorder, so a run that host mode lets through still reaches nothing.
  @Test(arguments: [
    ["attach", "s1"], ["attach", "s1", "--shell"], ["hook"], ["mcp-server"], ["service", "install"],
    ["service", "uninstall"], ["service", "status"],
  ])
  func hostModeRefusesACommandThatActsOnThisMacBeforeItRuns(argv: [String]) throws {
    try withSandbox { b in
      try Data("mine".utf8).write(to: URL(fileURLWithPath: b.plist))

      let r = try b.sandboxed(argv, env: b.serviceEnvironment(hostMode: true))

      #expect(r.status == 1, "\(text(r))")
      #expect(r.stderr.contains("sb \(argv[0]) doesn't run through mini's sb"), "\(r.stderr)")
      #expect(b.mini.requests.isEmpty, "sb sent \(b.mini.requests)")
      #expect(!FileManager.default.fileExists(atPath: b.launchctlLog), "launchctl ran")
      #expect(FileManager.default.contents(atPath: b.plist) == Data("mine".utf8), "the plist changed")
    }
  }

  // MARK: Paths that only sbd reads

  /// `sb` sends these paths to the socket and reads nothing at them. The host's scope refuses `repo-add` and
  /// `followup-import`, so the sandbox has nothing to deny here.
  @Test(
    arguments: [
      (["repo", "add", "/Users/u/secret-repo"], "repo-add", ["path": "/Users/u/secret-repo"]),
      (["followup", "import", "--file", "/Users/u/notes.md"], "followup-import", ["file": "/Users/u/notes.md"]),
    ] as [([String], String, [String: JSON])])
  func aPathThatOnlySbdReadsReachesTheHostsSocketAsTyped(argv: [String], op: String, args: [String: JSON]) throws {
    try withSandbox { b in
      _ = try b.sandboxed(argv, env: b.environment())

      let sent = b.mini.requests
      #expect(sent.count == 1, "\(sent)")
      #expect(sent.first?["op"]?.string == op)
      #expect(sent.first?["args"] == .object(args))
    }
  }
}
