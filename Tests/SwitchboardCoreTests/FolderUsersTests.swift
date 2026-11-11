import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct FolderUsersTests {
  /// A folder in the temporary folder, whose path goes through the /var symlink, and a sibling whose
  /// name starts with the folder's name.
  private func folders() throws -> (folder: String, sibling: String) {
    let base = "\(NSTemporaryDirectory())sb-folder-users-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: "\(base)/w/sub", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(base)/wx", withIntermediateDirectories: true)
    try "x".write(toFile: "\(base)/w/file", atomically: true, encoding: .utf8)
    try "x".write(toFile: "\(base)/wx/file", atomically: true, encoding: .utf8)
    return ("\(base)/w", "\(base)/wx")
  }

  private func start(_ args: [String], cwd: String, shell: String = "/bin/sh") throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-c"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    try p.run()
    return p
  }

  /// Waits for the process to reach the `sleep` that `exec` starts, which keeps the shell's fds. It checks the
  /// executable name, because the shell's arguments name sleep before the shell execs it.
  private func waitForSleep(_ p: Process) throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let r = try runCommand("/bin/ps", ["-o", "comm=", "-p", String(p.processIdentifier)])
      if r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("sleep") { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    Issue.record("\(p.processIdentifier) never exec'd sleep")
  }

  /// Copies /bin/sleep to `path`. macOS kills a copy of a system program that keeps Apple's signature, so the copy
  /// gets an ad hoc signature.
  private func copySleep(to path: String) throws {
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
    let signed = try runCommand("/usr/bin/codesign", ["--force", "-s", "-", path])
    try #require(signed.status == 0, "codesign failed: \(signed.stderr)")
  }

  private static let muxTitle = "ssh: /tmp/x/sock [mux]"

  /// A copy of /bin/sleep named `ssh`, outside `folder`, so that its program path doesn't match.
  private func fakeSsh(besides folder: String) throws -> String {
    let bin = "\((folder as NSString).deletingLastPathComponent)/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try copySleep(to: "\(bin)/ssh")
    return "\(bin)/ssh"
  }

  /// Starts `program` under bash with argv[0] set to `title`. Bash first opens each path in `holding`, from
  /// fd 3 up.
  private func startMux(
    _ program: String, cwd: String, holding paths: [String] = [], title: String = Self.muxTitle
  ) throws -> Process {
    let opens = paths.indices.map { "exec \($0 + 3)<\"$\($0 + 1)\"; " }.joined()
    return try start(
      ["\(opens)exec -a \"\(title)\" \"$0\" 30", program] + paths, cwd: cwd, shell: "/bin/bash")
  }

  private func user(_ p: Process, in folder: String) -> FolderUser? {
    Processes.using(folder).first { $0.pid == Int(p.processIdentifier) }
  }

  @Test func findsAProcessWhoseWorkingFolderIsInside() throws {
    let (folder, sibling) = try folders()
    let inside = try start(["exec /bin/sleep 30"], cwd: folder)
    defer { inside.terminate() }
    let beside = try start(["exec /bin/sleep 30"], cwd: sibling)
    defer { beside.terminate() }
    try waitForSleep(inside)
    try waitForSleep(beside)

    let users = Processes.using(folder)

    let found = try #require(users.first { $0.pid == Int(inside.processIdentifier) })
    #expect(found.use == .workingFolder)
    #expect(!users.map(\.pid).contains(Int(beside.processIdentifier)))
  }

  @Test func findsAProcessWhoseWorkingFolderIsASubfolder() throws {
    let (folder, _) = try folders()
    let p = try start(["exec /bin/sleep 30"], cwd: "\(folder)/sub")
    defer { p.terminate() }
    try waitForSleep(p)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .workingFolder)
    #expect(found.path.hasSuffix("/w/sub"))
  }

  @Test func findsAProcessWithAnOpenFileInside() throws {
    let (folder, sibling) = try folders()
    let open = try start(["exec 3<\"$0\"; exec /bin/sleep 30", "\(folder)/file"], cwd: "/")
    defer { open.terminate() }
    let beside = try start(["exec 3<\"$0\"; exec /bin/sleep 30", "\(sibling)/file"], cwd: "/")
    defer { beside.terminate() }
    try waitForSleep(open)
    try waitForSleep(beside)

    let users = Processes.using(folder)

    let found = try #require(users.first { $0.pid == Int(open.processIdentifier) })
    #expect(found.use == .openFile)
    #expect(found.path.hasSuffix("/w/file"))
    #expect(!users.map(\.pid).contains(Int(beside.processIdentifier)))
  }

  /// A fifo is not a directory, so holding it open counts as using the folder.
  @Test func findsAProcessWithAFifoOpenInside() throws {
    let (folder, _) = try folders()
    let fifo = "\(folder)/fifo"
    #expect(mkfifo(fifo, 0o600) == 0)
    // Opening a fifo read-write doesn't wait for a writer.
    let p = try start(["exec 3<>\"$0\"; exec /bin/sleep 30", fifo], cwd: "/")
    defer { p.terminate() }
    try waitForSleep(p)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .openFile)
    #expect(found.path.hasSuffix("/w/fifo"))
  }

  /// The copy runs in /, so only its program path finds it.
  @Test func findsAProcessWhoseProgramIsInside() throws {
    let (folder, _) = try folders()
    try copySleep(to: "\(folder)/sleep")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "\(folder)/sleep")
    p.arguments = ["30"]
    p.currentDirectoryURL = URL(fileURLWithPath: "/")
    try p.run()
    defer { p.terminate() }
    try waitForArgs(p, prefix: "\(folder)/sleep")

    let found = try #require(user(p, in: folder))
    #expect(found.use == .program)
    #expect(found.path.hasSuffix("/w/sleep"))
  }

  /// A file watcher such as Supacode holds folders open while it runs elsewhere.
  @Test(arguments: ["", "/sub"])
  func ignoresAProcessThatOnlyHoldsADirectoryOpen(_ below: String) throws {
    let (folder, _) = try folders()
    let p = try start(["exec 3<\"$0\"; exec /bin/sleep 30", folder + below], cwd: "/")
    defer { p.terminate() }
    try waitForSleep(p)

    #expect(user(p, in: folder) == nil)
  }

  /// The directory is on the lower fd, so a match on the first open path would report the directory.
  @Test(arguments: ["", "/sub"])
  func findsAProcessThatHoldsADirectoryAndAFileOpen(_ below: String) throws {
    let (folder, _) = try folders()
    let p = try start(
      ["exec 3<\"$0\" 4<\"$1\"; exec /bin/sleep 30", folder + below, "\(folder)/file"], cwd: "/")
    defer { p.terminate() }
    try waitForSleep(p)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .openFile)
    #expect(found.path.hasSuffix("/w/file"))
  }

  /// The rule for directories applies only to a process that runs elsewhere.
  @Test func findsAProcessInsideThatHoldsADirectoryOpenByItsWorkingFolder() throws {
    let (folder, _) = try folders()
    let p = try start(["exec 3<\"$0\"; exec /bin/sleep 30", "\(folder)/sub"], cwd: folder)
    defer { p.terminate() }
    try waitForSleep(p)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .workingFolder)
  }

  /// An ssh ControlMaster keeps the working folder of the session that started it.
  @Test(arguments: ["", "/sub"])
  func ignoresTheWorkingFolderOfAnSshMultiplexer(_ below: String) throws {
    let (folder, _) = try folders()
    let p = try startMux(try fakeSsh(besides: folder), cwd: folder + below)
    defer { p.terminate() }
    try waitForArgs(p, prefix: Self.muxTitle)

    #expect(user(p, in: folder) == nil)
  }

  @Test func findsAnSshMultiplexerWithAFileOpenInside() throws {
    let (folder, _) = try folders()
    let p = try startMux(try fakeSsh(besides: folder), cwd: folder, holding: ["\(folder)/sub", "\(folder)/file"])
    defer { p.terminate() }
    try waitForArgs(p, prefix: Self.muxTitle)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .openFile)
    #expect(found.path.hasSuffix("/w/file"))
  }

  /// The multiplexer rule leaves out only the working folder.
  @Test func findsAnSshMultiplexerWhoseProgramIsInside() throws {
    let (folder, _) = try folders()
    try copySleep(to: "\(folder)/ssh")
    let p = try startMux("\(folder)/ssh", cwd: "/")
    defer { p.terminate() }
    try waitForArgs(p, prefix: Self.muxTitle)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .program)
    #expect(found.path.hasSuffix("/w/ssh"))
  }

  /// An interactive ssh session started in the folder is not a multiplexer.
  @Test func findsAnSshProcessWithoutTheMuxTitleByItsWorkingFolder() throws {
    let (folder, _) = try folders()
    let ssh = try fakeSsh(besides: folder)
    let p = try start(["exec \"$0\" 30", ssh], cwd: folder)
    defer { p.terminate() }
    try waitForArgs(p, prefix: ssh)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .workingFolder)
  }

  /// A title with only the `ssh: ` prefix or only the ` [mux]` suffix is not the multiplexer's title.
  @Test(arguments: ["ssh: host", "x/sock [mux]"])
  func findsAnSshProcessWithHalfTheMuxTitleByItsWorkingFolder(_ title: String) throws {
    let (folder, _) = try folders()
    let p = try startMux(try fakeSsh(besides: folder), cwd: folder, title: title)
    defer { p.terminate() }
    try waitForArgs(p, prefix: title)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .workingFolder)
  }

  /// Only a program named ssh is a multiplexer, whatever its argv[0] says.
  @Test func findsAProcessWithTheMuxTitleThatIsNotSshByItsWorkingFolder() throws {
    let (folder, _) = try folders()
    let p = try startMux("/bin/sleep", cwd: folder)
    defer { p.terminate() }
    try waitForArgs(p, prefix: Self.muxTitle)

    let found = try #require(user(p, in: folder))

    #expect(found.use == .workingFolder)
  }

  /// Waits until the process's arguments, as `ps` shows them, start with `prefix`. A process that renames itself
  /// shows its new name there. The arguments of bash before its exec contain the prefix too, but not at the start.
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

  @Test func aFolderThatIsGoneHasNoUsers() {
    #expect(Processes.using("\(NSTemporaryDirectory())sb-folder-users-gone-\(UUID().uuidString)").isEmpty)
  }

  @Test func descendantsIncludeTheRootsAndEveryLevelBelow() {
    let rows = [
      ProcessRow(pid: 2, ppid: 1, pgid: 2, command: ""), ProcessRow(pid: 3, ppid: 2, pgid: 3, command: ""),
      ProcessRow(pid: 4, ppid: 9, pgid: 4, command: ""),
    ]
    #expect(Processes.descendants(of: [1], in: Dictionary(grouping: rows, by: \.ppid)) == [1, 2, 3])
  }
}
