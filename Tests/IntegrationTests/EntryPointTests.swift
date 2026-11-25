import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct EntryPointTests {
  /// A launchctl stand-in that records its calls, prints `stderr`,
  /// and exits with `status` on bootstrap and 0 otherwise. With `startingSbdAfter`, bootstrap also starts sbd on
  /// the home in `dir` after that many seconds, as launchd starts an sbd that loads its sessions before it answers.
  private func fakeLaunchctl(
    in dir: String, status: Int = 0, stderr: String = "", startingSbdAfter delay: Int? = nil
  ) throws -> String {
    let path = "\(dir)/launchctl"
    let start = delay.map {
      "(sleep \($0); exec \(shellQuote("\(Instance.bin)/sbd")) --home \(shellQuote(dir))) </dev/null >>\(shellQuote("\(dir)/sbd.log")) 2>&1 &\n"
    }
    let script =
      "#!/bin/sh\necho \"$@\" >>\"\(dir)/launchctl.log\"\n"
      + (stderr.isEmpty ? "" : "echo \(shellQuote(stderr)) >&2\n")
      + "case \"$1\" in bootstrap) \(start ?? "")exit \(status);; *) exit 0;; esac\n"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    return path
  }

  private func scratch() throws -> String {
    var template = Array("/tmp/sbe.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    return String(cString: dir)
  }

  @Test func sbdRefusesToStartWithoutItsPromptFiles() throws {
    let empty = try scratch()
    defer { try? FileManager.default.removeItem(atPath: empty) }
    let sbd = "\(Instance.bin)/sbd"

    let broken = try runCommand(
      sbd, ["--check-prompts"], env: ["SB_PROMPTS_DIR": empty], input: Data(), timeout: 30, cwd: empty)
    let found = try runCommand(sbd, ["--check-prompts"], env: [:], input: Data(), timeout: 30, cwd: empty)

    #expect(broken.status == 1 && broken.stderr.contains("can't read prompt \(empty)/"), "\(broken.stderr)")
    #expect(found.status == 0 && found.stdout.contains("prompts ok"), "\(found.stderr)")
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

  /// The first start after an update replays every event before sbd opens its socket. That can take longer
  /// than 5 s.
  @Test func serviceInstallWaitsForAnSbdThatAnswersLate() throws {
    let sbd = try Instance(startingSbd: false)
    let fakeHome = sbd.home.path
    let launchctl = try fakeLaunchctl(in: fakeHome, startingSbdAfter: 7)
    let r = try sbd.run(
      ["service", "install"], env: ["SB_LAUNCH_AGENTS": "\(fakeHome)/Library/LaunchAgents", "SB_LAUNCHCTL": launchctl])
    #expect(r.status == 0, "\(r.stderr)")
    #expect(r.stdout.contains("waiting for sbd to load its sessions…"), "\(r.stdout)")
    #expect(r.stdout.contains("sbd runs as a launchd agent"), "\(r.stdout)")
  }

  @Test func serviceInstallFailsWhenSbdNeverAnswers() throws {
    let sbd = try Instance(startingSbd: false)
    let fakeHome = sbd.home.path
    let launchctl = try fakeLaunchctl(in: fakeHome)
    let r = try sbd.run(
      ["service", "install"],
      env: [
        "SB_LAUNCH_AGENTS": "\(fakeHome)/Library/LaunchAgents", "SB_LAUNCHCTL": launchctl, "SB_SERVICE_WAIT": "3",
      ])
    #expect(r.status == 1, "\(r.stdout)")
    #expect(r.stderr.contains("sbd did not answer. See \(sbd.home.log)"), "\(r.stderr)")
    #expect(r.stdout.contains("waiting for sbd to load its sessions…"), "\(r.stdout)")
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
