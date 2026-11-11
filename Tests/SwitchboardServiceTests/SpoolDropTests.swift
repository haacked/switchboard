import CryptoKit
import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func eventId(_ n: Int) -> String {
  String(format: "%020d-4242-%04x", 1_700_000_000_000_000_000 + n, n % 65_536)
}

/// One spool line as the shim writes it, with its newline.
private func line(_ n: Int, session: String = "s1", padding: Int = 0) -> Data {
  let payload: JSON = [
    "hook_event_name": "Notification", "message": .string("event \(n) ✓" + String(repeating: "x", count: padding)),
  ]
  let fields: JSON = ["v": 1, "id": .string(eventId(n)), "session": .string(session), "payload": payload]
  return Data((fields.text + "\n").utf8)
}

/// About 8 MB of spool lines, which take the shim long enough to rewrite that another process can overlap it.
private func largePrefix() -> Data {
  var data = Data()
  for n in 0..<20_000 { data.append(line(n, padding: 300)) }
  return data
}

/// A folder that stands in for a host's home, with the shim that sbd writes in `.sb/bin/sb-shim` and a spool in
/// `.sb/spool.jsonl`. HOME, SB_HOME, and the shim's own folder all lead to the same `.sb`.
private final class DropBench {
  let home: String
  let folder: String
  let shim: String
  let python: String

  init() throws {
    var template = Array("/tmp/sb-drop.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
    home = String(cString: dir)
    folder = "\(home)/.sb"
    shim = "\(folder)/bin/sb-shim"
    python = try #require(findExecutable("python3"), "python3 is not installed")
    try FileManager.default.createDirectory(atPath: "\(folder)/bin", withIntermediateDirectories: true)
    try Data(BoxShim.source.utf8).write(to: URL(fileURLWithPath: shim))
  }

  func close() { try? FileManager.default.removeItem(atPath: home) }

  var spoolPath: String { "\(folder)/spool.jsonl" }
  var lockPath: String { "\(folder)/spool.lock" }
  /// The bytes of the spool, or none when the file is missing.
  var spool: Data { FileManager.default.contents(atPath: spoolPath) ?? Data() }

  func write(_ data: Data) throws { try data.write(to: URL(fileURLWithPath: spoolPath)) }

  func append(_ data: Data) throws {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: spoolPath))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  var environment: [String: String] { ["PATH": "/usr/bin:/bin", "HOME": home, "SB_HOME": folder] }

  /// Runs `sb-shim spool-drop` with the arguments as given and waits for it.
  @discardableResult
  func drop(arguments: [String]) throws -> CommandResult {
    try runCommand(python, [shim, "spool-drop"] + arguments, env: environment, timeout: 30)
  }

  /// Runs `sb-shim spool-drop <count> <sha256 of the bytes>`, as sbd does for a prefix that it read.
  @discardableResult
  func drop(_ prefix: Data, count: Int? = nil) throws -> CommandResult {
    try drop(arguments: [String(count ?? prefix.count), sha256(prefix)])
  }

  /// Starts the shim and returns at once.
  func start(_ arguments: [String], input: Data = Data(), session: String = "s1") throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = [shim] + arguments
    p.environment = environment.merging(["SB_SESSION_ID": session]) { $1 }
    let stdin = Pipe()
    p.standardInput = stdin
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
    return p
  }

  /// Whether the process ended within the seconds.
  func ended(_ p: Process, within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while p.isRunning && Date() < deadline { usleep(10_000) }
    return !p.isRunning
  }
}

private func withBench(_ body: (DropBench) throws -> Void) throws {
  let b = try DropBench()
  defer { b.close() }
  try body(b)
}

/// Lines inside the prefix that are not spool lines.
private let unreadable: [(name: String, bytes: Data)] = [
  ("text that is not JSON", Data("not json\n".utf8)),
  ("an empty line", Data("\n".utf8)),
  ("a JSON array", Data("[1,2]\n".utf8)),
  ("another version", Data("{\"v\":2,\"id\":\"\(eventId(2))\",\"session\":\"s1\",\"payload\":{}}\n".utf8)),
  ("an id that is not well formed", Data("{\"v\":1,\"id\":\"12-1-zz\",\"session\":\"s1\",\"payload\":{}}\n".utf8)),
  ("no session", Data("{\"v\":1,\"id\":\"\(eventId(2))\",\"payload\":{}}\n".utf8)),
  ("bytes that are not UTF-8", Data([0xff, 0xfe, 0x7b, 0x0a])),
]

/// `sb-shim spool-drop <bytes> <sha256>`, the destructive half of the spool cut. It takes the spool lock, checks
/// that the file still starts with bytes of that hash, and rewrites the file without them. It refuses, and removes
/// nothing, on a mismatch, an unreadable line inside the prefix, or any error. Each test asserts the exact bytes
/// of the file afterwards.
@Suite struct SpoolDropTests {
  // MARK: The drop

  @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 3])
  func theDropRemovesExactlyThePrefixAndKeepsTheRest(lines: Int) throws {
    try withBench { b in
      let all = [line(1), line(2), line(3), line(4)]
      try b.write(all.reduce(Data(), +))
      let prefix = all.prefix(lines).reduce(Data(), +)

      let r = try b.drop(prefix)

      #expect(r.status == 0, "\(r.stderr)")
      #expect(b.spool == all.dropFirst(lines).reduce(Data(), +))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDropOfTheWholeSpoolLeavesAnEmptySpool() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(all)

      #expect(r.status == 0, "\(r.stderr)")
      #expect(b.spool == Data())
    }
  }

  /// A line that the shim is still writing has no newline yet. It is behind the prefix, and its bytes stay.
  @Test(.timeLimit(.minutes(1)))
  func theDropKeepsATornLastLineByteForByte() throws {
    try withBench { b in
      let torn = Data(line(3).dropLast(7))
      try b.write(line(1) + line(2) + torn)

      try b.drop(line(1) + line(2))

      #expect(b.spool == torn)
    }
  }

  /// The shim on the box appended a line after sbd read the spool. The file still starts with the bytes that sbd
  /// read, so the drop removes those and keeps the new line.
  @Test(.timeLimit(.minutes(1)))
  func aLineAppendedAfterSbdReadTheSpoolIsStillThereAfterTheDrop() throws {
    try withBench { b in
      let read = line(1) + line(2)
      try b.write(read)
      try b.append(line(3))

      let r = try b.drop(read)

      #expect(r.status == 0, "\(r.stderr)")
      #expect(b.spool == line(3))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHookAfterADropAppendsBehindTheLinesThatStayed() throws {
    try withBench { b in
      try b.write(line(1) + line(2))
      try b.drop(line(1))

      let hook = try b.start(["hook"], input: Data(#"{"hook_event_name":"Stop","probe":"after"}"#.utf8))
      try #require(b.ended(hook, within: 10))

      let parsed = Spool.parse(b.spool)
      #expect(b.spool.starts(with: line(2)))
      #expect(parsed.firstUnreadable == nil)
      #expect(parsed.lines.map { $0.payload["probe"]?.string } == [nil, "after"])
    }
  }

  // MARK: A mismatch removes nothing

  @Test(.timeLimit(.minutes(1)))
  func aHashOfOtherBytesRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: [String(line(1).count), sha256(line(2))])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  /// The count and the hash are of the same length of bytes, with one byte different from the file's.
  @Test(.timeLimit(.minutes(1)))
  func aPrefixThatDiffersFromTheFileInOneByteRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)
      var changed = line(1)
      changed[changed.count - 3] ^= 0x01

      let r = try b.drop(changed)

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  /// Another cut ran between sbd's read and this one, so the file no longer starts with what sbd read.
  @Test(.timeLimit(.minutes(1)))
  func aFileWhoseStartChangedAfterSbdReadItRemovesNothing() throws {
    try withBench { b in
      let read = line(1) + line(2)
      try b.write(line(2) + line(3))

      let r = try b.drop(read)

      #expect(r.status != 0)
      #expect(b.spool == line(2) + line(3))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aFileShorterThanTheCountRemovesNothing() throws {
    try withBench { b in
      try b.write(line(1))

      let r = try b.drop(line(1) + line(2))

      #expect(r.status != 0)
      #expect(b.spool == line(1))
    }
  }

  /// The hash matches the first bytes of the file, and the count names more bytes than were hashed.
  @Test(.timeLimit(.minutes(1)))
  func aCountThatDoesNotMatchTheHashedBytesRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2) + line(3)
      try b.write(all)

      let r = try b.drop(arguments: [String((line(1) + line(2)).count), sha256(line(1))])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["", "0", "abc", String(repeating: "0", count: 64), "sha256:"])
  func aHashThatIsNotTheHashOfThePrefixRemovesNothing(hash: String) throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: [String(line(1).count), hash])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  // MARK: The prefix must be whole spool lines

  @Test(.timeLimit(.minutes(1)))
  func aZeroByteDropLeavesTheFileAsItWas() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      try b.drop(Data())

      #expect(b.spool == all)
    }
  }

  /// The hash is right, and the prefix ends inside a line. The drop would leave half a line at the start.
  @Test(.timeLimit(.minutes(1)), arguments: [1, 7, -1])
  func aPrefixThatEndsInsideALineRemovesNothing(offset: Int) throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)
      let count = offset > 0 ? offset : line(1).count + line(2).count + offset

      let r = try b.drop(Data(all.prefix(count)))

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  /// The hash is right, and the prefix holds a line that is not a spool line. sbd never recorded such a line.
  @Test(.timeLimit(.minutes(1)), arguments: unreadable.indices)
  func aPrefixThatHoldsAnUnreadableLineRemovesNothing(shape: Int) throws {
    try withBench { b in
      let (name, bad) = unreadable[shape]
      let all = line(1) + bad + line(3)
      try b.write(all)

      let r = try b.drop(line(1) + bad)

      #expect(r.status != 0, "\(name)")
      #expect(b.spool == all, "\(name)")
    }
  }

  /// Lines that Python's JSON reader takes more loosely than sbd's. sbd never recorded such a line.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "{\"v\":true,\"id\":\"01700000000000000002-4242-0002\",\"session\":\"s1\",\"payload\":{}}\n",
      "{\"v\":1,\"id\":\"99999999999999999999-4242-0002\",\"session\":\"s1\",\"payload\":{}}\n",
      "{\"v\":1,\"id\":\"01700000000000000002-12345678901-0002\",\"session\":\"s1\",\"payload\":{}}\n",
      "{\"v\":1,\"id\":\"01700000000000000002-4242-0002\\n\",\"session\":\"s1\",\"payload\":{}}\n",
      "{\"v\":1,\"id\":\"01700000000000000002-4242-0002\",\"session\":\"s1\",\"payload\":[]}\n",
      "{\"v\":1,\"id\":\"٠١٧٠٠٠٠٠٠٠٠٠٠٠٠٠٠٠٠٠٠٢-4242-0002\",\"session\":\"s1\",\"payload\":{}}\n",
    ])
  func aPrefixThatHoldsALineThatOnlyALooseReaderTakesRemovesNothing(bad: String) throws {
    try withBench { b in
      let all = line(1) + Data(bad.utf8) + line(3)
      try b.write(all)

      let r = try b.drop(line(1) + Data(bad.utf8))

      #expect(r.status != 0, "\(bad)")
      #expect(b.spool == all, "\(bad)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHashInUppercaseRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: [String(line(1).count), sha256(line(1)).uppercased()])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  /// The drop writes the kept lines to a file beside the spool first. A link at that name leads to another file,
  /// which the drop must not write.
  @Test(.timeLimit(.minutes(1)))
  func aLinkAtTheNameOfTheDropsOwnFileIsNotWrittenThrough() throws {
    try withBench { b in
      try b.write(line(1) + line(2))
      let other = "\(b.home)/other.txt"
      try Data("keep me\n".utf8).write(to: URL(fileURLWithPath: other))
      try FileManager.default.createSymbolicLink(atPath: "\(b.spoolPath).drop", withDestinationPath: other)

      let r = try b.drop(line(1))

      #expect(FileManager.default.contents(atPath: other) == Data("keep me\n".utf8))
      #expect(r.status == 0, "\(r.stderr)")
      #expect(b.spool == line(2))
    }
  }

  /// The spool's name is a link to a file elsewhere. The drop replaces the link and leaves that file as it was.
  @Test(.timeLimit(.minutes(1)))
  func aSpoolThatIsALinkLeavesTheFileThatItLeadsToAsItWas() throws {
    try withBench { b in
      let other = "\(b.home)/elsewhere.jsonl"
      let all = line(1) + line(2)
      try all.write(to: URL(fileURLWithPath: other))
      try FileManager.default.createSymbolicLink(atPath: b.spoolPath, withDestinationPath: other)

      try b.drop(line(1))

      #expect(FileManager.default.contents(atPath: other) == all)
      let left = b.spool
      #expect(left == all || left == line(2), "the spool holds \(left.count) bytes")
    }
  }

  // MARK: Arguments and errors

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      [], ["12"], ["-1", "x"], ["abc", "x"], ["1.5", "x"], ["1e3", "x"], ["0x10", "x"], ["", ""], ["١٢", "x"],
    ] as [[String]])
  func argumentsThatAreNotACountAndAHashRemoveNothing(arguments: [String]) throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: arguments)

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aNegativeCountWithTheHashOfNothingRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: ["-\(line(1).count)", sha256(Data())])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anExtraArgumentRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)

      let r = try b.drop(arguments: [String(line(1).count), sha256(line(1)), "--force"])

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aDropWithNoSpoolFileFailsAndCreatesNoSpool() throws {
    try withBench { b in
      let r = try b.drop(line(1))

      #expect(r.status != 0)
      #expect(!FileManager.default.fileExists(atPath: b.spoolPath))
    }
  }

  /// The drop can't rewrite the file, so it leaves the file as it was.
  @Test(.timeLimit(.minutes(1)))
  func aDropThatCanNotWriteTheFolderRemovesNothing() throws {
    try withBench { b in
      let all = line(1) + line(2)
      try b.write(all)
      try Data().write(to: URL(fileURLWithPath: b.lockPath))
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: b.spoolPath)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: b.folder)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.folder) }

      let r = try b.drop(line(1))

      #expect(r.status != 0)
      #expect(b.spool == all)
    }
  }

  /// The hook's contract stays: it exits 0 and prints nothing whatever happens.
  @Test(.timeLimit(.minutes(1)))
  func theHookStillExitsZeroAndPrintsNothingOnAFailure() throws {
    try withBench { b in
      let r = try runCommand(b.python, [b.shim, "hook"], env: b.environment, input: Data("not json".utf8), timeout: 20)

      #expect(r.status == 0)
      #expect(r.stdout.isEmpty)
    }
  }

  // MARK: The lock

  /// A hook holds the spool lock while it appends. The drop waits for the lock, so it never rewrites the file
  /// around a line that is half written.
  @Test(.timeLimit(.minutes(1)))
  func theDropWaitsForTheSpoolLockAndKeepsTheLineWrittenUnderIt() throws {
    try withBench { b in
      let read = line(1) + line(2)
      try b.write(read)
      let lock = open(b.lockPath, O_CREAT | O_RDWR, 0o600)
      try #require(lock >= 0)
      defer { close(lock) }
      try #require(flock(lock, LOCK_EX) == 0)

      let drop = try b.start(["spool-drop", String(read.count), sha256(read)])
      let endedUnderTheLock = b.ended(drop, within: 1.5)
      let whileLocked = b.spool
      try b.append(line(3))
      try #require(flock(lock, LOCK_UN) == 0)
      try #require(b.ended(drop, within: 20), "the drop did not finish after the lock was released")

      #expect(!endedUnderTheLock, "the drop did not wait for the spool lock")
      #expect(whileLocked == read)
      #expect(drop.terminationStatus == 0)
      #expect(b.spool == line(3))
    }
  }

  /// Hooks append while the drop runs. Every line that a hook wrote is in the file afterwards, whole.
  @Test(.timeLimit(.minutes(2)))
  func hooksThatAppendWhileTheDropRunsLoseNoLine() throws {
    try withBench { b in
      // A large prefix makes the rewrite take long enough for the hooks to overlap it.
      let read = largePrefix()
      try b.write(read + line(70_000))
      let markers = (0..<12).map { "during-\($0)" }
      func hook(_ marker: String) throws -> Process {
        try b.start(["hook"], input: Data(#"{"hook_event_name":"Notification","probe":"\#(marker)"}"#.utf8))
      }

      var running = try markers.prefix(4).map(hook)
      let drop = try b.start(["spool-drop", String(read.count), sha256(read)])
      running += try markers.dropFirst(4).map(hook)
      for p in running + [drop] { try #require(b.ended(p, within: 60)) }

      let after = b.spool
      let parsed = Spool.parse(after)
      #expect(drop.terminationStatus == 0)
      #expect(after.starts(with: line(70_000)), "the line behind the prefix is not first in the file")
      #expect(parsed.firstUnreadable == nil, "a line is torn at byte \(parsed.firstUnreadable ?? -1)")
      #expect(parsed.complete == after.count)
      #expect(parsed.lines.count == 1 + markers.count)
      #expect(Set(parsed.lines.compactMap { $0.payload["probe"]?.string }) == Set(markers))
    }
  }

  /// The link can drop while the drop runs, which ends the command at any point. The file is then the one from
  /// before or the one without the prefix, never a part of either.
  @Test(.timeLimit(.minutes(3)), arguments: [0, 20, 40, 60, 80, 120, 160, 250])
  func aDropThatIsKilledLeavesTheWholeFileOrTheFileWithoutThePrefix(milliseconds: Int) throws {
    try withBench { b in
      let read = largePrefix()
      let rest = line(70_000) + line(70_001)
      try b.write(read + rest)

      let drop = try b.start(["spool-drop", String(read.count), sha256(read)])
      usleep(UInt32(milliseconds) * 1_000)
      kill(drop.processIdentifier, SIGKILL)
      try #require(b.ended(drop, within: 10))

      let after = b.spool
      #expect(after == rest || after == read + rest, "the spool holds \(after.count) bytes after the kill")
    }
  }

  /// A drop that was killed left its lock, which the kernel released. The next drop works.
  @Test(.timeLimit(.minutes(1)))
  func aDropAfterAKilledDropStillWorks() throws {
    try withBench { b in
      let read = largePrefix()
      try b.write(read + line(70_000))
      let killed = try b.start(["spool-drop", String(read.count), sha256(read)])
      usleep(60_000)
      kill(killed.processIdentifier, SIGKILL)
      try #require(b.ended(killed, within: 10))
      let left = b.spool
      try #require(left == line(70_000) || left == read + line(70_000))

      if left != line(70_000) { try b.drop(read) }

      // Swift Testing computes a difference of the two sides of a failed `==`, which takes minutes on 8 MB.
      let cut = b.spool == line(70_000)
      #expect(cut, "the spool holds \(b.spool.count) bytes after the second drop")
    }
  }
}
