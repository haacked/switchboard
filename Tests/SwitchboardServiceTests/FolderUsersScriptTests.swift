import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

// The script that `RemoteSite.folderUsers` runs on a host. It names the processes that use a folder, as
// `Processes.using` defines a use: a working folder, a program, or an open file that is the folder or inside it. An
// open directory is not a use. It reads `/proc/<pid>/cwd`, `exe`, and `fd/*` under the root that it gets as its
// second argument, falls back to `lsof -Fpn` when that root does not exist, and exits 97 when it has neither.
//
// These tests assume that the script runs as `/bin/sh -c <script> sb <folder> <process root>`, that it finds lsof
// through PATH, and that `RemoteSite.parseFolderUsers` reads its answer. An implementation that differs changes
// `runScript` and `answer`.

/// The status with which the script says that it can't check.
private let cantCheck: Int32 = 97

/// A folder to check, a sibling whose name starts with the folder's name, a fake process table, and a folder of
/// programs for PATH. Every path is resolved, as /proc's links are.
private struct Bench {
  let base: String
  let folder: String
  let sibling: String
  let proc: String
  let bin: String

  init(folderName: String = "w") throws {
    base = try #require(SwitchboardCore.realPath(try makeShortTempFolder()))
    folder = "\(base)/\(folderName)"
    sibling = "\(base)/\(folderName)x"
    proc = "\(base)/proc"
    bin = "\(base)/bin"
    let fm = FileManager.default
    for dir in ["\(folder)/sub", "\(folder)/bin", sibling, proc, bin] {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    for file in ["\(folder)/file", "\(folder)/bin/tool", "\(sibling)/file"] {
      try Data("x".utf8).write(to: URL(fileURLWithPath: file))
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: base) }

  /// A process in the fake table, whose links point where the arguments say. A nil link is missing, as a link of
  /// another user's process is unreadable.
  func process(_ pid: Int, cwd: String? = "/", exe: String? = "/bin/sleep", fds: [Int: String] = [:]) throws {
    let dir = "\(proc)/\(pid)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(dir)/fd", withIntermediateDirectories: true)
    if let cwd { try fm.createSymbolicLink(atPath: "\(dir)/cwd", withDestinationPath: cwd) }
    if let exe { try fm.createSymbolicLink(atPath: "\(dir)/exe", withDestinationPath: exe) }
    for (fd, target) in fds { try fm.createSymbolicLink(atPath: "\(dir)/fd/\(fd)", withDestinationPath: target) }
  }

  /// An `lsof` in `bin` that prints `output` and appends its arguments to `lsof-ran`.
  func lsof(printing output: String) throws {
    let script = """
      #!/bin/sh
      echo "$*" >> \(shellQuote("\(base)/lsof-ran"))
      cat <<'EOF'
      \(output)EOF

      """
    try Data(script.utf8).write(to: URL(fileURLWithPath: "\(bin)/lsof"))
    chmod("\(bin)/lsof", 0o755)
  }

  var lsofRan: Bool { FileManager.default.fileExists(atPath: "\(base)/lsof-ran") }
}

private func runScript(_ folder: String, root: String, path: String) throws -> CommandResult {
  try runCommand("/bin/sh", ["-c", RemoteSite.folderUsersScript, "sb", folder, root], env: ["PATH": path], timeout: 30)
}

/// The users in an answer of the script that exited 0.
private func answer(_ r: CommandResult) throws -> [FolderUser] {
  try #require(r.status == 0, "the script exited \(r.status): \(r.stderr)")
  return try RemoteSite.parseFolderUsers(Data(r.stdout.utf8))
}

private func withBench(folderName: String = "w", _ body: (Bench) throws -> Void) throws {
  let b = try Bench(folderName: folderName)
  defer { b.remove() }
  try body(b)
}

/// The script reads the fake process table that the test builds, as it reads /proc on Linux.
@Suite struct FolderUsersScriptTests {
  /// The users that the script finds in the bench's table. PATH has no lsof unless the test put one in `bin`.
  private func users(_ b: Bench, folder: String? = nil) throws -> [FolderUser] {
    try answer(try runScript(folder ?? b.folder, root: b.proc, path: "\(b.bin):/usr/bin:/bin"))
  }

  @Test func aProcessWhoseWorkingFolderIsInsideTheFolderIsFound() throws {
    try withBench { b in
      try b.process(101, cwd: "\(b.folder)/sub")

      let found = try users(b)

      #expect(found == [FolderUser(pid: 101, use: .workingFolder, path: "\(b.folder)/sub")])
    }
  }

  @Test func aProcessWhoseWorkingFolderIsTheFolderItselfIsFound() throws {
    try withBench { b in
      try b.process(102, cwd: b.folder)

      #expect(try users(b) == [FolderUser(pid: 102, use: .workingFolder, path: b.folder)])
    }
  }

  @Test func aProcessWhoseProgramIsInsideTheFolderIsFound() throws {
    try withBench { b in
      try b.process(103, cwd: "/", exe: "\(b.folder)/bin/tool")

      #expect(try users(b) == [FolderUser(pid: 103, use: .program, path: "\(b.folder)/bin/tool")])
    }
  }

  @Test func aProcessWithAnOpenFileInsideTheFolderIsFound() throws {
    try withBench { b in
      try b.process(104, fds: [0: "/dev/null", 3: "\(b.folder)/file"])

      #expect(try users(b) == [FolderUser(pid: 104, use: .openFile, path: "\(b.folder)/file")])
    }
  }

  /// A file watcher holds folders open, and open(2) can't write through a directory.
  @Test(arguments: ["", "/sub"])
  func anOpenDirectoryInsideTheFolderIsNotAUse(_ below: String) throws {
    try withBench { b in
      try b.process(105, fds: [3: b.folder + below])

      #expect(try users(b).isEmpty)
    }
  }

  /// The sibling's name starts with the folder's name, so a test of the text alone would match it.
  @Test func aProcessThatUsesOnlyASiblingOfTheFolderIsNotFound() throws {
    try withBench { b in
      try b.process(106, cwd: b.sibling, exe: "\(b.sibling)/file", fds: [3: "\(b.sibling)/file"])

      #expect(try users(b).isEmpty)
    }
  }

  @Test func descriptorsThatAreNotPathsAreIgnored() throws {
    try withBench { b in
      try b.process(107, fds: [3: "socket:[12345]", 4: "pipe:[678]", 5: "anon_inode:[eventfd]", 6: "/dev/null"])

      #expect(try users(b).isEmpty)
    }
  }

  /// `Processes.using` checks the working folder, then the program, then the open files, and names each process
  /// once.
  @Test func aProcessIsNamedOnceWithItsFirstUseInTheOrderOfTheMac() throws {
    try withBench { b in
      try b.process(108, cwd: b.folder, exe: "\(b.folder)/bin/tool", fds: [3: "\(b.folder)/file"])
      try b.process(109, cwd: "/", exe: "\(b.folder)/bin/tool", fds: [3: "\(b.folder)/file"])

      let found = try users(b).sorted { $0.pid < $1.pid }

      #expect(found.map(\.pid) == [108, 109])
      #expect(found.map(\.use) == [.workingFolder, .program])
    }
  }

  @Test func eachProcessThatUsesTheFolderIsFound() throws {
    try withBench { b in
      try b.process(110, cwd: "\(b.folder)/sub")
      try b.process(111, cwd: "/", exe: "\(b.folder)/bin/tool")
      try b.process(112, fds: [7: "\(b.folder)/file"])
      try b.process(113, cwd: b.sibling)

      #expect(Set(try users(b).map(\.pid)) == [110, 111, 112])
    }
  }

  /// /proc holds names that are not pids, such as `self` and `sys`. The script reads only the pids, so a process
  /// that `self` links to is named once.
  @Test func entriesOfTheTableThatAreNotPidsAreIgnored() throws {
    try withBench { b in
      try b.process(114, cwd: b.folder)
      try FileManager.default.createSymbolicLink(atPath: "\(b.proc)/self", withDestinationPath: "\(b.proc)/114")
      try FileManager.default.createDirectory(atPath: "\(b.proc)/sys", withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: "\(b.proc)/sys/cwd", withDestinationPath: b.folder)

      #expect(try users(b).map(\.pid) == [114])
    }
  }

  /// A link of another user's process can't be read. That process is left out, as `Processes.using` leaves out
  /// the processes that macOS does not let it read.
  @Test func aProcessWhoseLinksCantBeReadIsLeftOutAndTheRestAreFound() throws {
    try withBench { b in
      try b.process(115, cwd: nil, exe: nil)
      try b.process(116, cwd: b.folder)

      #expect(try users(b).map(\.pid) == [116])
    }
  }

  @Test func aFolderWhosePathHoldsASpaceIsChecked() throws {
    try withBench(folderName: "a b's $HOME") { b in
      try b.process(117, cwd: "\(b.folder)/sub")
      try b.process(118, cwd: b.sibling)

      #expect(try users(b).map(\.pid) == [117])
    }
  }

  /// The links in /proc hold resolved paths, so the script resolves the folder first.
  @Test func aFolderNamedThroughASymlinkIsResolved() throws {
    try withBench { b in
      let link = "\(b.base)/link"
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: b.folder)
      try b.process(119, cwd: "\(b.folder)/sub")

      #expect(try users(b, folder: link).map(\.pid) == [119])
    }
  }

  @Test func aFolderThatDoesNotExistHasNoUsers() throws {
    try withBench { b in
      try b.process(120, cwd: "/")

      #expect(try users(b, folder: "\(b.base)/gone").isEmpty)
    }
  }

  @Test func aTableWithNoProcessThatUsesTheFolderAnswersNone() throws {
    try withBench { b in
      let found = try users(b)

      #expect(found.isEmpty)
    }
  }

  @Test func theTableIsReadWithoutRunningLsof() throws {
    try withBench { b in
      try b.lsof(printing: "p999\nfcwd\nn\(b.folder)\n")
      try b.process(121, cwd: b.folder)

      #expect(try users(b).map(\.pid) == [121])
      #expect(!b.lsofRan)
    }
  }

  // MARK: Without /proc

  /// lsof's -F output: a `p` line starts each process, an `f` line names each descriptor, with `cwd` for the
  /// working folder and `txt` for the program, and an `n` line holds its path.
  @Test func withNoProcessTableLsofsAnswerGivesTheSameUses() throws {
    try withBench { b in
      try b.lsof(
        printing: """
          p201
          fcwd
          n\(b.folder)/sub
          p202
          fcwd
          n/
          ftxt
          n\(b.folder)/bin/tool
          p203
          fcwd
          n/
          ftxt
          n/bin/sleep
          f3
          n\(b.folder)/file
          p204
          fcwd
          n/
          f4
          n\(b.folder)/sub
          p205
          fcwd
          n\(b.sibling)

          """)

      let found = try answer(try runScript(b.folder, root: "\(b.base)/no-proc", path: "\(b.bin):/usr/bin:/bin"))
        .sorted { $0.pid < $1.pid }

      #expect(b.lsofRan)
      #expect(found.map(\.pid) == [201, 202, 203])
      #expect(found.map(\.use) == [.workingFolder, .program, .openFile])
    }
  }

  /// sbd refuses the removal when the script can't check, so this answer must never read as "no users".
  @Test func withNeitherAProcessTableNorLsofTheScriptExits97() throws {
    try withBench { b in
      let r = try runScript(b.folder, root: "\(b.base)/no-proc", path: b.bin)

      #expect(r.status == cantCheck, "\(r.stdout)\(r.stderr)")
    }
  }
}

// MARK: Parity with this Mac

/// macOS has no /proc, so the script runs this Mac's lsof against real processes. It must name the same processes
/// with the same uses as `Processes.using`.
@Suite struct FolderUsersScriptParityTests {
  private func start(_ args: [String], cwd: String, shell: String = "/bin/sh") throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-c"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
  }

  private func waitForArgs(_ p: Process, prefix: String) throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      try #require(p.isRunning, "\(p.processIdentifier) exited before its arguments started with \(prefix)")
      let r = try runCommand("/bin/ps", ["-o", "args=", "-p", String(p.processIdentifier)])
      if r.stdout.hasPrefix(prefix) { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    Issue.record("\(p.processIdentifier)'s arguments never started with \(prefix)")
    throw CancellationError()
  }

  /// Copies /bin/sleep with an ad hoc signature, because macOS kills a copy that keeps Apple's.
  private func copySleep(to path: String) throws {
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
    let signed = try runCommand("/usr/bin/codesign", ["--force", "-s", "-", path])
    try #require(signed.status == 0, "codesign failed: \(signed.stderr)")
  }

  private func uses(_ users: [FolderUser], of pids: [Int32]) -> [String] {
    users.filter { pids.contains(Int32($0.pid)) }.sorted { $0.pid < $1.pid }.map { "\($0.pid) \($0.use.rawValue)" }
  }

  @Test(.timeLimit(.minutes(1)))
  func theScriptFindsTheProcessesAndUsesThatProcessesUsingFinds() throws {
    try withBench { b in
      try copySleep(to: "\(b.folder)/bin/sleep")
      let inside = try start(["exec /bin/sleep 30"], cwd: "\(b.folder)/sub")
      defer { inside.terminate() }
      let program = try start(["exec \"$0\" 30", "\(b.folder)/bin/sleep"], cwd: "/")
      defer { program.terminate() }
      let open = try start(["exec 3<\"$0\"; exec /bin/sleep 31", "\(b.folder)/file"], cwd: "/")
      defer { open.terminate() }
      let directory = try start(["exec 3<\"$0\"; exec /bin/sleep 32", "\(b.folder)/sub"], cwd: "/")
      defer { directory.terminate() }
      let beside = try start(["exec /bin/sleep 33"], cwd: b.sibling)
      defer { beside.terminate() }
      try waitForArgs(inside, prefix: "/bin/sleep 30")
      try waitForArgs(program, prefix: "\(b.folder)/bin/sleep")
      try waitForArgs(open, prefix: "/bin/sleep 31")
      try waitForArgs(directory, prefix: "/bin/sleep 32")
      try waitForArgs(beside, prefix: "/bin/sleep 33")
      let pids = [inside, program, open, directory, beside].map(\.processIdentifier)

      let script = try answer(try runScript(b.folder, root: "\(b.base)/no-proc", path: "/usr/bin:/bin:/usr/sbin"))
      let mac = Processes.using(b.folder)

      #expect(uses(script, of: pids) == uses(mac, of: pids))
      #expect(uses(script, of: pids).count == 3, "\(uses(script, of: pids))")
    }
  }

  /// The working folder of a background ssh multiplexer is not a use on this Mac, because ssh never reads or
  /// writes it after it starts.
  @Test(.timeLimit(.minutes(1)))
  func theWorkingFolderOfAnSshMultiplexerIsNotAUseAsOnThisMac() throws {
    try withBench { b in
      try copySleep(to: "\(b.bin)/ssh")
      let title = "ssh: /tmp/x/sock [mux]"
      let mux = try start(["exec -a \"\(title)\" \"$0\" 30", "\(b.bin)/ssh"], cwd: b.folder, shell: "/bin/bash")
      defer { mux.terminate() }
      try waitForArgs(mux, prefix: title)

      let script = try answer(try runScript(b.folder, root: "\(b.base)/no-proc", path: "/usr/bin:/bin:/usr/sbin"))

      #expect(uses(script, of: [mux.processIdentifier]) == uses(Processes.using(b.folder), of: [mux.processIdentifier]))
      #expect(uses(script, of: [mux.processIdentifier]).isEmpty)
    }
  }
}
