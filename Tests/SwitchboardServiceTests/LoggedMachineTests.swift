import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// Reads the file that a `LoggedMachine` and a logging `MacSite` append to.
enum MachineLogFile {
  /// The words of each line, oldest first. A line's words are its keys, strings, and whole numbers at any depth,
  /// which hold the member's name and its arguments. It throws for a line that is not one JSON object. A missing
  /// file has no lines.
  static func lines(_ path: String) throws -> [[String]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    try #require(text.isEmpty || text.hasSuffix("\n"), "the log's last line has no newline")
    return try text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
      let json = try #require(JSON.parse(String(line)), "not JSON: \(line)")
      try #require(json.object != nil, "not a JSON object: \(line)")
      return words(json)
    }
  }

  /// The lines that hold the member's name.
  static func lines(_ path: String, of member: String) throws -> [[String]] {
    try lines(path).filter { $0.contains(member) }
  }

  private static func words(_ value: JSON) -> [String] {
    switch value {
    case .string(let text): [text]
    case .number: value.int.map { [String($0)] } ?? []
    case .array(let items): items.flatMap(words)
    case .object(let fields): fields.flatMap { [$0.key] + words($0.value) }
    case .null, .bool: []
    }
  }
}

/// A machine that answers every member with a fixed value and records the arguments it got.
private final class FixedMachine: Machine, @unchecked Sendable {
  struct Failure: Error {}

  static let result = CommandResult(status: 7, stdout: "out\n", stderr: "err\n")
  static let data = Data("bytes".utf8)
  static let date = Date(timeIntervalSince1970: 1_700_000_000)
  static let names = ["a.jsonl", "b.jsonl"]

  private let lock = NSLock()
  private var recorded: [String] = []
  /// A machine that fails throws from `run` and `createFolder` and reads nothing.
  let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  var calls: [String] { lock.withLock { recorded } }

  private func note(_ call: String) { lock.withLock { recorded.append(call) } }

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    let input = input.map { String(decoding: $0, as: UTF8.self) }
    note("run \(executable) \(args) \(env ?? [:]) \(input ?? "nil") \(timeout ?? -1)")
    if fails { throw Failure() }
    return FixedMachine.result
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    note("read \(path) \(offset) \(count ?? -1)")
    return fails ? nil : FixedMachine.data
  }

  func size(_ path: String) -> UInt64? {
    note("size \(path)")
    return fails ? nil : 4096
  }

  func exists(_ path: String) -> Bool {
    note("exists \(path)")
    return !fails
  }

  func isFolder(_ path: String) -> Bool {
    note("isFolder \(path)")
    return !fails
  }

  func modified(_ path: String) -> Date? {
    note("modified \(path)")
    return fails ? nil : FixedMachine.date
  }

  func list(_ folder: String) -> [String] {
    note("list \(folder)")
    return fails ? [] : FixedMachine.names
  }

  func createFolder(_ path: String) throws {
    note("createFolder \(path)")
    if fails { throw Failure() }
  }

  func signal(_ pid: Int, _ signal: Int32) { note("signal \(pid) \(signal)") }
}

/// One call of each member of `Machine`, with the words that its log line must hold.
private enum Member: String, CaseIterable {
  case run, read, size, exists, isFolder, modified, list, createFolder, signal

  func call(_ machine: any Machine) throws {
    switch self {
    case .run: _ = try machine.run("/box/bin/tool", ["first arg", "second"], env: nil, input: nil, timeout: 5)
    case .read: _ = machine.read("/box/file.jsonl", from: 12, count: 34)
    case .size: _ = machine.size("/box/file.jsonl")
    case .exists: _ = machine.exists("/box/file.jsonl")
    case .isFolder: _ = machine.isFolder("/box/folder")
    case .modified: _ = machine.modified("/box/file.jsonl")
    case .list: _ = machine.list("/box/folder")
    case .createFolder: try machine.createFolder("/box/new folder")
    case .signal: machine.signal(4242, SIGTERM)
    }
  }

  var arguments: [String] {
    switch self {
    case .run: ["/box/bin/tool", "first arg", "second"]
    case .read: ["/box/file.jsonl", "12", "34"]
    case .size, .exists, .modified: ["/box/file.jsonl"]
    case .isFolder, .list: ["/box/folder"]
    case .createFolder: ["/box/new folder"]
    case .signal: ["4242", String(SIGTERM)]
    }
  }
}

@Suite struct LoggedMachineTests {
  /// Runs `body` with the path of a log in a new folder. The file does not exist yet.
  private func withLog(_ body: (String) throws -> Void) throws {
    var template = Array("/tmp/sbl.XXXXXX".utf8CString)
    let dir = String(cString: try #require(mkdtemp(&template)))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try body("\(dir)/mac-machine.log")
  }

  // MARK: The log

  @Test(arguments: Member.allCases)
  fileprivate func eachMemberWritesOneLineWithItsNameAndItsArguments(member: Member) throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(), log: MachineLog(path: log))

      try member.call(machine)

      let lines = try MachineLogFile.lines(log)
      #expect(lines.count == 1)
      let words = try #require(lines.first)
      #expect(words.contains(member.rawValue), "\(words)")
      for argument in member.arguments {
        #expect(words.contains(argument), "\(member.rawValue) lacks \(argument) in \(words)")
      }
    }
  }

  @Test(arguments: Member.allCases)
  fileprivate func eachMemberReachesTheBaseMachineOnce(member: Member) throws {
    try withLog { log in
      let base = FixedMachine()

      try member.call(LoggedMachine(base, log: MachineLog(path: log)))

      #expect(base.calls.count == 1)
      #expect(base.calls.first?.hasPrefix("\(member.rawValue) ") == true, "\(base.calls)")
    }
  }

  @Test func theLinesAreInTheOrderOfTheCalls() throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(), log: MachineLog(path: log))

      for member in Member.allCases { try member.call(machine) }

      let lines = try MachineLogFile.lines(log)
      #expect(lines.count == Member.allCases.count)
      for (words, member) in zip(lines, Member.allCases) {
        #expect(words.contains(member.rawValue), "\(words)")
      }
    }
  }

  @Test func aSecondMachineAppendsToTheSameLog() throws {
    try withLog { log in
      _ = LoggedMachine(FixedMachine(), log: MachineLog(path: log)).exists("/box/first")

      _ = LoggedMachine(FixedMachine(), log: MachineLog(path: log)).exists("/box/second")

      let lines = try MachineLogFile.lines(log)
      #expect(lines.count == 2)
      #expect(lines.first?.contains("/box/first") == true)
      #expect(lines.last?.contains("/box/second") == true)
    }
  }

  /// A newline or a quote in an argument must not split a line or end its JSON.
  @Test(arguments: ["two\nlines", "a \"quoted\" word", "back\\slash", "tab\there", "naïve ✓", ""])
  func anArgumentWithSpecialCharactersStaysWholeOnOneLine(argument: String) throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(), log: MachineLog(path: log))

      _ = try machine.run("/box/bin/tool", [argument], env: nil, input: nil, timeout: nil)

      let lines = try MachineLogFile.lines(log)
      #expect(lines.count == 1)
      #expect(lines.first?.contains(argument) == true, "\(lines)")
    }
  }

  @Test func callsFromManyThreadsEachWriteAWholeLine() throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(), log: MachineLog(path: log))

      DispatchQueue.concurrentPerform(iterations: 64) { _ = machine.exists("/box/file-\($0)") }

      let lines = try MachineLogFile.lines(log)
      #expect(lines.count == 64)
      #expect(Set(lines.flatMap { $0 }.filter { $0.hasPrefix("/box/file-") }).count == 64)
    }
  }

  @Test func aCallThatThrowsStillWritesItsLine() throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(fails: true), log: MachineLog(path: log))

      #expect(throws: FixedMachine.Failure.self) { try machine.run("/box/bin/tool", []) }
      #expect(throws: FixedMachine.Failure.self) { try machine.createFolder("/box/new folder") }

      let lines = try MachineLogFile.lines(log)
      #expect(lines.filter { $0.contains("run") }.count == 1)
      #expect(lines.filter { $0.contains("createFolder") }.count == 1)
    }
  }

  // MARK: Results pass through

  @Test func runPassesItsArgumentsToTheBaseAndReturnsItsResult() throws {
    try withLog { log in
      let base = FixedMachine()

      let result = try LoggedMachine(base, log: MachineLog(path: log)).run(
        "/box/bin/tool", ["a", "b"], env: ["KEY": "value"], input: Data("typed".utf8), timeout: 2.5)

      #expect(result.status == FixedMachine.result.status)
      #expect(result.stdout == FixedMachine.result.stdout)
      #expect(result.stderr == FixedMachine.result.stderr)
      #expect(base.calls == [#"run /box/bin/tool ["a", "b"] ["KEY": "value"] typed 2.5"#])
    }
  }

  @Test func runPassesAMissingEnvironmentInputAndTimeoutAsMissing() throws {
    try withLog { log in
      let base = FixedMachine()

      _ = try LoggedMachine(base, log: MachineLog(path: log)).run(
        "/box/bin/tool", [], env: nil, input: nil, timeout: nil)

      #expect(base.calls == ["run /box/bin/tool [] [:] nil -1.0"])
    }
  }

  @Test func theFileMembersReturnWhatTheBaseReturns() throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(), log: MachineLog(path: log))

      #expect(machine.read("/box/file.jsonl", from: 12, count: 34) == FixedMachine.data)
      #expect(machine.size("/box/file.jsonl") == 4096)
      #expect(machine.exists("/box/file.jsonl"))
      #expect(machine.isFolder("/box/folder"))
      #expect(machine.modified("/box/file.jsonl") == FixedMachine.date)
      #expect(machine.list("/box/folder") == FixedMachine.names)
    }
  }

  /// A logged machine must not turn "can't read" into an answer.
  @Test func theFileMembersReturnTheBasesMissingAnswers() throws {
    try withLog { log in
      let machine = LoggedMachine(FixedMachine(fails: true), log: MachineLog(path: log))

      #expect(machine.read("/box/file.jsonl", from: 0, count: nil) == nil)
      #expect(machine.size("/box/file.jsonl") == nil)
      #expect(!machine.exists("/box/file.jsonl"))
      #expect(!machine.isFolder("/box/folder"))
      #expect(machine.modified("/box/file.jsonl") == nil)
      #expect(machine.list("/box/folder").isEmpty)
    }
  }

  @Test func readPassesItsOffsetAndCountToTheBase() throws {
    try withLog { log in
      let base = FixedMachine()
      let machine = LoggedMachine(base, log: MachineLog(path: log))

      _ = machine.read("/box/file.jsonl", from: 12, count: 34)
      _ = machine.read("/box/file.jsonl", from: 0, count: nil)

      #expect(base.calls == ["read /box/file.jsonl 12 34", "read /box/file.jsonl 0 -1"])
    }
  }

  @Test func signalPassesThePidAndTheSignalToTheBase() throws {
    try withLog { log in
      let base = FixedMachine()

      LoggedMachine(base, log: MachineLog(path: log)).signal(4242, SIGTERM)

      #expect(base.calls == ["signal 4242 \(SIGTERM)"])
    }
  }
}
