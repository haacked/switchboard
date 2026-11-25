import Foundation
import Testing
import os

@testable import SwitchboardCore

/// A CI runner has 3 CPUs and starts processes several times slower than a laptop does.
private let scale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

/// The cap on a run's log, from Decision 12.
private let logCap = 1 << 20
private let cutMarker = "[output cut at 1 MiB]"

/// Runs the script with `/bin/sh -c` through `DetachedRun.run`, in `folder`, with its log at `folder/run.log`.
private func run(
  _ script: String, env: [String: String] = ProcessInfo.processInfo.environment, folder: String,
  timeout: Double = 30, cancelled: @escaping @Sendable () -> Bool = { false }
) throws -> DetachedRun.Result {
  try DetachedRun.run(
    executable: "/bin/sh", arguments: ["-c", script], env: env, folder: folder, log: logPath(folder),
    timeout: timeout, cancelled: cancelled)
}

private func logPath(_ folder: String) -> String { "\(folder)/run.log" }

private func logText(_ folder: String) -> String {
  (try? String(contentsOfFile: logPath(folder), encoding: .utf8)) ?? ""
}

private func logSize(_ folder: String) -> Int {
  ((try? FileManager.default.attributesOfItem(atPath: logPath(folder)))?[.size] as? NSNumber)?.intValue ?? 0
}

/// The pid that a script wrote to the file, or nil when it wrote none.
private func writtenPid(_ file: String) -> pid_t? {
  guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
  return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Whether a process with the pid still exists. A grandchild that the run ends is a zombie until launchd reaps it,
/// so a check right after the run can still find it.
private func exists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Waits up to 2 s (more on CI) for the process to go, and returns whether it went.
private func gone(_ pid: pid_t) -> Bool {
  let deadline = Date().addingTimeInterval(2 * scale)
  while Date() < deadline {
    if !exists(pid) { return true }
    usleep(50_000)
  }
  return !exists(pid)
}

private func since(_ start: Date) -> Double { Date().timeIntervalSince(start) }

/// The process runner behind headless and script schedules. It starts the child in a new POSIX session, so a
/// timeout or a cancel can end every process that the run started.
@Suite(.timeLimit(.minutes(1))) struct DetachedRunTests {
  // MARK: A normal run

  @Test func aRunThatExitsZeroReportsExitZero() throws {
    let folder = try scratchFolder()

    let result = try run("echo hello", folder: folder)

    #expect(result.exit == 0)
    #expect(!result.timedOut)
    #expect(!result.cancelled)
  }

  @Test func aRunThatExitsThreeReportsExitThree() throws {
    let folder = try scratchFolder()

    let result = try run("echo partial; exit 3", folder: folder)

    #expect(result.exit == 3)
    #expect(!result.timedOut)
  }

  @Test func theLogHoldsStdout() throws {
    let folder = try scratchFolder()

    _ = try run("echo hello", folder: folder)

    #expect(logText(folder) == "hello\n")
  }

  @Test func theLogHoldsStderrToo() throws {
    let folder = try scratchFolder()

    _ = try run("echo out; echo err >&2", folder: folder)

    #expect(logText(folder).contains("out"))
    #expect(logText(folder).contains("err"))
  }

  @Test func theTailIsTheLastNonEmptyLine() throws {
    let folder = try scratchFolder()

    let result = try run(#"printf 'first\nlast\n\n   \n'"#, folder: folder)

    #expect(result.tail == "last")
  }

  @Test func aRunThatPrintsNothingHasNoTail() throws {
    let folder = try scratchFolder()

    let result = try run("true", folder: folder)

    #expect(result.tail == nil || result.tail == "")
  }

  @Test func theTailIsAtMostTwoHundredCharacters() throws {
    let folder = try scratchFolder()

    let result = try run("printf '%0500d\\n' 0", folder: folder)

    let tail = try #require(result.tail)
    #expect(tail.count <= 200)
    #expect(!tail.isEmpty)
  }

  @Test func theDurationCoversTheRun() throws {
    let folder = try scratchFolder()

    let result = try run("sleep 0.3", folder: folder)

    #expect(result.ms >= 300)
    #expect(result.ms < Int64(10_000 * scale))
  }

  @Test func runsInTheFolder() throws {
    let folder = try scratchFolder()

    _ = try run("pwd -P", folder: folder)

    let resolved = try #require(realpath(folder, nil))
    defer { free(resolved) }
    #expect(logText(folder).trimmingCharacters(in: .newlines) == String(cString: resolved))
  }

  @Test func passesTheEnvironment() throws {
    let folder = try scratchFolder()

    _ = try run(#"printf %s "$DETACHED_VALUE""#, env: ["DETACHED_VALUE": "from the caller"], folder: folder)

    #expect(logText(folder) == "from the caller")
  }

  /// The run's environment is the one sbd builds, never sbd's own.
  @Test func theEnvironmentReplacesTheParents() throws {
    let folder = try scratchFolder()
    let inherited = try #require(ProcessInfo.processInfo.environment["HOME"])
    try #require(!inherited.isEmpty)

    _ = try run(#"printf '[%s]' "$HOME""#, env: ["DETACHED_VALUE": "x"], folder: folder)

    #expect(logText(folder) == "[]")
  }

  /// A script that reads stdin must not wait for input that never comes.
  @Test func stdinIsEmpty() throws {
    let folder = try scratchFolder()

    let result = try run("cat; echo done", folder: folder, timeout: 10)

    #expect(!result.timedOut)
    #expect(result.exit == 0)
    #expect(logText(folder) == "done\n")
  }

  /// POSIX_SPAWN_SETSID makes the child the leader of a new session and of a new process group, so `killpg` reaches
  /// every process that it starts and none of the test's.
  @Test func theChildLeadsItsOwnProcessGroup() throws {
    let folder = try scratchFolder()

    _ = try run(#"echo "$$ $(ps -o pgid= -p $$ | tr -d ' ')""#, folder: folder)

    let parts = logText(folder).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    try #require(parts.count == 2, "\(logText(folder))")
    #expect(parts[0] == parts[1])
    #expect(parts[1] != String(getpgrp()))
  }

  // MARK: Refusals

  /// A NUL can't pass through posix_spawn, and a cut argument would run a different command.
  @Test func refusesANulInAnArgument() throws {
    let folder = try scratchFolder()

    #expect(throws: (any Error).self) { try run("echo a\u{0}b", folder: folder) }
  }

  @Test func refusesANulInAnEnvironmentValue() throws {
    let folder = try scratchFolder()

    #expect(throws: (any Error).self) { try run("echo hi", env: ["X": "a\u{0}b"], folder: folder) }
  }

  @Test func refusesANulInAnEnvironmentKey() throws {
    let folder = try scratchFolder()

    #expect(throws: (any Error).self) { try run("echo hi", env: ["X\u{0}Y": "v"], folder: folder) }
  }

  @Test func refusesAProgramThatDoesNotExist() throws {
    let folder = try scratchFolder()

    #expect(throws: (any Error).self) {
      try DetachedRun.run(
        executable: "\(folder)/no-such-program", arguments: [], env: [:], folder: folder, log: logPath(folder),
        timeout: 5)
    }
  }

  // MARK: Timeout

  @Test func aRunThatNeverEndsTimesOut() throws {
    let folder = try scratchFolder()
    let start = Date()

    let result = try run("exec sleep 30", folder: folder, timeout: 0.5)

    #expect(result.timedOut)
    #expect(!result.cancelled)
    #expect(since(start) < 0.5 + 2 * scale)
  }

  /// A background child of the script stays in the script's process group, so the timeout's group signal ends it.
  @Test func aTimeoutEndsAForkedChild() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"

    let result = try run("sleep 30 & echo $! > '\(pidFile)'; wait", folder: folder, timeout: 0.5)

    #expect(result.timedOut)
    let pid = try #require(writtenPid(pidFile))
    #expect(gone(pid))
  }

  /// An ignored signal stays ignored across exec, so only SIGKILL, 5 s after SIGTERM, ends this process.
  @Test func aTimeoutEndsAProcessThatIgnoresSIGTERMWithSIGKILL() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    let result = try run("trap '' TERM; echo $$ > '\(pidFile)'; exec sleep 30", folder: folder, timeout: 0.5)

    #expect(result.timedOut)
    #expect(since(start) >= 0.5 + 4.5)
    #expect(since(start) < 0.5 + 5 + 3 * scale)
    let pid = try #require(writtenPid(pidFile))
    #expect(gone(pid))
  }

  /// The script exits at once, but its background `sleep` keeps the pipe open. The run must not wait for that pipe past the
  /// deadline, and the group signal must end the `sleep`.
  @Test func aGrandchildThatHoldsStdoutOpenDoesNotOutliveTheDeadline() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    _ = try run("sleep 30 & echo $! > '\(pidFile)'; echo started; exit 0", folder: folder, timeout: 1)

    #expect(since(start) < 1 + 2 * scale)
    let pid = try #require(writtenPid(pidFile))
    #expect(gone(pid))
  }

  @Test func aTimedOutRunKeepsWhatItLogged() throws {
    let folder = try scratchFolder()

    let result = try run("echo before; exec sleep 30", folder: folder, timeout: 0.5)

    #expect(result.timedOut)
    #expect(logText(folder).contains("before"))
  }

  /// The script exits at once and leaves a process that ignores SIGTERM and holds no output. The run ends it before
  /// it returns, with SIGKILL after the grace.
  @Test func aProcessThatTheScriptLeavesBehindEndsWithTheRun() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"

    let result = try run(
      #"sh -c "trap '' TERM; exec sleep 30" > /dev/null 2>&1 & echo $! > '\#(pidFile)'; exit 0"#, folder: folder)

    #expect(result.exit == 0)
    #expect(!result.timedOut)
    let pid = try #require(writtenPid(pidFile))
    #expect(gone(pid))
  }

  /// A process that starts a session of its own leaves the group, so no group signal reaches it. Its open copy of the
  /// output must not hold the run.
  @Test func aGrandchildInASessionOfItsOwnDoesNotHoldTheRun() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    defer { if let pid = writtenPid(pidFile) { kill(pid, SIGKILL) } }
    let start = Date()

    let result = try run(
      #"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); open(F, ">", $ARGV[0]); print F $$; close F; exec "sleep", "30"' '\#(pidFile)' & sleep 0.5; echo done"#,
      folder: folder, timeout: 20)

    #expect(result.exit == 0)
    #expect(since(start) < 0.5 + 2 * scale)
    #expect(logText(folder).contains("done"))
  }

  @Test func aRunThatEndsOnASignalHasNoExitStatus() throws {
    let folder = try scratchFolder()

    let result = try run("kill -9 $$", folder: folder)

    #expect(result.exit == nil)
    #expect(!result.timedOut)
  }

  /// The tail reaches a terminal through `sb schedule ls`, which would act on an escape sequence.
  @Test func theTailHoldsNoEscapeSequenceOrControlCharacter() throws {
    let folder = try scratchFolder()

    let result = try run(#"printf '\033[31mred\033[0m and\007 done\n'"#, folder: folder)

    #expect(result.tail == "red and done")
  }

  /// The log keeps the start of the output, and the tail is the end of the output.
  @Test func aCutLogsTailIsTheOutputsLastLine() throws {
    let folder = try scratchFolder()

    let result = try run("head -c 2097152 /dev/zero | tr '\\0' 'x'; echo; echo the end", folder: folder, timeout: 20)

    #expect(result.tail == "the end")
  }

  @Test func refusesAFolderThatDoesNotExist() throws {
    let folder = try scratchFolder()

    #expect(throws: (any Error).self) { try run("echo hi", folder: "\(folder)/missing") }
  }

  // MARK: Cancel

  @Test func aCancelEndsTheRunQuickly() throws {
    let folder = try scratchFolder()
    let start = Date()

    let result = try run("exec sleep 30", folder: folder, cancelled: { since(start) > 0.3 })

    #expect(result.cancelled)
    #expect(!result.timedOut)
    #expect(since(start) < 0.3 + 2 * scale)
  }

  @Test func aCancelEndsAForkedChild() throws {
    let folder = try scratchFolder()
    let pidFile = "\(folder)/pid"
    let start = Date()

    _ = try run("sleep 30 & echo $! > '\(pidFile)'; wait", folder: folder, cancelled: { since(start) > 0.3 })

    let pid = try #require(writtenPid(pidFile))
    #expect(gone(pid))
  }

  @Test func aRunThatEndsOnItsOwnIsNotCancelled() throws {
    let folder = try scratchFolder()

    let result = try run("echo done", folder: folder, cancelled: { false })

    #expect(!result.cancelled)
  }

  // MARK: The log cap

  /// The run keeps reading past the cap. A runner that stopped reading would block the script on a full pipe until
  /// the timeout, so an exit of 0 without a timeout shows that the pipe drained.
  @Test(.timeLimit(.minutes(1))) func fiftyMebibytesOfOutputAreCutAtOneMebibyte() throws {
    let folder = try scratchFolder()

    let result = try run("head -c 52428800 /dev/zero | tr '\\0' 'x'; echo; echo end", folder: folder, timeout: 40)

    #expect(!result.timedOut)
    #expect(result.exit == 0)
    #expect(logSize(folder) <= logCap + cutMarker.utf8.count + 2)
    #expect(logSize(folder) >= logCap)
  }

  @Test func aCutLogEndsWithTheMarker() throws {
    let folder = try scratchFolder()

    _ = try run("head -c 2097152 /dev/zero | tr '\\0' 'x'", folder: folder, timeout: 20)

    #expect(logText(folder).trimmingCharacters(in: .newlines).hasSuffix(cutMarker))
  }

  @Test func aLogUnderTheCapHasNoMarker() throws {
    let folder = try scratchFolder()

    _ = try run("head -c 1000 /dev/zero | tr '\\0' 'x'; echo", folder: folder)

    #expect(!logText(folder).contains(cutMarker))
    #expect(logSize(folder) == 1001)
  }
}
