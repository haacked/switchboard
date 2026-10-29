import Foundation
import SwitchboardCore
import Testing

/// The pids of the processes whose arguments match the pattern.
func processes(matching pattern: String) -> [String] {
  ((try? runCommand("/usr/bin/pgrep", ["-f", pattern]))?.stdout ?? "").split(separator: "\n").map(String.init)
}

/// The processes whose arguments name a path in the home, as Fixtures/reap
/// finds them.
func processes(of home: String) -> [String] {
  processes(matching: "\(home)(/| |$)")
}

extension Instance {
  /// Starts a session whose stub waits in a permission dialog, with a
  /// background hook, a terminal reader, and a polling loop.
  func newInADialog() throws -> SessionSummary {
    let s = try new(prompt: "perm touch x")
    try waitFor(s.id, "the card") { !$0.cards.isEmpty }
    return s
  }

}

func reaped(_ home: String) -> Bool {
  processes(of: home).isEmpty && !FileManager.default.fileExists(atPath: home)
}

@Suite(.timeLimit(.minutes(2))) struct CleanupTests {
  @Test func theStubEndsWhenItsTerminalCloses() throws {
    let sbd = try Instance()
    let s = try sbd.newInADialog()
    let t = try sbd.client.terminals(s.id)
    #expect(try runCommand(t.tmux, ["-S", t.socket, "kill-server"]).status == 0)
    try sbd.waitFor("the stub to exit") { processes(matching: sbd.home.claudeSettings).isEmpty }
    try sbd.waitFor("the held hook to end") { !sbd.heldHookRuns() }
  }

  @Test func deinitEndsEveryProcessOfTheHome() throws {
    var sbd: Instance? = try Instance()
    _ = try sbd!.newInADialog()
    let home = sbd!.home.path
    #expect(!processes(of: home).isEmpty)
    #expect(!processes(matching: "/sbd --home \(home)$").isEmpty)
    sbd = nil
    #expect(reaped(home))
  }

  @Test func reapsTheHomesOfATestProcessAfterItExits() throws {
    let sbd = try Instance()
    _ = try sbd.newInADialog()
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["60"]
    try owner.run()
    try sbd.home.setOwner(owner.processIdentifier)
    try Instance.watch(owner.processIdentifier)
    // The pause lets the watcher finish its first sweep. The reap below then
    // comes from its sweep after the owner exits.
    usleep(500_000)
    #expect(!processes(of: sbd.home.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: sbd.home.path))
    kill(owner.processIdentifier, SIGKILL)
    try sbd.waitFor("the reap") { reaped(sbd.home.path) }
  }

  @Test func reapsTheHomesOfEarlierRunsWhoseTestProcessExited() throws {
    let sbd = try Instance()
    _ = try sbd.newInADialog()
    let live = try Instance()
    let unowned = try Instance()
    try FileManager.default.removeItem(atPath: "\(unowned.home.path)/owner.pid")
    let owner = try runProcess("/usr/bin/true")
    try sbd.home.setOwner(owner)
    #expect(try runCommand(Instance.reap, ["--orphans"]).status == 0)
    #expect(reaped(sbd.home.path))
    for spared in [live, unowned] {
      #expect(!processes(of: spared.home.path).isEmpty)
      #expect(FileManager.default.fileExists(atPath: spared.home.path))
    }
  }

  @Test(arguments: ["/tmp/sbt.", "/var/sbt.abcdef", "/tmp/sbt.ab-def", "/tmp/sbt.ab/def", "/tmp/sbt.abcdefg"])
  func refusesAHomeThatMkdtempDidNotMake(_ path: String) throws {
    // The decoy's arguments name the path, so a reap of the path would end it.
    // A loop keeps sh from exec'ing a lone command, which would drop the path.
    let decoy = Process()
    decoy.executableURL = URL(fileURLWithPath: "/bin/sh")
    decoy.arguments = ["-c", "while :; do sleep 0.1; done", "\(path)/decoy"]
    try decoy.run()
    defer { decoy.terminate() }
    #expect(try Instance.reapHome(path).status != 0)
    #expect(processes(of: path).contains(String(decoy.processIdentifier)))
  }
}

/// Runs the program to its end, and returns its pid.
private func runProcess(_ path: String) throws -> pid_t {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: path)
  try p.run()
  p.waitUntilExit()
  return p.processIdentifier
}
