import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct EntryPointTests {
  /// A launchctl stand-in that records its calls, prints `stderr`,
  /// and exits with `status` on bootstrap and 0 otherwise.
  private func fakeLaunchctl(in dir: String, status: Int = 0, stderr: String = "") throws -> String {
    let path = "\(dir)/launchctl"
    let script =
      "#!/bin/sh\necho \"$@\" >>\"\(dir)/launchctl.log\"\n"
      + (stderr.isEmpty ? "" : "echo \(shellQuote(stderr)) >&2\n")
      + "case \"$1\" in bootstrap) exit \(status);; *) exit 0;; esac\n"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
  }

  private func scratch() throws -> String {
    var template = Array("/tmp/sbe.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    return String(cString: dir)
  }

  @Test func serviceInstallCreatesTheLaunchAgentsFolder() throws {
    let sbd = try Instance()
    let fakeHome = sbd.home.path
    let launchctl = try fakeLaunchctl(in: fakeHome)
    let agents = "\(fakeHome)/Library/LaunchAgents"
    let r = try sbd.run(["service", "install"], env: ["SB_LAUNCH_AGENTS": agents, "SB_LAUNCHCTL": launchctl])
    #expect(r.status == 0, "\(r.stderr)")
    let plist = "\(agents)/com.haacked.switchboard.sbd.plist"
    #expect(FileManager.default.fileExists(atPath: plist))
    let log = try String(contentsOfFile: "\(fakeHome)/launchctl.log", encoding: .utf8)
    #expect(log.contains("bootstrap gui/\(getuid()) \(plist)"))
  }

  @Test func serviceInstallShowsLaunchctlsOutputWhenBootstrapFails() throws {
    let sbd = try Instance()
    let fakeHome = sbd.home.path
    let launchctl = try fakeLaunchctl(in: fakeHome, status: 5, stderr: "Bootstrap failed: 5: Input/output error")
    let r = try sbd.run(
      ["service", "install"], env: ["SB_LAUNCH_AGENTS": "\(fakeHome)/Library/LaunchAgents", "SB_LAUNCHCTL": launchctl])
    #expect(r.status == 1)
    #expect(r.stderr.contains("launchctl bootstrap failed"))
    #expect(r.stderr.contains("Bootstrap failed: 5: Input/output error"))
  }

  @Test func pollJSONExitsNonZeroWhenThePollFails() throws {
    let github = try FakeGitHub()
    let sbd = try Instance(config: [
      "github": [
        "gh": .string("/nonexistent/gh"), "url": .string(github.url), "pollSeconds": .number(0),
      ]
    ])
    _ = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    let plain = try sbd.run(["poll"])
    #expect(plain.status == 1, "plain poll must fail for this setup: \(plain.stdout)")
    let json = try sbd.run(["poll", "--json"])
    #expect(json.stdout.contains("\"error\""))
    #expect(json.status == 1)
  }

  @Test func aSecondSbdRefusesAHomeThatAnotherProcessLocks() throws {
    let home = Home(path: try scratch())
    defer { try? FileManager.default.removeItem(atPath: home.path) }
    try home.create()
    let fd = open(home.lock, O_CREAT | O_RDWR, 0o600)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    let r = try runCommand(
      "\(Instance.bin)/sbd", ["--home", home.path], env: ProcessInfo.processInfo.environment, timeout: 5)
    #expect(r.status == 1, "\(r.stderr)")
    #expect(r.stderr.contains("another sbd"))
  }

  @Test func aSecondSbdLeavesTheRunningSbdServing() throws {
    let sbd = try Instance()
    let r = try runCommand(
      "\(Instance.bin)/sbd", ["--home", sbd.home.path], env: ProcessInfo.processInfo.environment, timeout: 5)
    #expect(r.status == 1, "\(r.stderr)")
    #expect(r.stderr.contains("another sbd"))
    #expect((try? sbd.client.call("ping", timeout: 2)) != nil)
  }
}
