import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private func write(_ text: String, to path: String) throws {
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private final class CurrentShell: @unchecked Sendable {
  private let lock = NSLock()
  private var value: RemoteShell

  init(_ shell: RemoteShell) { value = shell }

  var shell: RemoteShell {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

@Suite struct SSHMachineTests {
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func runReturnsStatusStdoutAndStderr(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }
    let machine = SSHMachine(shell: { t.shell })

    let r = try machine.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])

    #expect(r.status == 3)
    #expect(r.stdout == "out\n")
    #expect(r.stderr == "err\n")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func runPassesEnvInputAndTimeout(program: String) throws {
    let t = try TestShell.start(program, environment: ["PATH": "/usr/bin:/bin"])
    defer { t.shell.close() }
    let machine = SSHMachine(shell: { t.shell })

    let env = try machine.run("/usr/bin/env", [], env: ["SB_MACHINE_TEST": "bar"], input: nil, timeout: nil)
    let cat = try machine.run("/bin/cat", [], env: nil, input: Data("line one\nline two\n".utf8), timeout: nil)
    let slow = try machine.run("/bin/sleep", ["30"], env: nil, input: nil, timeout: 0.5)

    let lines = env.stdout.split(separator: "\n").map(String.init)
    #expect(lines.contains("SB_MACHINE_TEST=bar"))
    #expect(!lines.contains { $0.hasPrefix("PATH=") })
    #expect(cat.stdout == "line one\nline two\n")
    #expect(slow.status == 143)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func runRefusesAnEmptyExecutableAndANul(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }
    let machine = SSHMachine(shell: { t.shell })

    #expect(throws: (any Error).self) { try machine.run("", ["x"]) }
    #expect(throws: (any Error).self) { try machine.run("/bin/echo", ["a\0b"]) }
    #expect(throws: (any Error).self) {
      try machine.run("/bin/echo", [], env: ["A B": "v"], input: nil, timeout: nil)
    }
    #expect(throws: (any Error).self) { try machine.run("/bin/echo", [], env: nil, input: nil, timeout: 0) }
    #expect(try machine.run("/bin/echo", ["ok"]).stdout == "ok\n", "a refused command leaves the shell open")
    #expect(t.events.closes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readReturnsTheBytesFromOffsetUpToCount(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let path = folder + "/digits.txt"
      try write("0123456789", to: path)
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })
      let cases: [(UInt64, Int?, String)] = [
        (0, nil, "0123456789"), (4, nil, "456789"), (2, 3, "234"), (0, 0, ""), (8, 100, "89"), (10, nil, ""),
        (10, 5, ""), (500, nil, ""), (500, 5, ""), (9, 1, "9"), (0, 10, "0123456789"),
      ]

      #expect(machine.read(path, from: 0, count: -1) == nil)
      #expect(machine.read(path, from: 0, count: Int.min) == nil)
      for (offset, count, expected) in cases {
        let data = machine.read(path, from: offset, count: count)

        #expect(data == Data(expected.utf8), "offset \(offset), count \(String(describing: count))")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readClampsAnOffsetAboveInt64Max(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let path = folder + "/digits.txt"
      try write("0123456789", to: path)
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      #expect(machine.read(path, from: UInt64.max, count: nil) == Data())
      #expect(machine.read(path, from: UInt64(Int64.max), count: 4) == Data())
      #expect(machine.text(path) == "0123456789", "the shell still answers")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readReturnsBinaryBytesUnchanged(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let path = folder + "/binary"
      let bytes = Data((0...255).map { UInt8($0) })
      try bytes.write(to: URL(fileURLWithPath: path))
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      #expect(machine.read(path, from: 0, count: nil) == bytes)
      #expect(machine.read(path, from: 250, count: 3) == Data([250, 251, 252]))
      #expect(machine.size(path) == 256)
    }
  }

  /// `read` and `size` must refuse a FIFO before they open it. Opening one blocks the host's shell.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readAndSizeRefuseAFIFOWithoutBlocking(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let fifo = folder + "/fifo"
      #expect(mkfifo(fifo, 0o600) == 0)
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })
      let started = Date()

      #expect(machine.read(fifo, from: 0, count: nil) == nil)
      #expect(machine.read(fifo, from: 0, count: 4) == nil)
      #expect(machine.size(fifo) == nil)

      #expect(Date().timeIntervalSince(started) < 10)
      #expect(machine.exists(fifo))
      #expect(t.events.closes.isEmpty)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func readAndSizeReturnNilForAFolder(program: String) throws {
    try withRemoteShellTempFolder { folder in
      try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: folder)
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      #expect(machine.read(folder, from: 0, count: nil) == nil)
      #expect(machine.read(folder + "/link", from: 0, count: 0) == nil)
      #expect(machine.size(folder) == nil)
      #expect(machine.size(folder + "/link") == nil)
    }
  }

  /// The shell's working folder is the temporary folder, so each path is a bare name that starts with `-`.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aRelativePathWithALeadingDashIsAPathAndNotAnOption(program: String) throws {
    try withRemoteShellTempFolder { folder in
      for name in ["-dash", "-n", "--", "-e", "-rf"] { try write("0123456789", to: folder + "/" + name) }
      try FileManager.default.createDirectory(atPath: folder + "/-folder", withIntermediateDirectories: false)
      try write("x", to: folder + "/-folder/-child")
      let t = try TestShell.start("/bin/sh", ["-c", "cd \"$1\" && exec \"$0\"", program, folder])
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      for name in ["-dash", "-n", "--", "-e", "-rf"] {
        #expect(machine.read(name, from: 2, count: 3) == Data("234".utf8), "\(name)")
        #expect(machine.size(name) == 10, "\(name)")
        #expect(machine.exists(name), "\(name)")
        #expect(!machine.isFolder(name), "\(name)")
        #expect(machine.modified(name) != nil, "\(name)")
      }
      #expect(machine.isFolder("-folder"))
      #expect(machine.list("-folder") == ["-child"])
      try machine.createFolder("-p")
      try machine.createFolder("-new/-sub")
      #expect(isDirectory(folder + "/-p"))
      #expect(isDirectory(folder + "/-new/-sub"))
      #expect(FileManager.default.fileExists(atPath: folder + "/-rf"), "no name ran as an option")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aPathIsNeverReadAsShellText(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let marker = folder + "/injected"
      let hostile = [
        "$(touch \(marker))", "`touch \(marker)`", "'; touch \(marker); '", "\"; touch \(marker); \"",
        "a\ntouch \(marker)\n", "; touch \(marker)", "| touch \(marker)", "$HOME",
        "'\u{301}; touch \(marker); '\u{301}",
      ]
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      for name in hostile {
        let path = folder + "/" + name
        _ = machine.read(path, from: 0, count: nil)
        _ = machine.size(path)
        _ = machine.exists(path)
        _ = machine.isFolder(path)
        _ = machine.modified(path)
        _ = machine.list(path)
      }

      #expect(!FileManager.default.fileExists(atPath: marker))
      #expect(try machine.run("/bin/echo", ["ok"]).stdout == "ok\n")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func createFolderThrowsTheHostsStderrText(program: String) throws {
    try withRemoteShellTempFolder { folder in
      try write("x", to: folder + "/file")
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      do {
        try machine.createFolder(folder + "/file/sub")
        Issue.record("createFolder under a file did not throw")
      } catch {
        #expect("\(error)".contains("mkdir"))
        #expect("\(error)".contains("Not a directory"))
      }
    }
  }

  // A link that is down.

  @Test(.timeLimit(.minutes(1))) func aHostThatIsNotConnectedThrowsOrReturnsNothing() {
    let machine = SSHMachine(shell: { throw APIError("devbox is not connected") })

    #expect(throws: (any Error).self) { try machine.run("/bin/echo", ["hi"]) }
    #expect(throws: (any Error).self) { try machine.createFolder("/tmp/sb-never-created-\(UUID().uuidString)") }
    #expect(machine.read("/etc/hosts", from: 0, count: nil) == nil)
    #expect(machine.text("/etc/hosts") == nil)
    #expect(machine.size("/etc/hosts") == nil)
    #expect(!machine.exists("/etc/hosts"))
    #expect(!machine.isFolder("/etc"))
    #expect(machine.modified("/etc/hosts") == nil)
    #expect(machine.list("/etc") == [])
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aClosedShellThrowsOrReturnsNothingAndNeverReadsThisMac(program: String) throws {
    let t = try TestShell.start(program)
    let machine = SSHMachine(shell: { t.shell })
    #expect(machine.exists("/etc/hosts"))

    t.shell.close()

    #expect(throws: (any Error).self) { try machine.run("/bin/echo", ["hi"]) }
    #expect(throws: (any Error).self) { try machine.createFolder("/tmp/sb-never-created-\(UUID().uuidString)") }
    #expect(machine.read("/etc/hosts", from: 0, count: nil) == nil)
    #expect(machine.size("/etc/hosts") == nil)
    #expect(!machine.exists("/etc/hosts"))
    #expect(!machine.isFolder("/etc"))
    #expect(machine.modified("/etc/hosts") == nil)
    #expect(machine.list("/etc") == [])
  }

  @Test(.timeLimit(.minutes(1))) func aSignalToAHostThatIsNotConnectedSendsNothing() throws {
    try withSleepingChild { child in
      let machine = SSHMachine(shell: { throw APIError("devbox is not connected") })

      machine.signal(Int(child.processIdentifier), SIGTERM)
      Thread.sleep(forTimeInterval: 0.2)

      #expect(child.isRunning)
    }
  }

  @Test(.timeLimit(.minutes(1))) func theMachineAsksForTheShellOnEveryCall() throws {
    let first = try TestShell.start("/bin/sh")
    let second = try TestShell.start("/bin/sh")
    defer { second.shell.close() }
    let current = CurrentShell(first.shell)
    let machine = SSHMachine(shell: { current.shell })
    #expect(try machine.run("/bin/echo", ["one"]).stdout == "one\n")

    first.shell.close()
    current.shell = second.shell

    #expect(try machine.run("/bin/echo", ["two"]).stdout == "two\n")
  }
}

@Suite struct SSHMachineSignalTests {
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms, [SIGTERM, SIGKILL, SIGUSR1, SIGHUP, SIGINT])
  func signalEndsASleepingChildWithThatSignal(program: String, signal: Int32) throws {
    try withSleepingChild { child in
      let t = try TestShell.start(program)
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      machine.signal(Int(child.processIdentifier), signal)
      child.waitUntilExit()

      #expect(child.terminationReason == .uncaughtSignal)
      #expect(child.terminationStatus == signal)
    }
  }

  /// A fake host that writes each request to the file in `$1` and answers status 0 without running
  /// anything. A test of a guard reads the file, so a guard that fails sends no real signal. `kill`
  /// reads pid 0 and -1 as this process group and every process.
  private func withRecordingHost(_ body: (SSHMachine, () -> String) throws -> Void) throws {
    try withRemoteShellTempFolder { folder in
      let log = folder + "/requests"
      let then = """
        while IFS= read -r l; do
          printf '%s\\n' "$l" >>"$1"
          case $l in *sb_run*) n=${l#*sb_run }; n=${n%% *}; printf 'SB1 %s 0 0 0\\n' "$n";; esac
        done
        """
      let t = try FakeShell.open(then: then, arguments: [log])
      defer { t.shell.close() }
      try #require(t.events.readies == 1)
      try body(SSHMachine(shell: { t.shell })) {
        Thread.sleep(forTimeInterval: 0.2)
        return (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
      }
    }
  }

  @Test(.timeLimit(.minutes(1))) func theRecordingHostSeesAValidSignal() throws {
    try withRecordingHost { machine, requests in
      machine.signal(4242, SIGTERM)

      let line = try #require(requests().components(separatedBy: "\n").first { $0.contains("sb_run") })
      #expect(line.contains(#"'kill -s "$1" "$2"'"#))
      #expect(line.hasSuffix("'TERM' '4242'"))
    }
  }

  /// SIGUSR2 is 31 on macOS. The plan's name table holds it, so it is sent as `USR2`.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      (SIGHUP, "HUP"), (SIGINT, "INT"), (SIGQUIT, "QUIT"), (SIGKILL, "KILL"), (SIGTERM, "TERM"), (SIGSTOP, "STOP"),
      (SIGCONT, "CONT"), (SIGUSR1, "USR1"), (31, "USR2"),
    ])
  func aSignalIsSentByNameAndNeverByNumber(signal: Int32, name: String) throws {
    try withRecordingHost { machine, requests in
      machine.signal(4242, signal)

      let line = try #require(requests().components(separatedBy: "\n").first { $0.contains("sb_run") })
      #expect(line.hasSuffix("'\(name)' '4242'"))
      #expect(!line.contains("'\(signal)'"))
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [0, -1, -4242, Int(Int32.min), Int(Int32.max) + 1, Int(UInt32.max) + 1 + 4242, Int.max, Int.min])
  func aPidThatIsNotOneProcessSendsNothing(pid: Int) throws {
    try withRecordingHost { machine, requests in
      machine.signal(pid, SIGTERM)

      #expect(!requests().contains("sb_run"))
    }
  }

  /// 28 is SIGWINCH on macOS, a real signal that the table does not name.
  @Test(.timeLimit(.minutes(1)), arguments: [Int32(0), -1, 28, 32, 64, 100, Int32.max, Int32.min])
  func aSignalWithNoNameInTheTableSendsNothing(signal: Int32) throws {
    try withRecordingHost { machine, requests in
      machine.signal(4242, signal)

      #expect(!requests().contains("sb_run"))
    }
  }

  @Test(.timeLimit(.minutes(1))) func aSignalWithNoNameLeavesASleepingChildRunning() throws {
    try withSleepingChild { child in
      let t = try TestShell.start("/bin/sh")
      defer { t.shell.close() }
      let machine = SSHMachine(shell: { t.shell })

      machine.signal(Int(child.processIdentifier), 28)
      machine.signal(Int(child.processIdentifier), 0)
      Thread.sleep(forTimeInterval: 0.3)

      #expect(child.isRunning)
    }
  }
}
