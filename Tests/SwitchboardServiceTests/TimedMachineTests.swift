import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// A machine that records each call and hands it to another machine, or answers it itself when it has none.
final class CallRecorder: Machine, @unchecked Sendable {
  struct Run: Equatable {
    var executable: String
    var args: [String]
    var env: [String: String]?
    var input: Data?
    var timeout: Double?
  }

  private let lock = NSLock()
  private var recordedRuns: [Run] = []
  private var recordedCalls: [String] = []
  private var recordedResults: [CommandResult] = []
  private let next: (any Machine)?

  init(_ next: (any Machine)? = nil) { self.next = next }

  /// Every `run`, oldest first.
  var runs: [Run] { lock.withLock { recordedRuns } }

  /// What each `run` of `next` answered, oldest first.
  var results: [CommandResult] { lock.withLock { recordedResults } }

  /// Every member that is not `run`, as `<member> <argument>`, oldest first.
  var calls: [String] { lock.withLock { recordedCalls } }

  private func note(_ call: String) { lock.withLock { recordedCalls.append(call) } }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    lock.withLock {
      recordedRuns.append(Run(executable: executable, args: args, env: env, input: input, timeout: timeout))
    }
    if let next {
      let result = try next.run(executable, args, env: env, input: input, timeout: timeout)
      lock.withLock { recordedResults.append(result) }
      return result
    }
    return CommandResult(status: 7, stdout: "out of \(executable)", stderr: "err of \(executable)")
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    note("read \(path) \(offset) \(count.map(String.init) ?? "all")")
    return next.map { $0.read(path, from: offset, count: count) } ?? Data("read \(path)".utf8)
  }

  func size(_ path: String) -> UInt64? {
    note("size \(path)")
    return next.map { $0.size(path) } ?? 42
  }

  func exists(_ path: String) -> Bool {
    note("exists \(path)")
    return next?.exists(path) ?? true
  }

  func isFolder(_ path: String) -> Bool {
    note("isFolder \(path)")
    return next?.isFolder(path) ?? true
  }

  func modified(_ path: String) -> Date? {
    note("modified \(path)")
    return next.map { $0.modified(path) } ?? Date(timeIntervalSince1970: 1_794_377_400)
  }

  func list(_ folder: String) -> [String] {
    note("list \(folder)")
    return next?.list(folder) ?? ["a", "b"]
  }

  func createFolder(_ path: String) throws {
    note("createFolder \(path)")
    try next?.createFolder(path)
  }

  func signal(_ pid: Int, _ signal: Int32) {
    note("signal \(pid) \(signal)")
    next?.signal(pid, signal)
  }
}

/// A machine whose `run` throws.
private struct FailingMachine: Machine {
  struct Failure: Error {}

  func run(_ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?) throws
    -> CommandResult
  { throw Failure() }
  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? { nil }
  func size(_ path: String) -> UInt64? { nil }
  func exists(_ path: String) -> Bool { false }
  func isFolder(_ path: String) -> Bool { false }
  func modified(_ path: String) -> Date? { nil }
  func list(_ folder: String) -> [String] { [] }
  func createFolder(_ path: String) throws { throw Failure() }
  func signal(_ pid: Int, _ signal: Int32) {}
}

/// `TimedMachine` gives a timeout to each `run` that names none, so no command reaches a host without one.
@Suite struct TimedMachineTests {
  @Test func aRunWithNoTimeoutGetsTheFallback() throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: 30)

    _ = try machine.run("/bin/echo", ["hi"], env: nil, input: nil, timeout: nil)

    #expect(base.runs.map(\.timeout) == [30])
  }

  @Test(
    arguments: [
      ["-C", "/r", "worktree", "add", "-b", "b", "/t", "HEAD"], ["-C", "/r", "worktree", "remove", "/t"],
    ] as [[String]])
  func aWorktreeChangeWithNoTimeoutGetsTheWorktreeTimeout(args: [String]) throws {
    let base = CallRecorder()

    _ = try TimedMachine(base, fallback: 30).run("/usr/bin/git", args, env: nil, input: nil, timeout: nil)

    #expect(base.runs.map(\.timeout) == [TimedMachine.worktreeChangeSeconds])
  }

  @Test func aWorktreeListGetsTheFallback() throws {
    let base = CallRecorder()

    _ = try TimedMachine(base, fallback: 30).run(
      "/usr/bin/git", ["-C", "/r", "worktree", "list", "--porcelain"], env: nil, input: nil, timeout: nil)

    #expect(base.runs.map(\.timeout) == [30])
  }

  @Test func theShortFormOfRunGetsTheFallback() throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: 30)

    _ = try machine.run("/bin/echo", ["hi"])

    #expect(base.runs.map(\.timeout) == [30])
  }

  @Test(arguments: [0.5, 5, 30, 600])
  func aCallersTimeoutPassesThrough(timeout: Double) throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: 30)

    _ = try machine.run("/bin/echo", ["hi"], env: nil, input: nil, timeout: timeout)

    #expect(base.runs.map(\.timeout) == [timeout])
  }

  @Test(arguments: [1.0, 30, 45])
  func theFallbackIsTheOneThatTheMachineWasBuiltWith(fallback: Double) throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: fallback)

    _ = try machine.run("/bin/echo", [])

    #expect(base.runs.map(\.timeout) == [fallback])
  }

  @Test func aRunKeepsItsProgramArgumentsEnvironmentAndInput() throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: 30)
    let input = Data("stdin".utf8)

    _ = try machine.run("/usr/bin/git", ["-C", "/a b", "status"], env: ["LANG": "C"], input: input, timeout: nil)

    #expect(
      base.runs == [
        CallRecorder.Run(
          executable: "/usr/bin/git", args: ["-C", "/a b", "status"], env: ["LANG": "C"], input: input, timeout: 30)
      ])
  }

  @Test func aRunReturnsTheBaseMachinesResult() throws {
    let machine = TimedMachine(CallRecorder(), fallback: 30)

    let r = try machine.run("/bin/echo", [])

    #expect(r.status == 7)
    #expect(r.stdout == "out of /bin/echo")
    #expect(r.stderr == "err of /bin/echo")
  }

  @Test func aRunThrowsWhatTheBaseMachineThrows() {
    let machine = TimedMachine(FailingMachine(), fallback: 30)

    #expect(throws: FailingMachine.Failure.self) { try machine.run("/bin/echo", []) }
    #expect(throws: FailingMachine.Failure.self) { try machine.createFolder("/x") }
  }

  @Test func theFileAndSignalMembersReachTheBaseMachineWithTheirArguments() throws {
    let base = CallRecorder()
    let machine = TimedMachine(base, fallback: 30)

    let read = machine.read("/f", from: 3, count: 4)
    let size = machine.size("/f")
    let exists = machine.exists("/f")
    let isFolder = machine.isFolder("/d")
    let modified = machine.modified("/f")
    let list = machine.list("/d")
    try machine.createFolder("/d/new")
    machine.signal(4242, SIGTERM)

    #expect(
      base.calls == [
        "read /f 3 4", "size /f", "exists /f", "isFolder /d", "modified /f", "list /d", "createFolder /d/new",
        "signal 4242 \(SIGTERM)",
      ])
    #expect(read == Data("read /f".utf8))
    #expect(size == 42)
    #expect(exists)
    #expect(isFolder)
    #expect(modified == Date(timeIntervalSince1970: 1_794_377_400))
    #expect(list == ["a", "b"])
    #expect(base.runs.isEmpty)
  }

  @Test func theFileMembersReturnTheBaseMachinesMissingAnswers() {
    let machine = TimedMachine(FailingMachine(), fallback: 30)

    #expect(machine.read("/f", from: 0, count: nil) == nil)
    #expect(machine.size("/f") == nil)
    #expect(!machine.exists("/f"))
    #expect(!machine.isFolder("/f"))
    #expect(machine.modified("/f") == nil)
    #expect(machine.list("/f").isEmpty)
  }

  @Test func aRealCommandRunsThroughTheMachineAndEndsAtItsOwnTimeout() throws {
    let machine = TimedMachine(LocalMachine(), fallback: 0.3)
    let started = Date()

    let r = try machine.run("/bin/sleep", ["20"])

    #expect(r.status != 0)
    #expect(Date().timeIntervalSince(started) < 10)
  }
}
