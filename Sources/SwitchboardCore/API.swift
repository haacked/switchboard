import Foundation

/// One request on sbd's socket: a line of JSON.
public struct Request: Codable, Sendable {
  public var op: String
  public var args: JSON

  public init(op: String, args: JSON = [:]) {
    self.op = op
    self.args = args
  }
}

/// sbd's answer to a request: a line of JSON.
public struct Response: Codable, Sendable {
  public var ok: Bool
  public var result: JSON?
  public var error: String?

  public static func success(_ result: JSON = .null) -> Response { Response(ok: true, result: result, error: nil) }
  public static func failure(_ error: String) -> Response { Response(ok: false, result: nil, error: error) }
}

/// An error that sbd, sb, or the store reports with its message.
public struct APIError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// Arguments of `new`.
public struct NewSession: Codable, Sendable {
  /// The folder to run in. With `branch`, the repo to make a worktree of.
  public var path: String
  public var branch: String?
  /// The commit that a new branch starts from, such as origin/main.
  public var base: String?
  public var name: String?
  public var prompt: String?
  public var model: String?

  public init(
    path: String, branch: String? = nil, base: String? = nil, name: String? = nil, prompt: String? = nil,
    model: String? = nil
  ) {
    self.path = path
    self.branch = branch
    self.base = base
    self.name = name
    self.prompt = prompt
    self.model = model
  }
}

/// What `send` did with the message.
public enum Delivery: String, Codable, Sendable {
  /// Pasted into the live session's prompt.
  case pasted
  /// Passed as the first prompt of a resume.
  case resumed
  /// Queued, because a turn runs or claude is still drawing its prompt.
  case queued
}

/// Sends requests to sbd. Each call opens a new connection, sends one
/// request, and reads one response.
public final class Client: Sendable {
  public let home: Home

  public init(home: Home = Home()) {
    self.home = home
  }

  public func call(_ op: String, _ args: [String: JSON] = [:], timeout: TimeInterval = 30) throws -> JSON {
    let fd = try UnixSocket.connect(path: home.socket, timeout: timeout)
    defer { close(fd) }
    let line = try JSONCoding.encode(Request(op: op, args: .object(args))) + "\n"
    try UnixSocket.write(fd, Data(line.utf8))
    var reader = UnixSocket.LineReader(fd: fd)
    guard let reply = try reader.next() else { throw APIError("sbd closed the connection") }
    let response = try JSONCoding.decoder.decode(Response.self, from: reply)
    guard response.ok else { throw APIError(response.error ?? "sbd failed") }
    return response.result ?? .null
  }

  public func call<T: Decodable>(
    _ op: String, _ args: [String: JSON] = [:], as type: T.Type, timeout: TimeInterval = 30
  )
    throws -> T
  {
    try JSONCoding.convert(try call(op, args, timeout: timeout), to: type)
  }

  public func sessions() throws -> [SessionSummary] {
    try call("ls", as: [SessionSummary].self)
  }

  public func session(_ id: String) throws -> SessionSummary {
    try call("get", ["session": .string(id)], as: SessionSummary.self)
  }

  public func terminals(_ id: String) throws -> Terminals {
    try call("terminals", ["session": .string(id)], as: Terminals.self)
  }
}
