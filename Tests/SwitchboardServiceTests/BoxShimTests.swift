import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// One run of the shim.
private final class ShimRun {
  let process = Process()
  private let output = Pipe()
  private let ended = DispatchSemaphore(value: 0)
  let started = Date()
  private(set) var finished: Date?

  init(python: String, shim: String, arguments: [String], environment: [String: String], input: Data) throws {
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [shim] + arguments
    process.environment = environment
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [self] _ in
      finished = Date()
      ended.signal()
    }
    try process.run()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
  }

  var running: Bool { process.isRunning }

  /// The exit status and what the shim printed, or nil when it still runs after the seconds.
  func wait(_ seconds: Double) -> (status: Int32, stdout: String, seconds: Double)? {
    guard ended.wait(timeout: .now() + seconds) == .success else { return nil }
    ended.signal()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, printed, (finished ?? Date()).timeIntervalSince(started))
  }

  func end() {
    if process.isRunning { process.terminate() }
  }
}

/// A folder that stands in for the box's `~/.sb`, with the shim in `bin/sb-shim` and, when asked, a listener at
/// `sbd.sock` that the test owns. The folder is under /tmp, because a Unix socket path can't exceed 103 bytes.
private final class ShimBench {
  let home: String
  let shim: String
  let python: String
  private(set) var listener: Int32 = -1
  private var runs: [ShimRun] = []

  /// A test answers a shim that has already gone. macOS refuses SO_NOSIGPIPE on a socket whose peer closed, so
  /// that write would raise SIGPIPE and end the test run.
  private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

  enum Socket {
    /// A socket that the test listens on.
    case listening
    /// No file at the path.
    case missing
    /// A socket file that nothing listens on, as a dropped forward leaves.
    case stale
  }

  init(_ socket: Socket = .listening) throws {
    _ = ShimBench.ignoreSIGPIPE
    var template = Array("/tmp/sb-shim.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw APIError("mkdtemp failed") }
    home = String(cString: dir)
    shim = "\(home)/bin/sb-shim"
    python = try #require(findExecutable("python3"), "python3 is not installed")
    try FileManager.default.createDirectory(atPath: "\(home)/bin", withIntermediateDirectories: true)
    try Data(BoxShim.source.utf8).write(to: URL(fileURLWithPath: shim))
    switch socket {
    case .listening: listener = try UnixSocket.listen(path: socketPath)
    case .stale: Darwin.close(try UnixSocket.listen(path: socketPath))
    case .missing: break
    }
  }

  func close() {
    runs.forEach { $0.end() }
    if listener >= 0 { Darwin.close(listener) }
    try? FileManager.default.removeItem(atPath: home)
  }

  var socketPath: String { "\(home)/sbd.sock" }
  var spoolPath: String { "\(home)/spool.jsonl" }
  var spool: Data { FileManager.default.contents(atPath: spoolPath) ?? Data() }

  /// Starts `sb-shim hook` with the payload on stdin. A nil session leaves `SB_SESSION_ID` out.
  func hook(_ payload: Data, session: String? = "s1", sbHome: String?? = nil) throws -> ShimRun {
    var env = ["PATH": "/usr/bin:/bin", "HOME": home]
    if let session { env["SB_SESSION_ID"] = session }
    if let folder = sbHome ?? .some(home) { env["SB_HOME"] = folder }
    let run = try ShimRun(python: python, shim: shim, arguments: ["hook"], environment: env, input: payload)
    runs.append(run)
    return run
  }

  func hook(_ payload: JSON, session: String? = "s1") throws -> ShimRun {
    try hook(Data(payload.text.utf8), session: session)
  }

  /// The next connection to the listener, or nil when none arrives within the seconds.
  func accept(_ seconds: Double = 5) -> Int32? {
    var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&waiting, 1, Int32(seconds * 1000)) == 1 else { return nil }
    let fd = Darwin.accept(listener, nil, nil)
    guard fd >= 0 else { return nil }
    UnixSocket.configure(fd, timeout: 5)
    return fd
  }

  /// The request that the shim sent on the connection.
  func request(_ fd: Int32) throws -> JSON {
    var reader = UnixSocket.LineReader(fd: fd)
    let line = try #require(try reader.next(), "the shim closed the connection before it sent a request")
    return try #require(JSON.parse(String(decoding: line, as: UTF8.self)), "the request is not JSON")
  }
}

private func withBench(_ socket: ShimBench.Socket = .listening, _ body: (ShimBench) throws -> Void) throws {
  let b = try ShimBench(socket)
  defer { b.close() }
  try body(b)
}

/// A hook payload of the kind, shaped like claude's.
private func payload(_ kind: String, tool: String? = nil, _ more: [String: JSON] = [:]) -> JSON {
  var fields: [String: JSON] = [
    "hook_event_name": .string(kind), "session_id": "c0ffee00-0000-4000-8000-000000000001",
    "transcript_path": "/home/u/.claude/projects/-srv-repo/c0ffee00.jsonl", "permission_mode": "default",
  ]
  if let tool {
    fields["tool_name"] = .string(tool)
    fields["tool_input"] =
      tool == "AskUserQuestion"
      ? ["questions": [["question": "Which fruit?", "header": "Fruit", "options": [["label": "apple"]]]]]
      : ["command": "touch x"]
  }
  return .object(fields.merging(more) { $1 })
}

private let allow: JSON = [
  "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]
]

/// The hooks that wait for sbd's answer: a PermissionRequest, and a PreToolUse whose tool is AskUserQuestion.
private let waiting: [(kind: String, tool: String?)] = [
  ("PermissionRequest", "Bash"), ("PermissionRequest", "AskUserQuestion"), ("PermissionRequest", "Edit"),
  ("PreToolUse", "AskUserQuestion"),
]

/// The hooks that send their event and exit.
private let notWaiting: [(kind: String, tool: String?)] = [
  ("SessionStart", nil), ("SessionEnd", nil), ("UserPromptSubmit", nil), ("PreToolUse", "Bash"),
  ("PreToolUse", "Edit"), ("PostToolUse", "Bash"), ("PostToolUse", "AskUserQuestion"), ("PostToolUseFailure", "Bash"),
  ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SubagentStart", nil), ("SubagentStop", nil),
]

/// Each way the socket can have no listener, with a hook that waits and one that does not.
private let noListener: [(socket: ShimBench.Socket, kind: String, tool: String?)] = [
  (.missing, "PermissionRequest", "Bash"), (.missing, "PreToolUse", "AskUserQuestion"), (.missing, "Stop", nil),
  (.stale, "PermissionRequest", "Bash"), (.stale, "PreToolUse", "AskUserQuestion"), (.stale, "Stop", nil),
]

/// The shim that sbd writes to `~/.sb/bin/sb-shim` on a host. Each test runs it with python3 against a socket that
/// the test owns, in a folder that stands in for the host's `~/.sb`.
@Suite struct BoxShimTests {
  // MARK: The request

  @Test(.timeLimit(.minutes(1)))
  func theShimSendsAHookRequestWithItsSessionItsPayloadAndAnEventId() throws {
    try withBench { b in
      let sent = payload("Stop", ["last_assistant_message": "Done: \"x\"\nand ✓"])
      let run = try b.hook(sent, session: "abc123")
      let fd = try #require(b.accept(), "the shim did not connect to $SB_HOME/sbd.sock")
      defer { close(fd) }

      let request = try b.request(fd)

      #expect(request["op"] == "hook")
      #expect(request["args"]?["session"] == "abc123")
      #expect(request["args"]?["payload"] == sent)
      let id = try #require(request["args"]?["id"]?.string, "the request names no event id")
      let parsed = try #require(HostEventID(id), "\(id) is not an event id")
      let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
      #expect(parsed.ns <= now && now - parsed.ns < 60_000_000_000, "the id's clock is \(parsed.ns), and now is \(now)")
      #expect(Set(request.object?.keys.map { $0 } ?? []) == ["op", "args"])
      _ = run.wait(5)
    }
  }

  /// The spool line is on disk before sbd can see the request, so an event that sbd recorded is one that the spool
  /// holds.
  @Test(.timeLimit(.minutes(1)))
  func theShimSpoolsTheEventBeforeItSendsTheRequest() throws {
    try withBench { b in
      let run = try b.hook(payload("Stop"))
      let fd = try #require(b.accept())
      defer { close(fd) }

      let request = try b.request(fd)
      let spooled = Spool.parse(b.spool)

      try #require(spooled.lines.count == 1, "the spool held \(spooled.lines.count) lines when the request arrived")
      #expect(spooled.lines[0].id == HostEventID(request["args"]?["id"]?.string ?? ""))
      #expect(spooled.lines[0].session == "s1")
      #expect(spooled.lines[0].payload == request["args"]?["payload"])
      _ = run.wait(5)
    }
  }

  // MARK: A hook that waits

  @Test(.timeLimit(.minutes(1)), arguments: waiting.indices)
  func aHookThatWaitsPrintsSbdsAnswer(index: Int) throws {
    try withBench { b in
      let hook = waiting[index]
      let run = try b.hook(payload(hook.kind, tool: hook.tool))
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)

      // The answer comes when the card is answered, which can take a day.
      Thread.sleep(forTimeInterval: 2.5)
      let stillWaits = run.running
      try UnixSocket.write(fd, Data((JSON.object(["ok": true, "result": allow]).text + "\n").utf8))
      let result = try #require(run.wait(5), "the shim still runs 5 s after the answer")

      #expect(stillWaits, "\(hook.kind) for \(hook.tool ?? "no tool") did not wait for its answer")
      #expect(result.status == 0)
      #expect(JSON.parse(result.stdout) == allow, "\(result.stdout)")
    }
  }

  /// What sbd can send that is no decision. Claude Code shows a failed hook in the conversation, so the shim prints
  /// nothing and exits 0.
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      #"{"ok":true,"result":{}}"#, #"{"ok":true}"#, #"{"ok":true,"result":null}"#,
      #"{"ok":false,"error":"that session is not on mini"}"#, #"{"ok":false,"result":{"hookSpecificOutput":{}}}"#,
      "not json", #"{"ok":true,"result":{"hookSpec"#, "", "close",
    ])
  func aHookThatWaitsPrintsNothingAndExitsZeroWhenSbdGivesNoDecision(reply: String) throws {
    try withBench { b in
      let run = try b.hook(payload("PermissionRequest", tool: "Bash"))
      let fd = try #require(b.accept())
      _ = try b.request(fd)

      if reply != "close" { try UnixSocket.write(fd, Data((reply + "\n").utf8)) }
      close(fd)
      let result = try #require(run.wait(5), "the shim still runs 5 s after sbd closed the connection")

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      #expect(Spool.parse(b.spool).lines.count == 1)
    }
  }

  // MARK: A hook that does not wait

  @Test(.timeLimit(.minutes(1)), arguments: notWaiting.indices)
  func aHookThatDoesNotWaitExitsBeforeTheTestAnswers(index: Int) throws {
    try withBench { b in
      let hook = notWaiting[index]
      let sent = payload(hook.kind, tool: hook.tool)
      let run = try b.hook(sent)
      let fd = try #require(b.accept())
      defer { close(fd) }
      let request = try b.request(fd)

      // The test never answers.
      let result = try #require(run.wait(3), "\(hook.kind) for \(hook.tool ?? "no tool") waited for an answer")

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      #expect(request["args"]?["payload"] == sent)
      #expect(Spool.parse(b.spool).lines.count == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aHookThatDoesNotWaitPrintsNothingEvenWhenSbdAnswersAtOnce() throws {
    try withBench { b in
      let run = try b.hook(payload("UserPromptSubmit"))
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)
      try? UnixSocket.write(fd, Data((JSON.object(["ok": true, "result": allow]).text + "\n").utf8))

      let result = try #require(run.wait(3))

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
    }
  }

  // MARK: No listener

  @Test(.timeLimit(.minutes(1)), arguments: noListener.indices)
  func withNoListenerTheShimExitsZeroWithin3SecondsAndLeavesOneSpoolLine(index: Int) throws {
    let shape = noListener[index]
    try withBench(shape.socket) { b in
      let sent = payload(shape.kind, tool: shape.tool)

      let run = try b.hook(sent)
      let result = try #require(run.wait(3), "the shim still runs after 3 s with no listener")

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      let spooled = Spool.parse(b.spool)
      #expect(spooled.lines.map(\.session) == ["s1"])
      #expect(spooled.lines.map(\.payload) == [sent])
      #expect(spooled.firstUnreadable == nil)
      #expect(spooled.complete == b.spool.count, "the spool's last line has no newline")
    }
  }

  /// A listener that takes no connection off its queue. A hook that does not wait has nothing to wait for.
  @Test(.timeLimit(.minutes(1)))
  func aListenerThatNeverAcceptsDoesNotKeepAHookThatDoesNotWait() throws {
    try withBench { b in
      let run = try b.hook(payload("Stop"))

      let result = try #require(run.wait(3), "the shim waited for a listener that never accepted")

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty)
      #expect(Spool.parse(b.spool).lines.count == 1)
    }
  }

  // MARK: The spool

  @Test(.timeLimit(.minutes(1)))
  func eachSpoolLineIsOneVersionedLineThatParsesAsASpoolLine() throws {
    try withBench(.missing) { b in
      let tricky = payload(
        "UserPromptSubmit",
        [
          "prompt": "line one\nline two \"quoted\" \\ back \u{2028}\u{2029} ✓ 🎉 \u{0}", "null": "null", "empty": "",
          "number": "007", "nothing": .null, "nested": ["list": [1, "1", true, 1.5]],
        ])

      for sent in [payload("SessionStart"), tricky, payload("Stop")] { _ = try #require(try b.hook(sent).wait(5)) }

      let data = b.spool
      let text = try #require(String(data: data, encoding: .utf8))
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      try #require(lines.count == 4 && lines[3].isEmpty, "the spool is not three lines that each end in a newline")
      for line in lines.dropLast() {
        let json = try #require(JSON.parse(String(line)), "\(line)")
        #expect(json["v"] == 1)
        #expect(Set(json.object?.keys.map { $0 } ?? []) == ["v", "id", "session", "payload"])
      }
      let parsed = Spool.parse(data)
      #expect(parsed.firstUnreadable == nil)
      #expect(parsed.complete == data.count)
      #expect(parsed.lines.map(\.payload) == [payload("SessionStart"), tricky, payload("Stop")])
      #expect(parsed.lines.map(\.session) == ["s1", "s1", "s1"])
      #expect(parsed.lines.map(\.id) == parsed.lines.map(\.id).sorted(), "a later hook got a lower id")
      #expect(Set(parsed.lines.map(\.id)).count == 3)
      #expect(FileManager.default.fileExists(atPath: "\(b.home)/spool.lock"))
    }
  }

  /// Each line is longer than a pipe's atomic write, so a shim that wrote in pieces or without the lock would
  /// mix two lines.
  @Test(.timeLimit(.minutes(2)), arguments: [2, 12])
  func shimsThatRunAtOnceLeaveOneWholeLineEach(count: Int) throws {
    try withBench(.missing) { b in
      let sent = (0..<count).map { n in
        payload("PostToolUse", tool: "Bash", ["tool_response": .string(String(repeating: "\(n % 10)", count: 200_000))])
      }

      let runs = try sent.enumerated().map { n, one in try b.hook(one, session: "s\(n)") }
      let results = runs.map { $0.wait(30) }

      #expect(results.allSatisfy { $0?.status == 0 }, "\(results.map { $0?.status })")
      let data = b.spool
      let parsed = Spool.parse(data)
      #expect(
        parsed.firstUnreadable == nil, "a line is torn or mixed with another at byte \(parsed.firstUnreadable ?? -1)")
      #expect(parsed.complete == data.count)
      try #require(parsed.lines.count == count)
      #expect(Set(parsed.lines.map(\.id)).count == count, "two shims made the same id")
      for line in parsed.lines {
        let n = try #require(Int(line.session.dropFirst()))
        #expect(line.payload == sent[n], "the line of s\(n) holds another shim's payload")
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aSecondHookAppendsToTheSpoolAndKeepsTheFirstLine() throws {
    try withBench(.missing) { b in
      _ = try #require(try b.hook(payload("SessionStart")).wait(5))
      let first = b.spool

      _ = try #require(try b.hook(payload("Stop")).wait(5))

      #expect(b.spool.prefix(first.count) == first)
      #expect(Spool.parse(b.spool).lines.count == 2)
    }
  }

  // MARK: Nothing to send

  @Test(.timeLimit(.minutes(1)), arguments: [nil, ""] as [String?])
  func aMissingSessionIdWritesNothingAndSendsNothing(session: String?) throws {
    try withBench { b in
      let run = try b.hook(payload("Stop"), session: session)

      let result = try #require(run.wait(5))

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      #expect(b.spool.isEmpty, "the shim spooled an event that names no session")
      #expect(b.accept(0.3) == nil, "the shim sent a request that names no session")
    }
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "", "not json", "{\"hook_event_name\":", "[1, 2]", "\"text\"", #"{"hook_event_name":"Stop","x":NaN}"#,
      #"{"hook_event_name":"Stop","x":"\ud800"}"#,
    ])
  func aPayloadThatIsNotAJSONObjectWritesNothingAndSendsNothing(input: String) throws {
    try withBench { b in
      let run = try b.hook(Data(input.utf8))

      let result = try #require(run.wait(5))

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      #expect(b.spool.isEmpty)
      #expect(b.accept(0.3) == nil)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aMissingSBHomeExitsZeroAndPrintsNothing() throws {
    try withBench { b in
      let run = try b.hook(Data(payload("Stop").text.utf8), sbHome: .some(nil))

      let result = try #require(run.wait(5))

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
      #expect(b.spool.isEmpty)
      #expect(b.accept(0.3) == nil)
    }
  }

  /// A spool that the shim can't write must not fail the hook.
  @Test(.timeLimit(.minutes(1)))
  func aSpoolThatCantBeWrittenStillExitsZeroAndPrintsNothing() throws {
    try withBench(.missing) { b in
      try FileManager.default.createDirectory(atPath: b.spoolPath, withIntermediateDirectories: true)

      let result = try #require(try b.hook(payload("Stop")).wait(5))

      #expect(result.status == 0)
      #expect(result.stdout.isEmpty, "\(result.stdout)")
    }
  }
}
