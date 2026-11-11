import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// The shells that every framing test runs on.
let remoteShellPrograms = ["/bin/sh", "/bin/bash", "/bin/dash"]

/// Checks `done` every 10 ms. It returns false when `seconds` pass before `done` is true.
func waitUntil(seconds: Double, _ done: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !done() {
    if Date() > deadline { return false }
    Thread.sleep(forTimeInterval: 0.01)
  }
  return true
}

/// A new folder under /tmp, because a Unix socket path can't exceed 103 bytes. The caller
/// removes it.
func makeShortTempFolder() throws -> String {
  var template = Array("/tmp/sbt.XXXXXX".utf8CString)
  guard let folder = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
  return String(cString: folder)
}

func withSleepingChild(_ body: (Process) throws -> Void) throws {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/bin/sleep")
  child.arguments = ["30"]
  try child.run()
  defer {
    if child.isRunning {
      kill(child.processIdentifier, SIGKILL)
      child.waitUntilExit()
    }
  }
  try body(child)
}

/// What a `RemoteShell` reported through `onReady` and `onClose`.
final class ShellEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var readyCount = 0
  private var closeReasons: [String] = []

  func ready() { lock.withLock { readyCount += 1 } }
  func closed(_ reason: String) { lock.withLock { closeReasons.append(reason) } }

  var readies: Int { lock.withLock { readyCount } }
  var closes: [String] { lock.withLock { closeReasons } }

  func waitForClose(seconds: Double = 5) -> Bool { waitUntil(seconds: seconds) { !self.closes.isEmpty } }
}

struct TestShell {
  let shell: RemoteShell
  let events: ShellEvents

  /// Starts the program and returns once it answered the handshake or closed.
  static func open(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil) throws
    -> TestShell
  {
    let events = ShellEvents()
    let shell = try RemoteShell(
      executable: executable, arguments: arguments, environment: environment,
      onReady: { _ in events.ready() }, onClose: { events.closed($0) })
    _ = waitUntil(seconds: 30) { events.readies > 0 || !events.closes.isEmpty }
    return TestShell(shell: shell, events: events)
  }

  /// Starts the program and requires the handshake.
  static func start(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil) throws
    -> TestShell
  {
    let t = try open(executable, arguments, environment: environment)
    try #require(t.events.readies == 1, "the handshake did not finish: \(t.events.closes)")
    return t
  }

  func run(
    _ argv: [String], env: [String: String]? = nil, input: Data? = nil, timeout: Double? = nil,
    deadline: Double? = 60
  ) throws -> RemoteResult {
    try shell.run(argv, env: env, input: input, timeout: timeout, deadline: deadline)
  }

  func text(_ argv: [String]) throws -> String {
    String(decoding: try run(argv).stdout, as: UTF8.self)
  }
}

/// A `/bin/sh -c` program that answers the handshake as a host would and then runs `then` in
/// place of the real shell functions. It reads the token from the boot script's last line.
enum FakeShell {
  static let goodReady = "bsd 736 1792710643.000000000"

  /// Reads lines until the request's `sb_run` line.
  static let awaitRequest = "while IFS= read -r l; do case $l in *sb_run*) break;; esac; done\n"

  static func script(ready: String = goodReady, then: String) -> String {
    """
    tok=
    while IFS= read -r l; do
      case $l in *"SB1 ready"*) tok=$(printf '%s\\n' "$l" | grep -oE '[0-9a-fA-F]{32}' | head -n 1); break;; esac
    done
    printf 'SB1 ready %s %s\\n' "$tok" '\(ready)'
    \(then)
    """
  }

  static func open(ready: String = goodReady, then: String, arguments: [String] = []) throws -> TestShell {
    try TestShell.open("/bin/sh", ["-c", script(ready: ready, then: then), "sb"] + arguments)
  }
}

func withRemoteShellTempFolder(_ body: (String) throws -> Void) throws {
  let folder = try makeShortTempFolder()
  defer {
    _ = try? runCommand("/bin/chmod", ["-R", "u+rwx", folder])
    try? FileManager.default.removeItem(atPath: folder)
  }
  try body(folder)
}

/// Bytes that hold every value and do not repeat with a short period.
func mixedBytes(_ count: Int) -> Data {
  var state: UInt32 = 0x9E37_79B9
  var bytes = [UInt8]()
  bytes.reserveCapacity(count)
  for _ in 0..<count {
    state = state &* 1_664_525 &+ 1_013_904_223
    bytes.append(UInt8(truncatingIfNeeded: state >> 24))
  }
  return Data(bytes)
}

private let everyByte = Data((0...255).map { UInt8($0) })

@Suite struct RemoteShellFramingTests {
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func returnsStatusStdoutAndStderr(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])

    #expect(r.status == 3)
    #expect(r.stdout == Data("out\n".utf8))
    #expect(r.stderr == Data("err\n".utf8))
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func passesHostileArgvWordsByteForByte(program: String) throws {
    let words = [
      "a b", "'", "it's", "\"", "`id`", "`touch /tmp/sb-injected`", "$HOME", "$(id)", ";", "a; exit 9",
      "line\nbreak", "-n", "--", "", "héllo ✓ 日本", "\\", "a\\nb", "*", "~", "_SB_", "\n_SB_\n", "#x", "!", "\t",
      " ", "a=b", "&", "|", ">", "<", "'\\''", "\r",
      // A quote and the combining character after it are one character.
      "'\u{301}; exit 9; '\u{301}", "'\u{FE0F}x", "e\u{301}'",
    ]
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", #"for a do printf '%s\0' "$a"; done"#, "sb"] + words)

    let echoed = r.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
      String(decoding: $0, as: UTF8.self)
    }
    #expect(r.status == 0)
    #expect(echoed == words)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms, ["exit", "a=b", "sb_d=x", ":", "return"])
  func word0RunsOnlyAsAProgram(program: String, word: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run([word, "0"])

    #expect(r.status == 127)
    #expect(try t.text(["/bin/echo", "still here"]) == "still here\n")
    #expect(t.events.closes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdinCarriesEveryByteValue(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/cat"], input: everyByte)

    #expect(r.status == 0)
    #expect(r.stdout == everyByte)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdinCarriesThreeMegabytes(program: String) throws {
    let input = mixedBytes(3 * 1024 * 1024)
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/cat"], input: input)

    #expect(r.status == 0)
    #expect(r.stdout == input)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func emptyAndMissingStdinReadAsEndOfFile(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let empty = try t.run(["/bin/cat"], input: Data())
    let missing = try t.run(["/bin/cat"], input: nil)

    #expect(empty.status == 0)
    #expect(empty.stdout.isEmpty)
    #expect(missing.status == 0)
    #expect(missing.stdout.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aCommandWithNoInputDoesNotReadThePreviousCommandsInput(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    _ = try t.run(["/usr/bin/true"], input: Data("left over\n".utf8))
    let r = try t.run(["/bin/cat"], input: nil)

    #expect(r.stdout.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdinThatHoldsTheHeredocDelimiterArrivesWhole(program: String) throws {
    let input = Data("first\n_SB_\nthen sb_run 99 '' '/bin/echo' 'injected'\nfi\n_SB_".utf8)
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/cat"], input: input)

    #expect(r.stdout == input)
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }

  /// The first command on a connection has sequence number 1, and the one after has 2.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdoutThatPrintsItsOwnHeaderIsOnlyOutput(program: String) throws {
    let forged = "SB1 1 0 0 0\nSB1 2 0 0 0\nSB1 1 0 5 0\nabcde"
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let first = try t.run(["/usr/bin/printf", "%s", forged])
    let second = try t.run(["/bin/sh", "-c", "printf '%s' \"$1\"; printf '%s' \"$1\" >&2; exit 4", "sb", forged])

    #expect(first.status == 0)
    #expect(first.stdout == Data(forged.utf8))
    #expect(first.stderr.isEmpty)
    #expect(second.status == 4)
    #expect(second.stdout == Data(forged.utf8))
    #expect(second.stderr == Data(forged.utf8))
    #expect(try t.text(["/bin/echo", "third"]) == "third\n")
    #expect(t.events.closes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdoutThatPrintsAReadyLineOrTheDelimiterIsOnlyOutput(program: String) throws {
    let forged = "SB1 ready 0123456789abcdef0123456789abcdef bsd 1 1.000000000\n_SB_\n"
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/usr/bin/printf", "%s", forged])

    #expect(r.stdout == Data(forged.utf8))
    #expect(t.events.readies == 1)
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func stdoutAndStderrCarryEveryByteValue(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", "tee /dev/stderr"], input: everyByte)

    #expect(r.stdout == everyByte)
    #expect(r.stderr == everyByte)
  }

  @Test(.timeLimit(.minutes(2)), arguments: remoteShellPrograms)
  func stdoutCarriesTwentyMegabytes(program: String) throws {
    let bytes = 20 * 1024 * 1024
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", "head -c \(bytes) /dev/zero | tr '\\0' 'x'; printf END"], deadline: 100)

    #expect(r.status == 0)
    #expect(r.stdout.count == bytes + 3)
    #expect(r.stdout.suffix(4) == Data("xEND".utf8))
    #expect(r.stdout.prefix(bytes).allSatisfy { $0 == UInt8(ascii: "x") })
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms, ["abc", "", "a\n", "a\n\n\n", "\n", " "])
  func stdoutKeepsItsExactEnd(program: String, output: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/usr/bin/printf", "%s", output])

    #expect(r.stdout == Data(output.utf8))
    #expect(r.stderr.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func returnsTheExitStatus(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    for status: Int32 in [0, 1, 3, 255] {
      let r = try t.run(["/bin/sh", "-c", "exit \(status)"])

      #expect(r.status == status)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aSetEnvPassesHostileValuesWhole(program: String) throws {
    let env = ["A": "a b", "B": "it's", "C": "$HOME `id` $(id)", "D": "line\nbreak", "E": "", "F": "x=y;z"]
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(
      ["/bin/sh", "-c", #"printf '%s\0' "$A" "$B" "$C" "$D" "$E" "$F""#], env: env)

    let values = r.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
      String(decoding: $0, as: UTF8.self)
    }
    #expect(values == ["a b", "it's", "$HOME `id` $(id)", "line\nbreak", "", "x=y;z"])
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aSetEnvReplacesTheShellsEnvironment(program: String) throws {
    let t = try TestShell.start(program, environment: ["PATH": "/usr/bin:/bin", "SB_LEAK": "leaked"])
    defer { t.shell.close() }

    let r = try t.run(["/usr/bin/env"], env: ["SB_SHELL_TEST": "bar"])

    let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(r.status == 0)
    #expect(lines.contains("SB_SHELL_TEST=bar"))
    #expect(!lines.contains { $0.hasPrefix("PATH=") })
    #expect(!lines.contains { $0.hasPrefix("SB_LEAK=") })
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func anEmptySetEnvStillClearsTheShellsEnvironment(program: String) throws {
    let t = try TestShell.start(program, environment: ["PATH": "/usr/bin:/bin", "SB_LEAK": "leaked"])
    defer { t.shell.close() }

    let r = try t.run(["/usr/bin/env"], env: [:])

    let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(!lines.contains { $0.hasPrefix("PATH=") })
    #expect(!lines.contains { $0.hasPrefix("SB_LEAK=") })
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aNilEnvKeepsTheShellsPath(program: String) throws {
    let t = try TestShell.start(program, environment: ["PATH": "/usr/bin:/bin:/sb-path-marker"])
    defer { t.shell.close() }

    let r = try t.run(["/usr/bin/env"], env: nil)

    let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines.contains("PATH=/usr/bin:/bin:/sb-path-marker"))
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func anExecutableWithAnEqualsSignRunsAsAProgram(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let executable = folder + "/a=b"
      try Data("#!/bin/sh\necho \"ran $SB_SHELL_TEST\"\n".utf8).write(to: URL(fileURLWithPath: executable))
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
      let t = try TestShell.start(program)
      defer { t.shell.close() }

      let plain = try t.run([executable])
      let withEnv = try t.run([executable], env: ["SB_SHELL_TEST": "under env"])

      #expect(plain.status == 0)
      #expect(plain.stdout == Data("ran \n".utf8))
      #expect(withEnv.status == 0)
      #expect(withEnv.stdout == Data("ran under env\n".utf8))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aTimeoutEndsTheProgramWithStatus143(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }
    let started = Date()

    let r = try t.run(["/bin/sleep", "30"], timeout: 0.5, deadline: 30)

    let elapsed = Date().timeIntervalSince(started)
    #expect(r.status == 143)
    #expect(elapsed >= 0.4)
    #expect(elapsed < 10)
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
    #expect(t.events.closes.isEmpty)
  }

  /// A tmux client exits 0 when a signal ends it. Its answer must not read as a command that succeeded.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aProgramThatExitsZeroWhenItsTimeoutEndsItAnswersWithStatus143(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", "trap 'exit 0' TERM; /bin/sleep 30 & wait"], timeout: 0.3, deadline: 30)
    let next = try t.run(["/bin/sh", "-c", "exit 0"], timeout: 20, deadline: 30)

    #expect(r.status == 143)
    #expect(next.status == 0, "the mark of one command's timeout reached the next command")
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aProgramThatIgnoresSIGTERMEndsWithStatus137(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }
    let started = Date()

    let r = try t.run(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.3, deadline: 30)

    let elapsed = Date().timeIntervalSince(started)
    #expect(r.status == 137)
    #expect(elapsed >= 2)
    #expect(elapsed < 15)
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }

  /// Each shell gets a timeout of its own, so `pgrep` finds only that shell's `sleep`.
  @Test(.timeLimit(.minutes(1)), arguments: zip(remoteShellPrograms, [47.125, 47.25, 47.375]))
  func aProgramThatEndsBeforeItsTimeoutLeavesNoSleepRunning(program: String, timeout: Double) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    for _ in 1...3 { #expect(try t.run(["/bin/echo", "hi"], timeout: timeout).status == 0) }

    Thread.sleep(forTimeInterval: 0.3)
    #expect(try runCommand("/usr/bin/pgrep", ["-f", "sleep \(timeout)"]).stdout == "")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aProgramThatEndsBeforeItsTimeoutKeepsItsOwnStatus(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/bin/sh", "-c", "echo quick; exit 5"], timeout: 20, deadline: 30)

    #expect(r.status == 5)
    #expect(r.stdout == Data("quick\n".utf8))
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func fiftyCommandsInARowReturnTheirOwnOutputsInOrder(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    for i in 1...50 {
      let r = try t.run(["/bin/sh", "-c", "echo out-\(i); echo err-\(i) >&2; exit \(i)"])

      #expect(r.status == Int32(i))
      #expect(r.stdout == Data("out-\(i)\n".utf8))
      #expect(r.stderr == Data("err-\(i)\n".utf8))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func commandsFromSeveralThreadsEachGetTheirOwnOutput(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }
    let lock = NSLock()
    var outputs: [Int: String] = [:]
    let group = DispatchGroup()

    // Each command blocks its thread. Twelve blocked threads on a global queue leave other
    // tests' blocks waiting for a thread.
    for i in 0..<12 {
      group.enter()
      Thread.detachNewThread {
        let text = try? t.text(["/bin/sh", "-c", "sleep 0.0\(i % 3); echo thread-\(i)"])
        lock.withLock { outputs[i] = text ?? "threw" }
        group.leave()
      }
    }

    #expect(group.wait(timeout: .now() + 40) == .success)
    for i in 0..<12 {
      #expect(lock.withLock { outputs[i] } == "thread-\(i)\n")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aMissingProgramReturnsAStatusAndDoesNotCloseTheShell(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let r = try t.run(["/nonexistent/sb-no-such-program"])

    #expect(r.status == 126 || r.status == 127)
    #expect(try t.text(["/bin/echo", "next"]) == "next\n")
  }
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aChildThatOutlivesItsCommandWritesNothingIntoTheNextAnswer(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let first = try t.run(["/bin/sh", "-c", "(sleep 0.5; echo LATE; echo LATE-ERR >&2) & echo now"])
    let second = try t.run(["/bin/sh", "-c", "sleep 1.5; echo two; echo two-err >&2"])

    #expect(first.stdout == Data("now\n".utf8))
    #expect(first.stderr.isEmpty)
    #expect(second.status == 0)
    #expect(second.stdout == Data("two\n".utf8))
    #expect(second.stderr == Data("two-err\n".utf8))
    #expect(t.events.closes.isEmpty)
  }

  /// The timeout signals only the program, so the program's child runs on.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aChildThatOutlivesATimedOutCommandWritesNothingIntoTheNextAnswer(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    let first = try t.run(
      ["/bin/sh", "-c", "(sleep 1.2; echo LATE; echo LATE-ERR >&2) & sleep 30"], timeout: 0.3, deadline: 30)
    let second = try t.run(["/bin/sh", "-c", "sleep 2.5; printf x"])

    #expect(first.status == 143)
    #expect(first.stdout.isEmpty)
    #expect(second.status == 0)
    #expect(second.stdout == Data("x".utf8))
    #expect(second.stderr.isEmpty)
    #expect(t.events.closes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aChildThatOutlivesItsCommandNeverReadsTheNextCommandsInput(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let copy = folder + "/late-input"
      let t = try TestShell.start(program)
      defer { t.shell.close() }

      let first = try t.run(
        ["/bin/sh", "-c", #"exec 3<&0; (sleep 0.5; cat <&3 >"$1") & echo now"#, "sb", copy], input: Data("one".utf8))
      let second = try t.run(["/bin/sh", "-c", "sleep 1.5; cat"], input: Data("the input of two".utf8))

      #expect(first.stdout == Data("now\n".utf8))
      #expect(second.stdout == Data("the input of two".utf8))
      #expect(FileManager.default.contents(atPath: copy) == Data("one".utf8))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func theTemporaryFolderHoldsNoCommandFilesBetweenCommandsAndGoesWhenTheShellCloses(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let t = try TestShell.start(program, environment: ["PATH": "/usr/bin:/bin", "TMPDIR": folder])
      defer { t.shell.close() }
      let pid = Int(t.shell.pid)
      let folders = try FileManager.default.contentsOfDirectory(atPath: folder)
      try #require(folders.count == 1)
      let shellFolder = folder + "/" + folders[0]

      for i in 1...30 {
        let r = try t.run(
          ["/bin/sh", "-c", "(sleep 0.3; echo late) & cat; echo err-\(i) >&2"],
          input: i % 2 == 0 ? nil : Data("in-\(i)".utf8),
          timeout: i % 3 == 0 ? 20 : nil)
        #expect(r.stdout == Data((i % 2 == 0 ? "" : "in-\(i)").utf8))
        #expect(r.stderr == Data("err-\(i)\n".utf8))
      }

      // The shell removes a command's files after it prints the answer.
      #expect(
        waitUntil(seconds: 5) { (try? FileManager.default.contentsOfDirectory(atPath: shellFolder)) == ["f"] })
      t.shell.close()
      #expect(Processes.waitForExit([pid], seconds: 5).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == [])
    }
  }

  /// The second sleep runs past the SIGKILL that the first command's timeout would send.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func timeoutsOnCommandsInARowEachEndOnlyTheirOwnProgram(program: String) throws {
    let t = try TestShell.start(program)
    defer { t.shell.close() }

    #expect(try t.run(["/bin/echo", "hi"], timeout: 20).status == 0)
    #expect(try t.run(["/bin/sleep", "30"], timeout: 0.3, deadline: 30).status == 143)
    let slow = try t.run(["/bin/sh", "-c", "sleep 2.5; echo ok"], timeout: 20, deadline: 30)
    let started = Date()
    #expect(try t.run(["/bin/sleep", "30"], timeout: 0.3, deadline: 30).status == 143)

    #expect(slow.status == 0)
    #expect(slow.stdout == Data("ok\n".utf8))
    #expect(Date().timeIntervalSince(started) < 10)
  }
}

@Suite struct RemoteShellFailureTests {
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aKilledShellFailsTheCommandInFlightAndClosesOnce(program: String) throws {
    let t = try TestShell.start(program)
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var threw = false
    let started = DispatchSemaphore(value: 0)
    // A global queue can take seconds to give this block a thread while other tests block theirs.
    Thread.detachNewThread {
      started.signal()
      do { _ = try t.run(["/bin/sleep", "30"], deadline: nil) } catch { lock.withLock { threw = true } }
      finished.signal()
    }
    started.wait()
    Thread.sleep(forTimeInterval: 0.5)

    kill(t.shell.pid, SIGKILL)

    #expect(finished.wait(timeout: .now() + 2) == .success, "run did not throw within 2 s")
    #expect(lock.withLock { threw })
    #expect(t.events.waitForClose())
    Thread.sleep(forTimeInterval: 0.3)
    #expect(t.events.closes.count == 1)
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "after"]) }
    t.shell.close()
    #expect(t.events.closes.count == 1, "close after the shell ended reports nothing more")
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aCommandAfterCloseThrowsAndStartsNoProcess(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let marker = folder + "/ran"
      let t = try TestShell.start(program)
      #expect(try t.text(["/bin/echo", "before"]) == "before\n")

      t.shell.close()

      #expect(throws: (any Error).self) { try t.run(["/usr/bin/touch", marker]) }
      Thread.sleep(forTimeInterval: 0.3)
      #expect(!FileManager.default.fileExists(atPath: marker))
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func closeEndsTheProcessAndReportsOnce(program: String) throws {
    let t = try TestShell.start(program)
    let pid = Int(t.shell.pid)
    #expect(Processes.exists(pid))

    t.shell.close()
    t.shell.close()

    #expect(Processes.waitForExit([pid], seconds: 5).isEmpty)
    #expect(t.events.waitForClose())
    Thread.sleep(forTimeInterval: 0.3)
    #expect(t.events.closes.count == 1)
  }

  /// Each fake answers the handshake, reads one request, and then breaks the framing. The ones
  /// that end with `cat` stay alive, so the throw comes from the bytes and not from end of file.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      ("stray bytes before the header", "printf 'stray\\nSB1 1 0 0 0\\n'; cat >/dev/null"),
      ("stray bytes on the header's line", "printf 'straySB1 1 0 0 0\\n'; cat >/dev/null"),
      ("an empty line before the header", "printf '\\nSB1 1 0 0 0\\n'; cat >/dev/null"),
      ("a wrong sequence number", "printf 'SB1 2 0 0 0\\n'; cat >/dev/null"),
      ("sequence number 0", "printf 'SB1 0 0 0 0\\n'; cat >/dev/null"),
      ("a count that is not a number", "printf 'SB1 1 0 abc 0\\n'; cat >/dev/null"),
      ("a negative count", "printf 'SB1 1 0 -1 0\\n'; cat >/dev/null"),
      ("a status that is not a number", "printf 'SB1 1 ok 0 0\\n'; cat >/dev/null"),
      ("a missing field", "printf 'SB1 1 0 0\\n'; cat >/dev/null"),
      ("a line over 256 bytes", "printf 'SB1 1 0 0 %0300d\\n' 0; cat >/dev/null"),
      ("300 bytes with no newline", "printf '%0300d' 0; cat >/dev/null"),
      ("a ready line in place of the header", "printf 'SB1 ready %s bsd 1 1.0\\n' \"$tok\"; cat >/dev/null"),
      ("half a header and then exit", "printf 'SB1 1 0'"),
      ("half of stdout and then exit", "printf 'SB1 1 0 10 0\\nhalf'"),
      ("all of stdout, half of stderr, and then exit", "printf 'SB1 1 0 4 10\\nfullhalf'"),
      ("nothing and then exit", ":"),
    ])
  func anAnswerThatBreaksTheFramingThrowsAndClosesTheShell(shape: String, misbehavior: String) throws {
    let t = try FakeShell.open(then: FakeShell.awaitRequest + misbehavior)
    defer { t.shell.close() }
    try #require(t.events.readies == 1)
    let pid = Int(t.shell.pid)

    #expect(throws: (any Error).self, "\(shape)") { try t.run(["/bin/echo", "hi"], deadline: 20) }

    #expect(t.events.waitForClose(), "\(shape): onClose did not run")
    #expect(throws: (any Error).self, "\(shape): the closed shell ran a command") { try t.run(["/bin/echo", "again"]) }
    #expect(Processes.waitForExit([pid], seconds: 5).isEmpty, "\(shape): the process still runs")
    Thread.sleep(forTimeInterval: 0.2)
    #expect(t.events.closes.count == 1, "\(shape)")
  }

  @Test(.timeLimit(.minutes(1))) func aReadyLineAndAHeaderSplitAcrossReadsStillParse() throws {
    let script = """
      tok=
      while IFS= read -r l; do
        case $l in *"SB1 ready"*) tok=$(printf '%s\\n' "$l" | grep -oE '[0-9a-fA-F]{32}' | head -n 1); break;; esac
      done
      half=$(printf '%s' "$tok" | cut -c1-16); rest=$(printf '%s' "$tok" | cut -c17-32)
      printf 'noise SB1 rea'; sleep 0.2; printf 'dy %s' "$half"; sleep 0.2; printf '%s bsd 7' "$rest"; sleep 0.2
      printf '36 1792710643.000000000\\n'
      \(FakeShell.awaitRequest)printf 'SB1 1 0'; sleep 0.2; printf ' 2 0\\no'; sleep 0.2; printf 'k'; cat >/dev/null
      """
    let t = try TestShell.start("/bin/sh", ["-c", script])
    defer { t.shell.close() }

    let r = try t.run(["/bin/echo", "hi"], deadline: 20)

    #expect(r.stdout == Data("ok".utf8))
    #expect(t.events.closes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func closeFailsTheCommandInFlightAndEndsAShellThatWaits(program: String) throws {
    let t = try TestShell.start(program)
    let pid = Int(t.shell.pid)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var threw = false
    Thread.detachNewThread {
      started.signal()
      do { _ = try t.run(["/bin/sleep", "30"], deadline: nil) } catch { lock.withLock { threw = true } }
      finished.signal()
    }
    started.wait()
    Thread.sleep(forTimeInterval: 0.5)

    t.shell.close()

    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(lock.withLock { threw })
    #expect(Processes.waitForExit([pid], seconds: 5).isEmpty)
    #expect(t.events.closes == ["closed"])
  }

  /// The fakes never read the request, so the write can't finish.
  @Test(.timeLimit(.minutes(1)), arguments: ["sleep 30", "exec <&-; sleep 30"])
  func aShellThatDoesNotTakeTheRequestThrowsAtTheLocalDeadlineAndCloses(then: String) throws {
    let t = try FakeShell.open(then: then)
    defer { t.shell.close() }
    try #require(t.events.readies == 1)
    let started = Date()

    #expect(throws: (any Error).self) {
      try t.run(["/bin/cat"], input: mixedBytes(2 * 1024 * 1024), deadline: 0.6)
    }

    #expect(Date().timeIntervalSince(started) < 10)
    #expect(t.events.waitForClose())
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "again"]) }
  }

  @Test(.timeLimit(.minutes(1))) func theCloseReasonIsTheLastTwentyLinesOfStderr() throws {
    let t = try TestShell.open(
      "/bin/sh", ["-c", "i=1; while [ $i -le 30 ]; do echo \"line $i\" >&2; i=$((i+1)); done; exit 255"])
    defer { t.shell.close() }

    #expect(t.events.waitForClose())
    #expect(t.events.closes.first == (11...30).map { "line \($0)" }.joined(separator: "\n"))
  }

  /// The second answer carries the first command's sequence number, as a late answer would.
  @Test(.timeLimit(.minutes(1))) func anAnswerWithThePreviousSequenceNumberIsNotTheNextCommandsAnswer() throws {
    let then =
      FakeShell.awaitRequest + "printf 'SB1 1 0 2 0\\nok'\n" + FakeShell.awaitRequest
      + "printf 'SB1 1 0 5 0\\nstale'; cat >/dev/null"
    let t = try FakeShell.open(then: then)
    defer { t.shell.close() }
    try #require(t.events.readies == 1)

    let first = try t.run(["/bin/echo", "one"], deadline: 20)

    #expect(first.stdout == Data("ok".utf8))
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "two"], deadline: 20) }
    #expect(t.events.waitForClose())
  }

  @Test(.timeLimit(.minutes(1))) func statusXThrowsThatTheHostCouldNotDecodeTheInput() throws {
    let t = try FakeShell.open(then: FakeShell.awaitRequest + "printf 'SB1 1 x 0 0\\n'; cat >/dev/null")
    defer { t.shell.close() }
    try #require(t.events.readies == 1)

    do {
      _ = try t.run(["/bin/cat"], input: Data("in".utf8), deadline: 20)
      Issue.record("status x did not throw")
    } catch {
      #expect("\(error)".contains("the host could not decode the command's input"))
    }
  }

  @Test(.timeLimit(.minutes(1))) func aShellThatNeverAnswersThrowsAtTheLocalDeadlineAndCloses() throws {
    let t = try FakeShell.open(then: "cat >/dev/null")
    defer { t.shell.close() }
    try #require(t.events.readies == 1)
    let pid = Int(t.shell.pid)
    let started = Date()

    #expect(throws: (any Error).self) { try t.run(["/bin/sleep", "30"], timeout: 0.2, deadline: 0.6) }

    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed >= 0.55)
    #expect(elapsed < 10)
    #expect(t.events.waitForClose())
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "again"]) }
    #expect(Processes.waitForExit([pid], seconds: 5).isEmpty)
  }

  /// The noise holds a ready line with another token and ends without a newline, so the real
  /// ready line starts in the middle of a line.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func noiseBeforeTheBootScriptRunsDoesNotBreakTheHandshake(program: String) throws {
    let noise =
      "printf 'Last login: today\\nSB1 ready 00000000000000000000000000000000 none 0 0\\nSB1 1 0 0 0\\nSB1 ready \\nmotd'"
    let t = try TestShell.open("/bin/sh", ["-c", "\(noise); exec \"$0\"", program])
    defer { t.shell.close() }

    #expect(t.events.readies == 1)
    #expect(t.events.closes.isEmpty)
    let r = try t.run(["/bin/sh", "-c", "echo out; exit 2"])
    #expect(r.status == 2)
    #expect(r.stdout == Data("out\n".utf8))
  }

  /// The shell's PATH holds the programs that the boot script needs except `base64`.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aHostWithNoBase64IsReportedAsUnsupported(program: String) throws {
    try withRemoteShellTempFolder { folder in
      for tool in ["/usr/bin/mktemp", "/usr/bin/mkfifo", "/usr/bin/stat", "/usr/bin/wc", "/usr/bin/head", "/bin/rm"] {
        try FileManager.default.createSymbolicLink(
          atPath: folder + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
      }

      let t = try TestShell.open(program, environment: ["PATH": folder])
      defer { t.shell.close() }

      #expect(t.events.readies == 0)
      #expect(t.events.waitForClose())
      #expect(t.events.closes.first?.contains("the host has no stat or base64 that Switchboard can use") == true)
      #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
    }
  }

  @Test(.timeLimit(.minutes(1))) func aReadyLineOfNoneIsReportedAsUnsupported() throws {
    let t = try FakeShell.open(ready: "none 0 0", then: "cat >/dev/null")
    defer { t.shell.close() }

    #expect(t.events.readies == 0)
    #expect(t.events.waitForClose())
    #expect(t.events.closes.first?.contains("the host has no stat or base64 that Switchboard can use") == true)
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["bsd garbage here", "gnu stat: illegal option", "bsd 736", "bsd", "solaris 736 1700000000.000000000"])
  func aReadyLineWhoseStatOutputDoesNotParseNeverBecomesReady(ready: String) throws {
    let t = try FakeShell.open(ready: ready, then: "cat >/dev/null")
    defer { t.shell.close() }

    #expect(t.events.readies == 0)
    #expect(t.events.waitForClose())
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
  }

  @Test(.timeLimit(.minutes(1))) func aReadyLineOver256BytesClosesTheShell() throws {
    let t = try FakeShell.open(ready: "bsd 736 " + String(repeating: "1", count: 300), then: "cat >/dev/null")
    defer { t.shell.close() }

    #expect(t.events.readies == 0)
    #expect(t.events.waitForClose())
    #expect(t.events.closes.first?.contains("too long") == true)
  }

  /// `close()` closes the stdin FileHandle, and reading its descriptor after that raises an
  /// exception that ends the test process.
  @Test(.timeLimit(.minutes(2))) func aCloseWhileACommandStartsNeverEndsTheProcess() throws {
    for _ in 0..<200 {
      let t = try TestShell.start("/bin/sh")
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      // A block on the global queue starts seconds late while other tests block its threads.
      Thread.detachNewThread {
        _ = try? t.run(["/usr/bin/true"])
        started.signal()
        for _ in 0..<50 { _ = try? t.run(["/usr/bin/true"]) }
        finished.signal()
      }
      started.wait()
      t.shell.close()
      #expect(finished.wait(timeout: .now() + 30) == .success)
    }
  }

  @Test(.timeLimit(.minutes(1))) func aCommandBeforeTheHandshakeThrowsAndLeavesTheShellOpen() throws {
    let events = ShellEvents()
    let shell = try RemoteShell(
      executable: "/bin/sh", arguments: ["-c", "cat >/dev/null"], environment: nil,
      onReady: { _ in events.ready() }, onClose: { events.closed($0) })
    defer { shell.close() }

    #expect(shell.ready == nil)
    #expect(throws: (any Error).self) {
      try shell.run(["/bin/echo", "hi"], env: nil, input: nil, timeout: nil, deadline: 5)
    }

    Thread.sleep(forTimeInterval: 0.2)
    #expect(events.closes.isEmpty)
    #expect(Processes.exists(Int(shell.pid)))
  }

  @Test(.timeLimit(.minutes(1))) func outputThatNoCommandAskedForClosesTheShell() throws {
    let t = try FakeShell.open(then: "sleep 0.3; printf 'unasked'; cat >/dev/null")
    defer { t.shell.close() }
    try #require(t.events.readies == 1)

    #expect(t.events.waitForClose())
    #expect(t.events.closes.first?.contains("no command asked for") == true)
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
  }

  @Test(.timeLimit(.minutes(1))) func aProgramThatExitsBeforeTheHandshakeClosesWithItsStderr() throws {
    let t = try TestShell.open(
      "/bin/sh", ["-c", "echo 'ssh: connect to host mini.local port 22: refused' >&2; exit 255"])
    defer { t.shell.close() }

    #expect(t.events.readies == 0)
    #expect(t.events.waitForClose())
    Thread.sleep(forTimeInterval: 0.2)
    #expect(t.events.closes.count == 1)
    #expect(t.events.closes.first?.contains("ssh: connect to host mini.local port 22: refused") == true)
    #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
  }

  /// The shell's PATH holds the programs that the boot script needs except `mkfifo`.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aHostWithNoMkfifoClosesBeforeTheHandshakeWithAReason(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let tools = folder + "/bin"
      let temporary = folder + "/tmp"
      for path in [tools, temporary] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      }
      for tool in ["/usr/bin/mktemp", "/usr/bin/stat", "/usr/bin/base64", "/usr/bin/wc", "/usr/bin/head", "/bin/rm"] {
        try FileManager.default.createSymbolicLink(
          atPath: tools + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
      }

      let t = try TestShell.open(program, environment: ["PATH": tools, "TMPDIR": temporary])
      defer { t.shell.close() }

      #expect(t.events.readies == 0)
      #expect(t.events.waitForClose())
      #expect(t.events.closes.first?.contains("mkfifo") == true)
      #expect(throws: (any Error).self) { try t.run(["/bin/echo", "hi"]) }
      #expect(Processes.waitForExit([Int(t.shell.pid)], seconds: 5).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: temporary) == [])
    }
  }

  /// The shell's `rm` fails, so the next command would open the files of this one.
  @Test(.timeLimit(.minutes(1)), arguments: remoteShellPrograms)
  func aShellThatCannotRemoveACommandsFilesAnswersItAndThenCloses(program: String) throws {
    try withRemoteShellTempFolder { folder in
      let tools = folder + "/bin"
      let temporary = folder + "/tmp"
      for path in [tools, temporary] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      }
      for tool in [
        "/usr/bin/mktemp", "/usr/bin/mkfifo", "/usr/bin/stat", "/usr/bin/base64", "/usr/bin/wc", "/usr/bin/head",
      ] {
        try FileManager.default.createSymbolicLink(
          atPath: tools + "/" + (tool as NSString).lastPathComponent, withDestinationPath: tool)
      }
      try Data("#!/bin/sh\necho 'rm: refused' >&2\nexit 1\n".utf8).write(to: URL(fileURLWithPath: tools + "/rm"))
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools + "/rm")
      let t = try TestShell.start(program, environment: ["PATH": tools, "TMPDIR": temporary])
      defer { t.shell.close() }

      let r = try t.run(["/bin/echo", "hi"])

      #expect(r.stdout == Data("hi\n".utf8))
      #expect(t.events.waitForClose())
      #expect(t.events.closes.first?.contains("rm: refused") == true)
      #expect(throws: (any Error).self) { try t.run(["/bin/echo", "again"]) }
    }
  }
}
