import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// One run of the shim. It reads stdout and stderr while the shim runs, so a full pipe can't stall the shim.
private final class ShimRun {
  let process = Process()
  private let output = Pipe()
  private let errors = Pipe()
  private let stdin = Pipe()
  private let ended = DispatchSemaphore(value: 0)
  private let drained = DispatchGroup()
  private var printed = Data()
  private var complained = Data()
  let started = Date()
  private(set) var finished: Date?

  /// A nil `input` leaves stdin open until `send` writes it.
  convenience init(
    python: String, shim: String, arguments: [String], environment: [String: String], input: Data?,
    cwd: String? = nil
  ) throws {
    try self.init(
      executable: python, arguments: [shim] + arguments, environment: environment, input: input, cwd: cwd)
  }

  init(executable: String, arguments: [String], environment: [String: String], input: Data?, cwd: String? = nil)
    throws
  {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = errors
    process.terminationHandler = { [self] _ in
      finished = Date()
      ended.signal()
    }
    try process.run()
    drain(output) { [self] in printed = $0 }
    drain(errors) { [self] in complained = $0 }
    if let input { try send(input) }
  }

  private func drain(_ pipe: Pipe, into store: @escaping (Data) -> Void) {
    drained.enter()
    let handle = pipe.fileHandleForReading
    Thread.detachNewThread { [self] in
      store(handle.readDataToEndOfFile())
      drained.leave()
    }
  }

  /// Writes the payload to stdin and closes it.
  func send(_ input: Data) throws {
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
  }

  var running: Bool { process.isRunning }

  /// The exit status and what the shim printed, or nil when it still runs after the seconds.
  func wait(_ seconds: Double) -> (status: Int32, stdout: String, seconds: Double)? {
    guard let result = waitForBytes(seconds) else { return nil }
    return (result.status, String(decoding: result.stdout, as: UTF8.self), result.seconds)
  }

  /// The exit status and the bytes of both streams, or nil when it still runs after the seconds.
  func waitForBytes(_ seconds: Double) -> (status: Int32, stdout: Data, stderr: Data, seconds: Double)? {
    guard ended.wait(timeout: .now() + seconds) == .success else { return nil }
    ended.signal()
    drained.wait()
    return (process.terminationStatus, printed, complained, (finished ?? Date()).timeIntervalSince(started))
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

  /// Starts `sb-shim hook` with the payload on stdin. A nil payload leaves stdin open for `ShimRun.send`. A nil
  /// session leaves `SB_SESSION_ID` out.
  func hook(_ payload: Data?, session: String? = "s1", sbHome: String?? = nil) throws -> ShimRun {
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

  /// The folder that a `cli` run starts in, as claude's folder on the box.
  var work: String { "\(home)/work" }

  /// Starts `sb-shim cli <argv…>` in `work`. A nil `input` leaves stdin open, so a shim that reads it waits.
  /// A nil `sbHome` sets SB_HOME to the bench's folder, and `.some(nil)` leaves it out.
  func cli(_ argv: [String], env more: [String: String] = [:], input: Data? = nil, sbHome: String?? = nil) throws
    -> ShimRun
  {
    try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    var env = ["PATH": "/usr/bin:/bin", "HOME": home]
    if let folder = sbHome ?? .some(home) { env["SB_HOME"] = folder }
    env.merge(more) { $1 }
    let run = try ShimRun(
      python: python, shim: shim, arguments: ["cli"] + argv, environment: env, input: input, cwd: work)
    runs.append(run)
    return run
  }

  /// Starts a program with the bench's SB_HOME, as a claude on the box starts `~/.sb/bin/sb`.
  func start(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> ShimRun {
    let env = ["PATH": "/usr/bin:/bin", "HOME": home, "SB_HOME": home]
    let run = try ShimRun(executable: executable, arguments: arguments, environment: env, input: input)
    runs.append(run)
    return run
  }

  /// Answers the request on the connection with one line.
  func answer(_ fd: Int32, _ line: String) throws {
    try UnixSocket.write(fd, Data((line + "\n").utf8))
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
  /// mix two lines. A shim makes its id under the lock, so a shim without the lock could also append its line
  /// behind a line with a later id. Every shim starts and waits for its stdin, and the test then writes every
  /// stdin at once, so the shims spool at the same time.
  @Test(.timeLimit(.minutes(2)), arguments: [2, 12])
  func shimsThatRunAtOnceLeaveOneWholeLineEach(count: Int) throws {
    try withBench(.missing) { b in
      let sent = (0..<count).map { n in
        payload("PostToolUse", tool: "Bash", ["tool_response": .string(String(repeating: "\(n % 10)", count: 200_000))])
      }

      let runs = try (0..<count).map { n in try b.hook(nil, session: "s\(n)") }
      DispatchQueue.concurrentPerform(iterations: count) { n in try? runs[n].send(Data(sent[n].text.utf8)) }
      let results = runs.map { $0.wait(30) }

      #expect(results.allSatisfy { $0?.status == 0 }, "\(results.map { $0?.status })")
      let data = b.spool
      let parsed = Spool.parse(data)
      #expect(
        parsed.firstUnreadable == nil, "a line is torn or mixed with another at byte \(parsed.firstUnreadable ?? -1)")
      #expect(parsed.complete == data.count)
      try #require(parsed.lines.count == count)
      #expect(Set(parsed.lines.map(\.id)).count == count, "two shims made the same id")
      #expect(parsed.lines.map(\.id) == parsed.lines.map(\.id).sorted(), "a line is behind a line with a later id")
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

// MARK: sb on the box

/// sbd's answer to a `cli` request: the exit status and both streams in base64.
private func cliAnswer(status: Int, stdout: Data = Data(), stderr: Data = Data()) -> String {
  JSON.object([
    "ok": true,
    "result": [
      "status": .number(Double(status)), "stdout": .string(stdout.base64EncodedString()),
      "stderr": .string(stderr.base64EncodedString()),
    ],
  ]).text
}

/// The bytes of the request's `stdin`, which are none when the key is absent, or nil when it is not base64.
private func sentStdin(_ request: JSON) -> Data? {
  guard let field = request["args"]?["stdin"] else { return Data() }
  return field.string.flatMap { Data(base64Encoded: $0) }
}

/// The argv of `sb summary set` in each form that `sb` reads as that command.
private let summarySets: [[String]] = [
  ["summary", "set"], ["summary", "set", "--json"], ["summary", "--json", "set"], ["summary", "set", "s1"],
]

/// Commands that never get the box's stdin.
private let noStdin: [[String]] = [
  ["ls", "--json"], ["send", "s1", "hi"], ["summary", "help"], ["summary"], ["hook"],
  ["draft", "post", "s1", "1", "--text", "-"], ["set", "summary"],
]

/// `sb-shim cli`, which the box's `~/.sb/bin/sb` runs: it sends its argv in one `cli` request to
/// `$SB_HOME/sbd.sock`, then writes the answer's bytes and exits with its status. Each test runs it with python3
/// against a socket that the test owns.
@Suite struct BoxShimCLITests {
  // MARK: The request

  @Test(.timeLimit(.minutes(1)))
  func theShimSendsOneCliRequestWithItsArgvItsFolderItsSessionAndClaudecode() throws {
    try withBench { b in
      let argv = ["send", "s1", "a b", "", "$(touch x)", "--json", "é ✓ 🎉", "line\nbreak", "SB_HOME=/x"]
      let run = try b.cli(argv, env: ["SB_SESSION_ID": "s1a2b3", "CLAUDECODE": "1"])
      let fd = try #require(b.accept(), "the shim did not connect to $SB_HOME/sbd.sock")
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(Set(request.object?.keys.map { $0 } ?? []) == ["op", "args"])
      #expect(request["op"] == "cli")
      let keys = Set(request["args"]?.object?.keys.map { $0 } ?? [])
      #expect(keys.isSubset(of: ["argv", "cwd", "session", "claudecode", "stdin"]), "\(keys)")
      #expect(request["args"]?["argv"] == .array(argv.map(JSON.string)))
      #expect(request["args"]?["cwd"]?.string.map(real) == real(b.work))
      #expect(request["args"]?["session"] == "s1a2b3")
      #expect(request["args"]?["claudecode"] == "1")
      #expect(sentStdin(request) == Data())
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func withoutSBSessionIdOrClaudecodeTheRequestLeavesThoseKeysOut() throws {
    try withBench { b in
      let run = try b.cli(["ls", "--json"])
      let fd = try #require(b.accept())
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(request["args"]?["session"] == nil)
      #expect(request["args"]?["claudecode"] == nil)
    }
  }

  /// Decision 16: a command's answer could be stale after a reconnect.
  @Test(.timeLimit(.minutes(1)))
  func theCliRequestIsNeverSpooled() throws {
    try withBench { b in
      let run = try b.cli(["ls"], env: ["SB_SESSION_ID": "s1"])
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))

      _ = try #require(run.wait(5))

      #expect(b.spool.isEmpty)
    }
  }

  // MARK: stdin

  @Test(.timeLimit(.minutes(1)), arguments: summarySets)
  func summarySetSendsTheWholeStdinAsBase64(argv: [String]) throws {
    try withBench { b in
      let card = Data([0xFF, 0x00, 0x0A]) + Data(#"{"summary":"Done: \"x\"\nand ✓"}"#.utf8)
      let run = try b.cli(argv, env: ["SB_SESSION_ID": "s1", "CLAUDECODE": "1"], input: card)
      let fd = try #require(b.accept())
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(sentStdin(request) == card, "\(argv)")
    }
  }

  /// stdin stays open, so a shim that read it would never send its request.
  @Test(.timeLimit(.minutes(1)), arguments: noStdin)
  func aCommandOtherThanSummarySetSendsNoStdinAndDoesNotReadIt(argv: [String]) throws {
    try withBench { b in
      let run = try b.cli(argv, env: ["SB_SESSION_ID": "s1"])
      let fd = try #require(b.accept(), "the shim sent no request for \(argv)")
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(sentStdin(request) == Data(), "\(argv)")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aCommandOtherThanSummarySetSendsNoneOfAStdinThatIsThere() throws {
    try withBench { b in
      let secret = Data("a secret on the box".utf8)
      let run = try b.cli(["send", "s1", "hi"], input: secret)
      let fd = try #require(b.accept())
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(sentStdin(request) == Data())
      #expect(!request.text.contains(secret.base64EncodedString()))
    }
  }

  // MARK: The answer

  /// The bytes are not UTF-8, and they hold a NUL and no final newline.
  @Test(.timeLimit(.minutes(1)), arguments: [0, 1, 3, 255])
  func theShimWritesTheAnswersBytesAndExitsWithItsStatus(status: Int) throws {
    try withBench { b in
      let stdout = Data([0xFF, 0xFE, 0x00, 0x61, 0x0A, 0xC3, 0x28])
      let stderr = Data([0x80, 0x65, 0x00, 0x1B, 0x5B, 0x32, 0x4A])
      let run = try b.cli(["ls"])
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)

      try b.answer(fd, cliAnswer(status: status, stdout: stdout, stderr: stderr))
      let result = try #require(run.waitForBytes(5), "the shim still runs 5 s after the answer")

      #expect(result.status == Int32(status))
      #expect(result.stdout == stdout)
      #expect(result.stderr == stderr)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func anOutputLargerThanAPipesBufferArrivesWhole() throws {
    try withBench { b in
      let stdout = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
      let run = try b.cli(["events", "--json"])
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)

      try b.answer(fd, cliAnswer(status: 0, stdout: stdout))
      let result = try #require(run.waitForBytes(10))

      #expect(result.status == 0)
      #expect(result.stdout == stdout)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aFailureAnswerPrintsTheErrorAndExits1() throws {
    try withBench { b in
      let run = try b.cli(["send", "l1", "hi"])
      let fd = try #require(b.accept())
      defer { close(fd) }
      _ = try b.request(fd)

      try b.answer(fd, #"{"ok":false,"error":"that session is not on mini"}"#)
      let result = try #require(run.waitForBytes(5))

      #expect(result.status == 1)
      #expect(result.stdout.isEmpty)
      #expect(String(decoding: result.stderr, as: UTF8.self) == "sb: that session is not on mini\n")
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["close", "not json", ""])
  func anAnswerThatSbdNeverFinishedExits1(reply: String) throws {
    try withBench { b in
      let run = try b.cli(["ls"])
      let fd = try #require(b.accept())
      _ = try b.request(fd)

      if reply != "close" { try b.answer(fd, reply) }
      close(fd)
      let result = try #require(run.waitForBytes(5), "the shim still runs 5 s after sbd closed the connection")

      #expect(result.status == 1, "\(reply)")
      #expect(result.stdout.isEmpty)
    }
  }

  // MARK: No listener

  @Test(.timeLimit(.minutes(1)), arguments: ["missing", "stale"])
  func withNoListenerTheShimExits1Within3SecondsWithTheMessage(socket: String) throws {
    try withBench(socket == "missing" ? .missing : .stale) { b in
      let run = try b.cli(["ls", "--json"], env: ["SB_SESSION_ID": "s1"])

      let result = try #require(run.waitForBytes(3), "the shim still runs after 3 s with no listener")

      #expect(result.status == 1)
      #expect(result.stdout.isEmpty)
      let stderr = String(decoding: result.stderr, as: UTF8.self)
      #expect(stderr.hasPrefix("sb: can't reach Switchboard on the Mac"), "\(stderr)")
      #expect(b.spool.isEmpty, "the shim spooled a cli request")
    }
  }

  /// Without SB_HOME, the shim finds the socket next to its own folder, as `spool-drop` does, and not in the
  /// folder that it runs in.
  @Test(.timeLimit(.minutes(1)), arguments: ["unset", "empty"])
  func withoutSBHomeTheShimConnectsToTheSocketOfItsOwnFolder(sbHome: String) throws {
    try withBench { b in
      let run = try b.cli(["ls"], sbHome: sbHome == "unset" ? .some(nil) : "")
      let fd = try #require(b.accept(), "the shim did not connect to the socket of its folder")
      defer { close(fd) }

      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 0))
      _ = run.wait(5)

      #expect(request["op"] == "cli")
    }
  }

  // MARK: The wrapper

  /// `~/.sb/bin/sb` runs the shim's `cli` with every argument, so a claude on the box runs `sb` as it does on
  /// this Mac.
  @Test(.timeLimit(.minutes(1)))
  func theSbWrapperRunsTheShimsCliWithEveryArgument() throws {
    try withBench { b in
      let boxHome = "\(b.home)/box"
      try FileManager.default.createDirectory(atPath: boxHome, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: "\(boxHome)/.sb", withDestinationPath: b.home)
      let facts = BoxFacts(
        epoch: 1, home: boxHome, shell: "/bin/sh", user: "", lang: "", tmux: "/usr/bin/true", git: "/usr/bin/true",
        python: b.python, clockOffsetMs: 0)
      let wrapper = "\(b.home)/bin/sb"
      try Data(BoxShim.wrapper(for: facts).utf8).write(to: URL(fileURLWithPath: wrapper))
      chmod(wrapper, 0o700)
      let argv = ["send", "s1", "two words", "", "$HOME", "--json"]

      let run = try b.start(wrapper, argv)
      let fd = try #require(b.accept(), "the wrapper's shim did not connect")
      defer { close(fd) }
      let request = try b.request(fd)
      try b.answer(fd, cliAnswer(status: 4, stdout: Data("out".utf8)))
      let result = try #require(run.waitForBytes(5))

      #expect(request["op"] == "cli")
      #expect(request["args"]?["argv"] == .array(argv.map(JSON.string)))
      #expect(result.status == 4)
      #expect(result.stdout == Data("out".utf8))
    }
  }
}
