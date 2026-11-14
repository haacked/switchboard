import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct LocalMachineTests {
  let machine = LocalMachine()

  private func withTempFolder(_ body: (String) throws -> Void) throws {
    let folder = NSTemporaryDirectory() + "sb-machine-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try body(folder)
  }

  private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  private func withSleepingChild(_ body: (Process) throws -> Void) throws {
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

  @Test(.timeLimit(.minutes(1))) func runReturnsStatusStdoutAndStderr() throws {
    let r = try machine.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])

    #expect(r.status == 3)
    #expect(r.stdout == "out\n")
    #expect(r.stderr == "err\n")
  }

  @Test(.timeLimit(.minutes(1))) func runReplacesTheEnvironmentWhenEnvIsSet() throws {
    let r = try machine.run(
      "/usr/bin/env", [], env: ["SB_MACHINE_TEST": "bar"], input: nil, timeout: nil)

    let lines = r.stdout.split(separator: "\n").map(String.init)
    #expect(lines.contains("SB_MACHINE_TEST=bar"))
    #expect(!lines.contains { $0.hasPrefix("PATH=") })
  }

  @Test(.timeLimit(.minutes(1))) func runKeepsTheEnvironmentWhenEnvIsNil() throws {
    let r = try machine.run("/usr/bin/env", [])

    #expect(r.stdout.split(separator: "\n").contains { $0.hasPrefix("PATH=") })
  }

  @Test(.timeLimit(.minutes(1))) func runWritesInputToStdin() throws {
    let r = try machine.run(
      "/bin/cat", [], env: nil, input: Data("line one\nline two\n".utf8), timeout: nil)

    #expect(r.status == 0)
    #expect(r.stdout == "line one\nline two\n")
  }

  @Test(arguments: [
    (UInt64(0), Int?.none, "0123456789"),
    (UInt64(4), Int?.none, "456789"),
    (UInt64(2), Int?.some(3), "234"),
    (UInt64(0), Int?.some(0), ""),
    (UInt64(8), Int?.some(100), "89"),
    (UInt64(10), Int?.none, ""),
    (UInt64(10), Int?.some(5), ""),
    (UInt64(500), Int?.none, ""),
    (UInt64(500), Int?.some(5), ""),
  ])
  func readReturnsTheBytesFromOffsetUpToCount(offset: UInt64, count: Int?, expected: String) throws {
    try withTempFolder { folder in
      let path = folder + "/digits.txt"
      try write("0123456789", to: path)

      let data = machine.read(path, from: offset, count: count)

      #expect(data == Data(expected.utf8))
    }
  }

  @Test func readReturnsNilForAMissingFile() throws {
    try withTempFolder { folder in
      #expect(machine.read(folder + "/missing", from: 0, count: nil) == nil)
      #expect(machine.read(folder + "/missing", from: 0, count: 4) == nil)
    }
  }

  @Test func textReturnsTheWholeFile() throws {
    try withTempFolder { folder in
      let path = folder + "/note.txt"
      try write("héllo\nwörld ✓\n", to: path)

      #expect(machine.text(path) == "héllo\nwörld ✓\n")
    }
  }

  @Test func textReturnsNilForAMissingFile() throws {
    try withTempFolder { folder in
      #expect(machine.text(folder + "/missing") == nil)
    }
  }

  @Test func sizeCountsBytesNotCharacters() throws {
    try withTempFolder { folder in
      let path = folder + "/note.txt"
      try write("é✓a", to: path)
      let empty = folder + "/empty"
      try write("", to: empty)

      #expect(machine.size(path) == 6)
      #expect(machine.size(empty) == 0)
    }
  }

  @Test func sizeReturnsNilForAMissingFile() throws {
    try withTempFolder { folder in
      #expect(machine.size(folder + "/missing") == nil)
    }
  }

  @Test func existsIsTrueForAFileAndAFolderAndFalseForAMissingPath() throws {
    try withTempFolder { folder in
      let file = folder + "/file"
      try write("x", to: file)

      #expect(machine.exists(file))
      #expect(machine.exists(folder))
      #expect(!machine.exists(folder + "/missing"))
    }
  }

  @Test func isFolderIsTrueOnlyForAFolder() throws {
    try withTempFolder { folder in
      let file = folder + "/file"
      try write("x", to: file)

      #expect(machine.isFolder(folder))
      #expect(!machine.isFolder(file))
      #expect(!machine.isFolder(folder + "/missing"))
    }
  }

  @Test func modifiedReturnsWhenTheFileLastChanged() throws {
    try withTempFolder { folder in
      let path = folder + "/file"
      try write("x", to: path)
      let changed = Date(timeIntervalSince1970: 1_700_000_000)
      try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: path)

      #expect(machine.modified(path) == changed)
    }
  }

  @Test func modifiedReturnsNilForAMissingFile() throws {
    try withTempFolder { folder in
      #expect(machine.modified(folder + "/missing") == nil)
    }
  }

  @Test func listReturnsTheNamesInTheFolder() throws {
    try withTempFolder { folder in
      try write("a", to: folder + "/a.txt")
      try write("b", to: folder + "/b.txt")
      try FileManager.default.createDirectory(
        atPath: folder + "/sub", withIntermediateDirectories: false)

      #expect(machine.list(folder).sorted() == ["a.txt", "b.txt", "sub"])
    }
  }

  @Test func listReturnsNothingForAnEmptyMissingOrNonFolderPath() throws {
    try withTempFolder { folder in
      let file = folder + "/file"
      try write("x", to: file)

      #expect(machine.list(file) == [])
      #expect(machine.list(folder + "/missing") == [])
      try FileManager.default.removeItem(atPath: file)
      #expect(machine.list(folder) == [])
    }
  }

  @Test func createFolderCreatesTheMissingFoldersAboveIt() throws {
    try withTempFolder { folder in
      let path = folder + "/a/b/c"

      try machine.createFolder(path)

      #expect(machine.isFolder(path))
    }
  }

  @Test func createFolderSucceedsWhenTheFolderExistsAndKeepsItsContents() throws {
    try withTempFolder { folder in
      try write("x", to: folder + "/file")

      try machine.createFolder(folder)

      #expect(machine.list(folder) == ["file"])
    }
  }

  @Test(.timeLimit(.minutes(1))) func signalEndsTheProcessWithThatPid() throws {
    try withSleepingChild { child in
      machine.signal(Int(child.processIdentifier), SIGTERM)
      child.waitUntilExit()

      #expect(child.terminationReason == .uncaughtSignal)
      #expect(child.terminationStatus == SIGTERM)
    }
  }

  @Test(arguments: [0, -1, -2, Int(Int32.min), Int.min, Int(Int32.max) + 1, Int.max])
  func isValidPidRefusesANumberThatIsNotOneProcess(pid: Int) {
    #expect(!Processes.isValidPid(pid))
  }

  @Test(arguments: [1, Int(Int32.max)])
  func isValidPidAcceptsTheEnds(pid: Int) {
    #expect(Processes.isValidPid(pid))
  }

  @Test(.timeLimit(.minutes(1))) func signalSendsNothingForTheNegatedPidOfAChild() throws {
    try withSleepingChild { child in
      machine.signal(-Int(child.processIdentifier), SIGTERM)
      Thread.sleep(forTimeInterval: 0.2)

      #expect(child.isRunning)
    }
  }

  @Test(.timeLimit(.minutes(1))) func signalSendsNothingForAPidAboveInt32Max() throws {
    try withSleepingChild { child in
      let wrapsToChild = Int(UInt32.max) + 1 + Int(child.processIdentifier)

      machine.signal(Int(Int32.max) + 1, SIGTERM)
      machine.signal(wrapsToChild, SIGTERM)
      machine.signal(Int.max, SIGTERM)
      Thread.sleep(forTimeInterval: 0.2)

      #expect(child.isRunning)
    }
  }
}

/// A machine whose files and command output exist only in memory, so a read
/// that reaches this Mac's disk finds nothing.
private struct MemoryMachine: Machine {
  var files: [String: Data] = [:]
  var stdout = ""

  func run(
    _ executable: String, _ args: [String], env: [String: String]?, input: Data?, timeout: Double?
  ) throws -> CommandResult {
    CommandResult(status: 0, stdout: stdout, stderr: "")
  }

  func read(_ path: String, from offset: UInt64, count: Int?) -> Data? {
    guard let data = files[path] else { return nil }
    let rest = data.dropFirst(Int(min(offset, UInt64(data.count))))
    return Data(count.map { rest.prefix($0) } ?? rest)
  }

  func size(_ path: String) -> UInt64? { files[path].map { UInt64($0.count) } }
  func exists(_ path: String) -> Bool { files[path] != nil }
  func isFolder(_ path: String) -> Bool { files.keys.contains { $0.hasPrefix(path + "/") } }
  func modified(_ path: String) -> Date? { nil }

  func list(_ folder: String) -> [String] {
    Array(
      Set(
        files.keys.filter { $0.hasPrefix(folder + "/") }.compactMap {
          $0.dropFirst(folder.count + 1).split(separator: "/").first.map(String.init)
        }))
  }

  func createFolder(_ path: String) throws {}
  func signal(_ pid: Int, _ signal: Int32) {}
}

@Suite struct MachineReadTests {
  private let id = "0b6e4c2a-5d1f-4e8b-9a3c-7f2d1e6b8a40"
  private let account = "/box/home/.claude"

  private func line(_ type: String, _ text: String) -> String {
    #"{"type":"\#(type)","timestamp":"2026-10-25T10:00:04.000Z","message":{"content":"\#(text)"}}"#
  }

  private func machine(folder: String, lines: [String]) -> MemoryMachine {
    MemoryMachine(files: [
      "\(account)/projects/\(folder)/\(id).jsonl": Data((lines.joined(separator: "\n") + "\n").utf8)
    ])
  }

  @Test func findsATranscriptThatOnlyTheMachineHolds() {
    let machine = machine(folder: "-box-work", lines: [])
    let path = "\(account)/projects/-box-work/\(id).jsonl"

    #expect(Transcript.find(id, account: account, cwd: "/box/work", on: machine) == path)
    #expect(Transcript.find(id, account: account, cwd: "/box/other", on: machine) == path, "the folder search")
    #expect(Transcript.find(id, account: account, cwd: "/box/work") == nil, "this Mac has no such file")
  }

  @Test func readsTheTailAndTheMessagesFromTheMachine() {
    let machine = machine(folder: "-box-work", lines: [line("user", "Fix it."), line("assistant", "Done.")])
    let path = "\(account)/projects/-box-work/\(id).jsonl"

    #expect(Transcript.tail(path, on: machine).lastReply == "Done.")
    #expect(Transcript.messages(path, limit: 5, on: machine).map(\.text) == ["Fix it.", "Done."])
    #expect(Transcript.tail(path) == TranscriptTail(), "this Mac has no such file")
  }

  @Test func looksForAUserMessageFromTheOffsetOnTheMachine() {
    let first = line("user", "Fix it.")
    let machine = machine(folder: "-box-work", lines: [first, line("assistant", "Done.")])
    let path = "\(account)/projects/-box-work/\(id).jsonl"

    #expect(Transcript.hasUserMessage(path, holding: "Fix it.", from: 0, on: machine))
    #expect(!Transcript.hasUserMessage(path, holding: "Fix it.", from: UInt64(first.utf8.count + 1), on: machine))
    #expect(!Transcript.hasUserMessage(path, holding: "Fix it.", from: 1 << 20, on: machine), "past the end")
  }

  @Test func listsTheProcessesThatTheMachinesPsPrints() {
    let machine = MemoryMachine(stdout: "  7     1     7 /sbin/launchd\n 42     7    42 claude --resume x\n")

    let processes = ProcessTable.readLocal(on: machine)

    #expect(processes.children(of: 7).map(\.pid) == [42])
    #expect(processes.command(of: 42) == "claude --resume x")
  }
}
