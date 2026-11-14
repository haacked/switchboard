import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct ProcessTests {
  /// Swift Testing runs tests on the cooperative pool, which has one thread
  /// per CPU, and integration tests call runCommand from there in parallel.
  @Test(
    .timeLimit(.minutes(1))) func runsMoreCommandsAtOnceThanThereAreCPUs() async
  {
    let count = 2 * ProcessInfo.processInfo.activeProcessorCount
    let statuses = await withTaskGroup(of: Int32.self) { group in
      for _ in 0..<count {
        group.addTask { (try? runCommand("/bin/sleep", ["0.2"]))?.status ?? -1 }
      }
      return await group.reduce(into: [Int32]()) { $0.append($1) }
    }
    #expect(statuses == Array(repeating: 0, count: count))
  }

  @Test(.timeLimit(.minutes(1))) func endsACommandThatOutlastsItsTimeout() throws {
    let start = Date()
    let r = try runCommand("/bin/sleep", ["30"], timeout: 0.3)
    #expect(r.status != 0)
    #expect(Date().timeIntervalSince(start) < 10)
  }

  /// Process raises an exception that Swift can't catch for a NUL, which would end the program.
  @Test func refusesANulInAnArgumentOrTheEnvironment() {
    #expect(throws: APIError.self) { try runCommand("/bin/echo", ["a\u{0}b"]) }
    #expect(throws: APIError.self) { try runCommand("/bin/echo", ["hi"], env: ["X": "a\u{0}b"]) }
  }

  @Test func leavesACommandThatFinishesInTimeAlone() throws {
    #expect(try runCommand("/bin/echo", ["hi"], timeout: 30).stdout == "hi\n")
  }

  // MARK: ancestors(of:)

  @Test func ancestorsOfThisProcessHoldItselfItsParentAndLaunchd() throws {
    let ancestry = try #require(Processes.ancestors(of: Int(getpid())))

    #expect(ancestry.isSuperset(of: [Int(getpid()), Int(getppid()), 1]), "\(ancestry)")
  }

  /// `Int32.max` passes `Processes.isValidPid` and names no process. `Int32.max + 1` fails it.
  @Test(arguments: [0, -1, Int(Int32.max), Int(Int32.max) + 1])
  func ancestorsOfAPidThatNamesNoProcessIsNil(pid: Int) {
    #expect(Processes.ancestors(of: pid) == nil)
  }

  /// A script that runs sb makes sb a grandchild of the pane's process.
  @Test(.timeLimit(.minutes(1))) func ancestorsOfAGrandchildHoldItsParentAndThisProcess() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "/bin/sleep 30 >/dev/null & echo $!; wait"]
    let output = Pipe()
    child.standardOutput = output
    try child.run()
    let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
    let grandchild = try #require(Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), "\(line)")
    defer {
      kill(pid_t(grandchild), SIGKILL)
      kill(child.processIdentifier, SIGKILL)
      child.waitUntilExit()
    }

    let ancestry = try #require(Processes.ancestors(of: grandchild))

    #expect(ancestry.isSuperset(of: [grandchild, Int(child.processIdentifier), Int(getpid()), 1]), "\(ancestry)")
  }

  /// The kernel moves the children of a process that exits to launchd.
  @Test(.timeLimit(.minutes(1))) func ancestorsOfAnOrphanAreItAndLaunchd() throws {
    let r = try runCommand("/bin/sh", ["-c", "/bin/sleep 30 </dev/null >/dev/null 2>&1 & echo $!"], timeout: 30)
    let orphan = try #require(Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), "\(r.stdout)")
    defer { kill(pid_t(orphan), SIGKILL) }

    #expect(Processes.ancestors(of: orphan) == [orphan, 1])
  }
}

@Suite struct ShellQuoteTests {
  @Test(arguments: [
    ("", "''"), ("a b", "'a b'"), ("'", #"''\'''"#), ("it's", #"'it'\''s'"#), ("''", #"''\'''\'''"#),
    ("$HOME `id` \"x\"", "'$HOME `id` \"x\"'"), ("line\nbreak", "'line\nbreak'"), ("héllo ✓ 日本", "'héllo ✓ 日本'"),
    ("e\u{301}", "'e\u{301}'"), ("a\\b", "'a\\b'"),
  ])
  func putsTheTextInSingleQuotes(text: String, quoted: String) {
    #expect(Array(shellQuote(text).utf8) == Array(quoted.utf8))
  }

  /// A `'` and the combining character after it are one character.
  @Test(arguments: ["'\u{301}; touch /tmp/sb-injected; '\u{301}", "'\u{FE0F}x", "a'\u{200D}b", "e\u{301}'"])
  func escapesAQuoteBeforeACombiningCharacter(text: String) {
    let quoted = shellQuote(text)

    #expect(
      !quoted.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "", options: .literal).unicodeScalars
        .contains("'"))
  }

  /// The shell reads the command from stdin, because `Process` decomposes the characters of an
  /// argument.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "'\u{301}; echo INJECTED; '\u{301}", "'\u{FE0F}x", "a'\u{200D}b", "e\u{301}'", "'", "it's", "'\\''", "",
      "$(echo INJECTED)", "`echo INJECTED`", "a; echo INJECTED", "line\nbreak", "héllo ✓ 日本", "\\", "%s", "-n",
    ])
  func aShellReadsTheQuotedTextAsTheSameBytes(text: String) throws {
    let r = try runCommand("/bin/sh", [], input: Data("printf %s \(shellQuote(text))\n".utf8), timeout: 30)

    #expect(r.status == 0)
    #expect(Array(r.stdout.utf8) == Array(text.utf8))
    #expect(r.stderr.isEmpty)
  }
}
