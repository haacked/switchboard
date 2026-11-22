import Foundation
import Testing
import os

@testable import SwitchboardCore

/// A CI runner has 3 CPUs and starts processes several times slower than a laptop does.
private let scale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

/// A script that writes its pid to the file and then becomes `sleep 30` with that pid. It never reads stdin. The
/// `exec` matters: a shell that ran `sleep` as a child would leave it holding stdout open after SIGTERM.
private func neverEnds(pidFile: String) -> String { "echo $$ > '\(pidFile)'; exec sleep 30" }

/// Runs the script with `/bin/sh -c` through `Headless.run`, in `folder`.
private func run(
  _ script: String, input: String = "", env: [String: String] = ProcessInfo.processInfo.environment,
  folder: String, timeout: Double = 30, cancelled: @escaping @Sendable () -> Bool = { false },
  onLine: ((String) -> String?)? = nil
) throws -> String {
  try Headless.run(
    claude: "/bin/sh", arguments: ["-c", script], input: input, env: env, folder: folder, timeout: timeout,
    cancelled: cancelled, onLine: onLine)
}

/// A line handler that records each line it sees and refuses none.
private final class LineLog: Sendable {
  private let seen = OSAllocatedUnfairLock<[String]>(initialState: [])

  var lines: [String] { seen.withLock { $0 } }

  func handle(_ line: String) -> String? {
    seen.withLock { $0.append(line) }
    return nil
  }
}

/// The pid that a script wrote to the file, or nil when it wrote none.
private func writtenPid(_ file: String) -> pid_t? {
  guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
  return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Whether a process with the pid still exists. `Headless.run` reaps the process before it returns, so a process
/// that it ended no longer exists.
private func exists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// The seconds since `start`.
private func since(_ start: Date) -> Double { Date().timeIntervalSince(start) }

/// Scripts whose output a line handler must leave as it is: lines, a last line without a newline, no output, a
/// character split across two reads, a line split across two reads, and many reads.
private let parityScripts = [
  #"printf 'a\nb\nc\n'"#,
  "printf 'no newline'",
  "true",
  #"printf '\303'; sleep 0.2; printf '\251\n'"#,
  #"printf '{"half":'; sleep 0.2; printf '"rest"}\n'"#,
  "yes 'a line of output' | head -n 20000",
]

/// The process runner behind the triage summary, the merge brief, the plan update, and the quick ask.
@Suite(.timeLimit(.minutes(1))) struct HeadlessRunTests {
  // MARK: A normal run

  @Test func echoesTheInputAndReturnsWhatTheScriptPrinted() throws {
    let folder = try scratchFolder()

    let output = try run("cat", input: "hello\nworld", folder: folder)

    #expect(output == "hello\nworld")
  }

  @Test func runsInTheFolder() throws {
    let folder = try scratchFolder()

    let output = try run("pwd -P", folder: folder)

    let resolved = try #require(realpath(folder, nil))
    defer { free(resolved) }
    #expect(output.trimmingCharacters(in: .newlines) == String(cString: resolved))
  }

  @Test func passesTheEnvironment() throws {
    let folder = try scratchFolder()

    let output = try run(#"printf %s "$HEADLESS_VALUE""#, env: ["HEADLESS_VALUE": "from the caller"], folder: folder)

    #expect(output == "from the caller")
  }

  /// Process raises an exception that Swift can't catch for a NUL, which would end sbd.
  @Test func refusesANulInAnArgumentOrTheEnvironment() throws {
    let folder = try scratchFolder()

    #expect(throws: Headless.NotStarted.self) { try run("echo a\u{0}b", folder: folder) }
    #expect(throws: Headless.NotStarted.self) { try run("echo hi", env: ["X": "a\u{0}b"], folder: folder) }
    #expect(throws: Headless.NotStarted.self) { try run("echo hi", env: ["X\u{0}Y": "v"], folder: folder) }
  }

  @Test func aNonZeroExitThrowsWithTheStatusAndTheOutput() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.ExitError.self) { try run("echo partial answer; exit 3", folder: folder) }

    #expect(error?.status == 3)
    #expect(error?.output == "partial answer\n")
    #expect(error?.description.contains("status 3") == true, "\(String(describing: error))")
    #expect(error?.description.contains("partial answer") == true, "\(String(describing: error))")
  }

  /// A process that ends before it reads all of its input makes the write of the rest fail. That failure must not
  /// end the caller with SIGPIPE, and the run still returns what the process printed.
  @Test func aScriptThatReadsPartOfALargeInputAndExitsReturnsItsOutput() throws {
    let folder = try scratchFolder()
    let input = String(repeating: "x", count: 1_000_000)

    let output = try run("head -c 10", input: input, folder: folder)

    #expect(output == String(repeating: "x", count: 10))
  }

  // MARK: Timeout

  @Test func aScriptThatNeverEndsTimesOutWithinTwoSeconds() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: Headless.TimedOut.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, timeout: 0.5)
    }

    #expect(error?.description.contains("timed out") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
  }

  @Test func aTimeoutLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"

    _ = try? run(neverEnds(pidFile: pidFile), folder: folder, timeout: 0.5)

    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  // MARK: Cancel

  @Test func aCancelDuringTheRunThrowsCancelledWithinTwoSeconds() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: APIError.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { since(start) > 0.3 })
    }

    #expect(error?.description.contains("cancelled") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
  }

  @Test func aCancelDuringTheRunLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    _ = try? run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { since(start) > 0.3 })

    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  /// A cancel that arrives before the run starts no process. `NotStarted` tells `headlessCall` to record no call.
  @Test func aCancelBeforeTheRunThrowsCancelledAndLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let error = #expect(throws: Headless.NotStarted.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, cancelled: { true })
    }

    #expect(error?.description.contains("cancelled") == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
    #expect(writtenPid(pidFile).map(exists) != true)
  }

  /// The stdin write blocks once the pipe's buffer fills, because the script never reads. The end of the run must
  /// still come from the cancel or the timeout, and the failed write of the rest must not crash the caller.
  @Test(arguments: [true, false])
  func aRunThatEndsWhileItsLargeInputIsUnreadThrowsAndDoesNotCrash(_ byCancel: Bool) throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let input = String(repeating: "q", count: 1_000_000)
    let start = Date()

    let error = #expect(throws: (any Error).self) {
      try run(
        neverEnds(pidFile: pidFile), input: input, folder: folder, timeout: byCancel ? 30 : 0.5,
        cancelled: { byCancel && since(start) > 0.3 })
    }

    #expect(byCancel ? error is APIError : error is Headless.TimedOut)
    let expected = byCancel ? "cancelled" : "timed out"
    #expect(error.map { "\($0)" }?.contains(expected) == true, "\(String(describing: error))")
    #expect(since(start) < 2 * scale)
    #expect(writtenPid(pidFile).map(exists) != true)
  }

  // MARK: The monitor

  @Test func aQuickRunReturnsNormallyWhenNothingCancels() throws {
    let folder = try scratchFolder()

    let output = try run("sleep 0.1; echo done", folder: folder, cancelled: { false })

    #expect(output == "done\n")
  }

  /// The monitor that checks `cancelled` stops once the process exits, so no check, and no terminate, comes later.
  @Test func theMonitorStopsCheckingOnceTheRunEnds() throws {
    let folder = try scratchFolder()
    let checks = OSAllocatedUnfairLock(initialState: 0)
    _ = try run(
      "sleep 0.3; echo done", folder: folder,
      cancelled: {
        checks.withLock { $0 += 1 }
        return false
      })
    let afterRun = checks.withLock { $0 }

    usleep(500_000)

    #expect(checks.withLock { $0 } == afterRun)
  }

  /// A cancel that turns true only after the run returned changes nothing about that run's result.
  @Test func aCancelAfterTheRunEndedDoesNotChangeTheResult() throws {
    let folder = try scratchFolder()
    let returned = OSAllocatedUnfairLock(initialState: false)

    let output = try run("echo done", folder: folder, cancelled: { returned.withLock { $0 } })
    returned.withLock { $0 = true }
    usleep(300_000)

    #expect(output == "done\n")
  }

  // MARK: The line handler: refusal

  /// The criterion's own script. /bin/sh runs `sleep` as a child, and that child keeps stdout open after sh ends.
  /// A run that reads stdout to its end after a refusal therefore waits the full 30 s.
  @Test func aRefusalOnTheFirstLineThrowsRefusedWithinTwoSeconds() throws {
    let folder = try scratchFolder()
    let start = Date()

    #expect(throws: Headless.Refused.self) {
      try run("echo first; sleep 30", folder: folder, onLine: { _ in "wrong tools" })
    }

    #expect(since(start) < 2 * scale)
  }

  /// The trailing `true` makes sh fork `sleep` instead of running it with exec, so the orphan keeps stdout open.
  @Test func aRefusalDoesNotWaitForAChildThatKeepsStdoutOpen() throws {
    let folder = try scratchFolder()
    let start = Date()

    #expect(throws: Headless.Refused.self) {
      try run("echo first; sleep 30; true", folder: folder, onLine: { _ in "wrong tools" })
    }

    #expect(since(start) < 2 * scale)
  }

  /// An ignored signal stays ignored across exec, so only SIGKILL ends this process.
  @Test func aRefusalEndsAProcessThatIgnoresSIGTERM() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    #expect(throws: Headless.Refused.self) {
      try run(
        "trap '' TERM; echo $$ > '\(pidFile)'; echo first; exec sleep 30", folder: folder,
        onLine: { _ in "wrong tools" })
    }

    #expect(since(start) < 2 * scale)
    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  @Test func aRefusalCarriesTheHandlersReason() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.Refused.self) {
      try run("echo first; exec sleep 30", folder: folder, onLine: { _ in "wrong tools" })
    }

    #expect(error?.reason == "wrong tools")
  }

  @Test func aRefusalsDescriptionHoldsTheReason() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.Refused.self) {
      try run("echo first; exec sleep 30", folder: folder, onLine: { _ in "wrong tools" })
    }

    #expect(error?.description.contains("wrong tools") == true, "\(String(describing: error))")
  }

  /// One read can deliver more than the refused line, so the output only has to start with the lines up to it.
  @Test func aRefusalsOutputHoldsWhatTheScriptPrintedUpToTheRefusedLine() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.Refused.self) {
      try run(
        "echo first; echo second; exec sleep 30", folder: folder, onLine: { $0 == "second" ? "second line" : nil })
    }

    #expect(error?.output.hasPrefix("first\nsecond") == true, "\(String(describing: error?.output))")
  }

  @Test func aRefusalLeavesNoProcess() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"

    _ = try? run("echo $$ > '\(pidFile)'; echo first; exec sleep 30", folder: folder, onLine: { _ in "wrong tools" })

    let pid = try #require(writtenPid(pidFile))
    #expect(!exists(pid))
  }

  /// One read can deliver all three lines. The handler refuses each one, and only the first refusal counts.
  @Test func theFirstRefusalIsTheOneThatIsThrown() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.Refused.self) {
      try run(#"printf 'a\nb\nc\n'; exec sleep 30"#, folder: folder, onLine: { "refused at \($0)" })
    }

    #expect(error?.reason == "refused at a")
  }

  /// claude exits with status 1 after an error envelope. A refusal of a line still reaches the caller as a refusal.
  @Test func aRefusedLineFromAScriptThatThenExitsNonZeroThrowsRefused() throws {
    let folder = try scratchFolder()

    #expect(throws: Headless.Refused.self) {
      try run("echo bad; exit 3", folder: folder, onLine: { $0 == "bad" ? "bad line" : nil })
    }
  }

  @Test func aRefusedLastLineWithoutANewlineThrowsRefused() throws {
    let folder = try scratchFolder()

    #expect(throws: Headless.Refused.self) {
      try run("printf bad", folder: folder, onLine: { $0 == "bad" ? "bad line" : nil })
    }
  }

  // MARK: The line handler: lines

  @Test func theHandlerSeesEveryLineInOrder() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run(#"printf 'a\nb\nc\n'"#, folder: folder, onLine: log.handle)

    #expect(log.lines == ["a", "b", "c"])
  }

  @Test func aLastLineWithoutANewlineReachesTheHandler() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run(#"printf 'a\nb'"#, folder: folder, onLine: log.handle)

    #expect(log.lines == ["a", "b"])
  }

  @Test func anOutputThatEndsInANewlineGivesNoExtraLine() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run(#"printf 'a\n'"#, folder: folder, onLine: log.handle)

    #expect(log.lines == ["a"])
  }

  @Test func aScriptThatPrintsNothingNeverCallsTheHandler() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run("true", folder: folder, onLine: log.handle)

    #expect(log.lines.isEmpty)
  }

  /// The sleep makes the two halves arrive in two reads of the pipe.
  @Test func aLineSplitAcrossTwoReadsArrivesWhole() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run(#"printf '{"half":'; sleep 0.2; printf '"rest"}\n'"#, folder: folder, onLine: log.handle)

    #expect(log.lines == [#"{"half":"rest"}"#])
  }

  /// The two bytes of "é" arrive in two reads. A runner that decodes each read on its own replaces both bytes.
  @Test func aCharacterSplitAcrossTwoReadsArrivesWhole() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run(#"printf '\303'; sleep 0.2; printf '\251\n'"#, folder: folder, onLine: log.handle)

    #expect(log.lines == ["é"])
  }

  /// 20,000 lines fill many reads of the pipe, so lines cross read boundaries at many offsets.
  @Test func manyLinesAcrossManyReadsReachTheHandlerOneForOne() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run("yes 'a line of output' | head -n 20000", folder: folder, onLine: log.handle)

    #expect(log.lines.count == 20000)
  }

  @Test func manyLinesAcrossManyReadsEachArriveWhole() throws {
    let folder = try scratchFolder()
    let log = LineLog()

    _ = try run("yes 'a line of output' | head -n 20000", folder: folder, onLine: log.handle)

    #expect(log.lines.allSatisfy { $0 == "a line of output" })
  }

  // MARK: The line handler: parity with no handler

  /// A handler that refuses nothing leaves the returned output as it is without a handler.
  @Test(arguments: parityScripts)
  func aHandlerThatRefusesNothingReturnsTheSameOutputAsNoHandler(_ script: String) throws {
    let folder = try scratchFolder()

    let withHandler = try run(script, folder: folder, onLine: LineLog().handle)
    let withoutHandler = try run(script, folder: folder)

    #expect(withHandler == withoutHandler)
  }

  @Test func aHandlerThatRefusesNothingStillGivesTheExitError() throws {
    let folder = try scratchFolder()

    let error = #expect(throws: Headless.ExitError.self) {
      try run("echo partial answer; exit 3", folder: folder, onLine: LineLog().handle)
    }

    #expect(error?.output == "partial answer\n")
  }

  @Test func aHandlerThatRefusesNothingStillTimesOut() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    #expect(throws: Headless.TimedOut.self) {
      try run(neverEnds(pidFile: pidFile), folder: folder, timeout: 0.5, onLine: LineLog().handle)
    }

    #expect(since(start) < 2 * scale)
  }

  @Test func aHandlerThatRefusesNothingStillCancels() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    #expect(throws: APIError.self) {
      try run(
        neverEnds(pidFile: pidFile), folder: folder, cancelled: { since(start) > 0.3 }, onLine: LineLog().handle)
    }

    #expect(since(start) < 2 * scale)
  }
}
