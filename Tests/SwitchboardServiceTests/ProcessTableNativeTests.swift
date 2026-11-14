import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// `ProcessTable.readLocal()` reads this Mac's processes with `sysctl`. These tests compare it with a real
/// `/bin/ps -axo pid=,ppid=,pgid=,command=` parsed by `ProcessTable.parse`, for processes that the tests start. The
/// suite lives here and not in SwitchboardCoreTests because it also compares `Service.isClaude` and
/// `Service.backgroundJobs` over both tables.
@Suite(.serialized, .timeLimit(.minutes(2))) struct ProcessTableNativeTests {
  // MARK: Equivalence with ps

  @Test func aScriptRunByAnInterpreterWithASpacedArgumentMatchesPsAndIsClaudeInBothTables() throws {
    let folder = try makeShortTempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try "/bin/sleep 120\n".write(toFile: "\(folder)/claude", atomically: true, encoding: .utf8)
    let sh = try Child("/bin/sh", ["\(folder)/claude", "a b"])
    defer { sh.stop() }
    try waitForPs("the script's sleep below \(sh.pid)") { ps in
      ps.command(of: sh.pid) == "/bin/sh \(folder)/claude a b"
        && ps.children(of: sh.pid).contains { ps.command(of: $0.pid) == "/bin/sleep 120" }
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: sh.pid, native: native, ps: ps)
    let nativeAnswer = Service.isClaude(native.command(of: sh.pid) ?? "", program: "claude")
    let psAnswer = Service.isClaude(ps.command(of: sh.pid) ?? "", program: "claude")
    #expect(nativeAnswer == psAnswer, "native: \(String(describing: native.command(of: sh.pid)))")
    #expect(nativeAnswer, "native: \(String(describing: native.command(of: sh.pid)))")
  }

  @Test func anArgvZeroThatDiffersFromTheProgramMatchesPs() throws {
    let bash = try Child("/bin/bash", ["-c", "exec -a renamed-sleep /bin/sleep 120"])
    defer { bash.stop() }
    try waitForPs("\(bash.pid) to exec as renamed-sleep") { $0.command(of: bash.pid) == "renamed-sleep 120" }

    let (native, ps) = try readBoth()

    try expectSameRows(below: bash.pid, native: native, ps: ps)
  }

  @Test func anEmptyArgumentMatchesPs() throws {
    let sh = try Child("/bin/sh", ["-c", "/bin/sleep 120; :", "", "x"])
    defer { sh.stop() }
    try waitForPs("the sleep below \(sh.pid)") { ps in
      ps.command(of: sh.pid) == "/bin/sh -c /bin/sleep 120; :  x" && !ps.children(of: sh.pid).isEmpty
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: sh.pid, native: native, ps: ps)
  }

  @Test func aVeryLongCommandMatchesPsUntruncated() throws {
    let long = String(repeating: "x", count: 12_000)
    let sh = try Child("/bin/sh", ["-c", "/bin/sleep 120; :", long])
    defer { sh.stop() }
    try waitForPs("the long command of \(sh.pid)") { ps in
      ps.command(of: sh.pid) == "/bin/sh -c /bin/sleep 120; : \(long)" && !ps.children(of: sh.pid).isEmpty
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: sh.pid, native: native, ps: ps)
  }

  @Test func aChildThatLeadsItsOwnProcessGroupMatchesPsAndCountsAsOneJobInBothTables() throws {
    let sh = try Child("/bin/sh", ["-c", "set -m; /bin/sleep 120 & wait"])
    defer { sh.stop() }
    try waitForPs("a group-leading sleep below \(sh.pid)") { ps in
      ps.children(of: sh.pid).contains { $0.pgid == $0.pid && ps.command(of: $0.pid) == "/bin/sleep 120" }
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: sh.pid, native: native, ps: ps)
    try withService { service, _ in
      #expect(service.backgroundJobs(sh.pid, in: native) == service.backgroundJobs(sh.pid, in: ps))
      #expect(service.backgroundJobs(sh.pid, in: native) == 1)
    }
  }

  /// The `true` exits and its parent never waits for it. Without `set -m` the zombie stays in the shell's process
  /// group. With it, the zombie led its own group, which `backgroundJobs` counts.
  static let zombieScripts = ["/usr/bin/true & exec /bin/sleep 120", "set -m; /usr/bin/true & exec /bin/sleep 120"]

  @Test(arguments: zombieScripts)
  func aZombieMatchesPsIsDefunctAndCountsTheSameJobsInBothTables(script: String) throws {
    let sleep = try Child("/bin/sh", ["-c", script])
    defer { sleep.stop() }
    try waitForZombie(below: sleep.pid)

    let (native, ps) = try readBoth()

    try expectSameRows(below: sleep.pid, native: native, ps: ps)
    try withService { service, _ in
      #expect(service.backgroundJobs(sleep.pid, in: native) == service.backgroundJobs(sleep.pid, in: ps))
    }
    let zombie = try #require(native.children(of: sleep.pid).first, "no child of \(sleep.pid) in the native table")
    #expect(native.command(of: zombie.pid) == "<defunct>")
  }

  /// Perl writes the new title over its argv and pads the rest with spaces, so the argc strings that ps joins end
  /// in the environment. The environment is set, so that its first string holds no newline.
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
  func aProcessThatRewritesItsArgvMatchesPs() throws {
    let perl = try Child(
      "/usr/bin/perl", ["-e", "$0 = 'renamed by perl'; sleep 120"], environment: ["SB_TEST_TITLE": "1"])
    defer { perl.stop() }
    try waitForPs("\(perl.pid) to rename itself") { $0.command(of: perl.pid)?.hasPrefix("renamed by perl") == true }

    let (native, ps) = try readBoth()

    try expectSameRows(below: perl.pid, native: native, ps: ps)
  }

  @Test func aNonASCIIArgumentMatchesPs() throws {
    let sh = try Child("/bin/sh", ["-c", "/bin/sleep 120; :", "é ☎"])
    defer { sh.stop() }
    try waitForPs("the sleep below \(sh.pid)") { ps in
      ps.command(of: sh.pid) == "/bin/sh -c /bin/sleep 120; : é ☎" && !ps.children(of: sh.pid).isEmpty
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: sh.pid, native: native, ps: ps)
  }

  /// ps sorts by terminal device, then pid, and a process with no terminal comes first. The setsid child starts
  /// second, so it has the higher pid, but it has no terminal while its sibling has the pty that `script` opened.
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
  func childrenOnDifferentTerminalsKeepPsOrder() throws {
    let script = try Child(
      "/usr/bin/script",
      [
        "-q", "/dev/null", "/bin/sh", "-c",
        "/bin/sleep 120 & /usr/bin/perl -MPOSIX -e 'setsid(); exec @ARGV' /bin/sleep 121 & wait",
      ])
    defer { script.stop() }
    var shPid = 0
    try waitForPs("both sleeps below the shell of \(script.pid)") { ps in
      guard let sh = ps.children(of: script.pid).first else { return false }
      shPid = sh.pid
      let commands = Set(ps.children(of: sh.pid).compactMap { ps.command(of: $0.pid) })
      return commands == ["/bin/sleep 120", "/bin/sleep 121"]
    }

    let (native, ps) = try readBoth()

    try expectSameRows(below: script.pid, native: native, ps: ps)
    #expect(native.children(of: shPid).first.flatMap { native.command(of: $0.pid) } == "/bin/sleep 121")
  }

  /// Another user's argv is unreadable without root, so only pid, ppid, and pgid are compared. A row whose two
  /// native reads differ changed during the reads, so it is left out.
  @Test func otherUsersRowsMatchPsInPidParentAndGroup() throws {
    let first = ProcessTable.readLocal()
    let ps = try psTable()
    let second = ProcessTable.readLocal()

    let stable = first.all.filter { row in
      let uid = Processes.info(of: pid_t(row.pid))?.kp_eproc.e_ucred.cr_uid
      return uid.map { $0 != getuid() } == true && second.row(row.pid) == row && ps.row(row.pid) != nil
    }

    #expect(stable.contains { $0.pid == 1 }, "pid 1 is not among the other users' rows")
    #expect(stable.count > 1, "\(stable.count) other users' rows")
    for row in stable {
      let listed = try #require(ps.row(row.pid))
      #expect(row.ppid == listed.ppid, "ppid of \(row.pid)")
      #expect(row.pgid == listed.pgid, "pgid of \(row.pid)")
    }
  }

  @Test func pid1HasANativeCommand() throws {
    let native = ProcessTable.readLocal()
    let ps = try psTable()

    let command = native.command(of: 1)

    #expect(command != nil, "ps prints \(String(describing: ps.command(of: 1)))")
  }

  // MARK: The start-time guard on command(of:)

  @Test func aRowBuiltFromTheReadAnswersItsCommand() throws {
    let sleep = try Child("/bin/sleep", ["120"])
    defer { sleep.stop() }
    try waitForPs("\(sleep.pid) to run sleep") { $0.command(of: sleep.pid) == "/bin/sleep 120" }
    let row = try #require(ProcessTable.readLocal().row(sleep.pid))

    let table = ProcessTable(nativeRows: [row])

    #expect(table.command(of: sleep.pid) == "/bin/sleep 120")
  }

  /// A pid that a new process reused has a different start time. A shift of one microsecond shows that the guard
  /// compares the whole start time and not only its seconds.
  @Test(arguments: [1_000_000, 1] as [Int64])
  func aLiveRowWithAnotherStartTimeHasNoCommand(shift: Int64) throws {
    let sleep = try Child("/bin/sleep", ["120"])
    defer { sleep.stop() }
    try waitForPs("\(sleep.pid) to run sleep") { $0.command(of: sleep.pid) == "/bin/sleep 120" }
    let row = try #require(ProcessTable.readLocal().row(sleep.pid))

    let table = ProcessTable(nativeRows: [row.startingLater(byMicroseconds: shift)])

    #expect(table.command(of: sleep.pid) == nil)
  }

  /// Without root, pid 1's argv is unreadable, so its command comes from the fallback, which the guard covers too.
  @Test func pid1WithAnotherStartTimeHasNoFallbackCommand() throws {
    let row = try #require(ProcessTable.readLocal().row(1))

    let table = ProcessTable(nativeRows: [row.startingLater(byMicroseconds: 1_000_000)])

    #expect(table.command(of: 1) == nil)
  }

  @Test func pid1BuiltFromTheReadAnswersItsFallbackCommand() throws {
    let row = try #require(ProcessTable.readLocal().row(1))

    let table = ProcessTable(nativeRows: [row])

    #expect(table.command(of: 1) != nil)
  }

  @Test func aRowForAPidThatExitedHasNoCommand() throws {
    let sleep = try Child("/bin/sleep", ["120"])
    defer { sleep.stop() }
    try waitForPs("\(sleep.pid) to run sleep") { $0.command(of: sleep.pid) == "/bin/sleep 120" }
    let native = ProcessTable.readLocal()
    try #require(native.row(sleep.pid) != nil)

    sleep.stop()

    #expect(native.command(of: sleep.pid) == nil)
  }

  /// The process runs and its argv is readable, but it started after the read.
  @Test func aLivePidThatTheTableDoesNotListHasNoCommand() throws {
    let native = ProcessTable.readLocal()
    let sleep = try Child("/bin/sleep", ["120"])
    defer { sleep.stop() }
    try waitForPs("\(sleep.pid) to run sleep") { $0.command(of: sleep.pid) == "/bin/sleep 120" }
    try #require(native.row(sleep.pid) == nil, "the earlier read lists a process with pid \(sleep.pid)")

    let command = native.command(of: sleep.pid)

    #expect(command == nil)
  }

  // MARK: The KERN_PROCARGS2 parser

  @Test func argvHoldsArgcStringsAfterThePathAndItsPadding() {
    let buffer = procArgs(argc: 2, path: "/bin/sleep", padding: 5, ["sleep", "30", "PATH=/bin", "HOME=/x"])

    #expect(ProcessTable.argv(fromProcArgs: buffer) == ["sleep", "30"])
  }

  @Test func argvKeepsAnEmptyArgument() {
    let buffer = procArgs(argc: 3, path: "/bin/sh", padding: 3, ["sh", "", "x", "TERM=dumb"])

    #expect(ProcessTable.argv(fromProcArgs: buffer) == ["sh", "", "x"])
  }

  @Test func argvKeepsASpaceInsideAnArgument() {
    let buffer = procArgs(argc: 2, path: "/bin/sh", padding: 0, ["/bin/sh", "a b"])

    #expect(ProcessTable.argv(fromProcArgs: buffer) == ["/bin/sh", "a b"])
  }

  @Test func argvWithAnArgcLargerThanTheStringsStopsAtTheEnd() {
    let buffer = procArgs(argc: 5, path: "/bin/sleep", padding: 2, ["sleep", "30"])

    #expect(ProcessTable.argv(fromProcArgs: buffer) == ["sleep", "30"])
  }

  @Test(
    arguments: [
      ("an empty buffer", []),
      ("two bytes, shorter than argc", [2, 0]),
      ("argc alone", procArgs(argc: 2, path: nil, padding: 0, [])),
      ("an empty argv", procArgs(argc: 0, path: "/bin/sleep", padding: 4, ["PATH=/bin"])),
      ("a negative argc", procArgs(argc: -1, path: "/bin/sleep", padding: 4, ["sleep"])),
      ("a path without its NUL", procArgs(argc: 1, path: nil, padding: 0, []) + Array("/bin/sleep".utf8)),
    ] as [(String, [UInt8])])
  func argvOfABufferWithNoArgumentsIsEmpty(_ what: String, buffer: [UInt8]) {
    #expect(ProcessTable.argv(fromProcArgs: buffer) == [], "\(what)")
  }
}

// MARK: Helpers

/// A process that a test starts, with stdin, stdout, and stderr on the null device.
private final class Child {
  let process = Process()
  var pid: Int { Int(process.processIdentifier) }

  init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  /// Kills every process below the child, because a background child or a grandchild in its own process group
  /// outlives the child. Then it kills and reaps the child. A reaped child's pid may belong to another process, so
  /// it kills nothing once the child is gone.
  func stop() {
    guard process.isRunning else { return process.waitUntilExit() }
    if let ps = try? psTable() {
      for below in ps.descendants(of: [pid]) where below != pid { kill(pid_t(below), SIGKILL) }
    }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }
}

private func psTable() throws -> ProcessTable {
  let r = try runCommand("/bin/ps", ["-axo", "pid=,ppid=,pgid=,command="])
  try #require(r.status == 0, "ps failed: \(r.stderr)")
  return ProcessTable.parse(r.stdout)
}

/// Polls ps until `ready` holds, so that both reads see the processes after their last exec. A failed ps ends the
/// wait with its error.
private func waitForPs(_ what: String, _ ready: (ProcessTable) -> Bool) throws {
  var failure: (any Error)?
  let shown = waitUntil(seconds: 30) {
    do {
      return ready(try psTable())
    } catch {
      failure = error
      return true
    }
  }
  if let failure { throw failure }
  guard shown else { throw APIError("ps never showed \(what)") }
}

private func waitForZombie(below pid: Int) throws {
  try waitForPs("a <defunct> child of \(pid)") { ps in
    ps.command(of: pid) == "/bin/sleep 120" && ps.children(of: pid).contains { ps.command(of: $0.pid) == "<defunct>" }
  }
}

private func readBoth() throws -> (native: ProcessTable, ps: ProcessTable) {
  let native = ProcessTable.readLocal()
  let ps = try psTable()
  return (native, ps)
}

/// Compares the root and every process below it in the ps read: ppid, pgid, command, and the order of children.
private func expectSameRows(
  below root: Int, native: ProcessTable, ps: ProcessTable, sourceLocation: SourceLocation = #_sourceLocation
) throws {
  for pid in ps.descendants(of: [root]).sorted() {
    let listed = try #require(ps.row(pid), "ps lacks \(pid)", sourceLocation: sourceLocation)
    let read = try #require(native.row(pid), "the native table lacks \(pid)", sourceLocation: sourceLocation)
    #expect(read.ppid == listed.ppid, "ppid of \(pid)", sourceLocation: sourceLocation)
    #expect(read.pgid == listed.pgid, "pgid of \(pid)", sourceLocation: sourceLocation)
    #expect(native.command(of: pid) == ps.command(of: pid), "command of \(pid)", sourceLocation: sourceLocation)
    #expect(
      native.children(of: pid).map(\.pid) == ps.children(of: pid).map(\.pid), "children of \(pid)",
      sourceLocation: sourceLocation)
  }
}

/// A `KERN_PROCARGS2` buffer: argc, the program path and its NUL, `padding` more NULs, then each string and its NUL.
/// The kernel puts the environment after argv, so `strings` may hold more than argc strings.
private func procArgs(argc: Int32, path: String?, padding: Int, _ strings: [String]) -> [UInt8] {
  var buffer = withUnsafeBytes(of: argc) { Array($0) }
  if let path { buffer += Array(path.utf8) + [0] }
  buffer += [UInt8](repeating: 0, count: padding)
  for s in strings { buffer += Array(s.utf8) + [0] }
  return buffer
}

extension ProcessRow {
  /// The row of a process that started later. `startTime` holds microseconds since the epoch.
  fileprivate func startingLater(byMicroseconds shift: Int64) -> ProcessRow {
    var row = self
    row.startTime += shift
    return row
  }
}
