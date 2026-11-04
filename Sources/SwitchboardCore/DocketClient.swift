import Foundation

/// A Model Context Protocol client for `docket mcp`, docket's only interface
/// for programs. Each `run` starts docket, makes its calls, and closes stdin,
/// which ends the server.
public final class DocketClient {
  private let input: FileHandle
  private var output: UnixSocket.LineReader
  private var nextId = 1

  private init(input: FileHandle, output: FileHandle) {
    self.input = input
    self.output = UnixSocket.LineReader(fd: output.fileDescriptor)
  }

  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  /// Runs `<docket> mcp` with `env`, initializes the session, and passes the
  /// client to `body`. docket gets SIGTERM after `timeout` seconds, which
  /// fails the call that waits.
  public static func run<T>(
    docket: String, env: [String: String], timeout: Double, _ body: (DocketClient) throws -> T
  ) throws -> T {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: docket)
    p.arguments = ["mcp"]
    p.environment = env
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr
    var errData = Data()
    let errDone = DispatchGroup()
    errDone.enter()
    // A queue of its own reads stderr. A full stderr pipe then can't stall docket.
    DispatchQueue(label: "docket.stderr").async {
      errData = stderr.fileHandleForReading.readDataToEndOfFile()
      errDone.leave()
    }
    try p.run()
    let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue(label: "docket.timeout").asyncAfter(deadline: .now() + timeout, execute: kill)
    let client = DocketClient(input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
    // The timeout stays armed while docket exits. A docket that ignores the
    // closed stdin still ends.
    defer {
      try? stdin.fileHandleForWriting.close()
      p.waitUntilExit()
      kill.cancel()
    }
    do {
      _ = try client.request(
        "initialize",
        [
          "protocolVersion": .string(MCPToolServer.protocolVersion), "capabilities": [:],
          "clientInfo": ["name": "sbd", "version": "1"],
        ])
      try client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
      return try body(client)
    } catch let failure as Failure {
      try? stdin.fileHandleForWriting.close()
      if p.isRunning { p.terminate() }
      errDone.wait()
      let err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw err.isEmpty ? failure : Failure(description: "\(failure.description): \(oneLine(err, max: 300))")
    }
  }

  /// Calls a docket tool and returns its structured result. A tool error
  /// throws with docket's text.
  public func call(_ tool: String, _ arguments: JSON = [:]) throws -> JSON {
    let result = try request("tools/call", ["name": .string(tool), "arguments": arguments])
    let text = result["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
    if result["isError"]?.bool == true {
      throw Failure(description: text.isEmpty ? "docket's \(tool) failed" : text)
    }
    if let structured = result["structuredContent"] { return structured }
    guard let parsed = JSON.parse(text) else { throw Failure(description: "docket's \(tool) returned no JSON") }
    return parsed
  }

  /// The open reviews, which `list_reviews` reads from claude and GitHub first.
  public func listReviews() throws -> [DocketReview] {
    try (call("list_reviews")["reviews"]?.array ?? []).map(DocketClient.review)
  }

  private static let snakeCase: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  /// A review from a tool result's `review`, or from an element of `reviews`.
  public static func review(_ value: JSON) throws -> DocketReview {
    try snakeCase.decode(DocketReview.self, from: Data(value.text.utf8))
  }

  private func request(_ method: String, _ params: JSON) throws -> JSON {
    let id = nextId
    nextId += 1
    try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
    while true {
      let message = try readMessage()
      // The loop skips notifications and any other message that isn't this request's reply.
      guard message["id"]?.int == id else { continue }
      if let error = message["error"] {
        throw Failure(description: error["message"]?.string ?? "docket answered \(method) with an error")
      }
      return message["result"] ?? [:]
    }
  }

  private func send(_ message: JSON) throws {
    do {
      try input.write(contentsOf: Data((message.text + "\n").utf8))
    } catch {
      throw Failure(description: "docket exited")
    }
  }

  private func readMessage() throws -> JSON {
    while true {
      guard let line = try output.next() else { throw Failure(description: "docket exited") }
      if let message = JSON.parse(String(decoding: line, as: UTF8.self)) { return message }
    }
  }
}
