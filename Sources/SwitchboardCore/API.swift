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
  /// The session that starts this one. An id that sbd doesn't know is ignored.
  public var parent: String?
  /// The Claude account, by name or folder. Without it, the session uses its
  /// parent's account, else the active account.
  public var account: String?

  public init(
    path: String, branch: String? = nil, base: String? = nil, name: String? = nil, prompt: String? = nil,
    model: String? = nil, parent: String? = nil, account: String? = nil
  ) {
    self.path = path
    self.branch = branch
    self.base = base
    self.name = name
    self.prompt = prompt
    self.model = model
    self.parent = parent
    self.account = account
  }
}

/// One Claude account, as `accounts` reports it.
public struct AccountInfo: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var folder: String
  /// True for the account that new sessions without a parent use.
  public var active: Bool
  /// How many sessions run under the account.
  public var sessions: Int
  public var id: String { folder }

  public init(name: String, folder: String, active: Bool, sessions: Int) {
    self.name = name
    self.folder = folder
    self.active = active
    self.sessions = sessions
  }
}

/// The answer to `importable`: the Claude sessions that Switchboard can import.
public struct ImportList: Codable, Equatable, Sendable {
  public var sessions: [ClaudeSession]
  /// How many sessions the list leaves out, because they don't run in a worktree.
  /// With a repo filter, it counts only that repo's sessions.
  public var hidden: Int
  /// Every repo that has a session to import, whatever the repo filter, sorted.
  public var repos: [String]

  public init(sessions: [ClaudeSession], hidden: Int, repos: [String]) {
    self.sessions = sessions
    self.hidden = hidden
    self.repos = repos
  }

  /// The list of the candidates that Switchboard doesn't have: the sessions in
  /// a linked worktree, or with `all` every one, and only those of the repo
  /// named exactly `repo` when it is set.
  public static func make(from candidates: [ClaudeSession], all: Bool, repo: String?) -> ImportList {
    let inRepo = repo == nil ? candidates : candidates.filter { $0.repo == repo }
    let shown = all ? inRepo : inRepo.filter(\.worktree)
    return ImportList(
      sessions: shown.sorted(by: ClaudeSession.importOrder), hidden: inRepo.count - shown.count,
      repos: Set(candidates.compactMap(\.repo)).sorted())
  }

  /// Groups each stretch of consecutive sessions that share a repo, which the
  /// list's order keeps together. Folders outside git form one group.
  public var groups: [(title: String, sessions: [ClaudeSession])] {
    var out: [(title: String, sessions: [ClaudeSession])] = []
    for s in sessions {
      let title = s.repo ?? "Outside git"
      if out.last?.title == title { out[out.count - 1].sessions.append(s) } else { out.append((title, [s])) }
    }
    return out
  }
}

/// Why `import` didn't import the session that a ref names.
public struct Refusal: Codable, Equatable, Sendable {
  public var ref: String
  public var reason: String

  public init(ref: String, reason: String) {
    self.ref = ref
    self.reason = reason
  }
}

/// The answer to `import`.
public struct ImportResult: Codable, Sendable {
  public var imported: [SessionSummary]
  public var refused: [Refusal]

  public init(imported: [SessionSummary], refused: [Refusal]) {
    self.imported = imported
    self.refused = refused
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

  public func importable(all: Bool = false, repo: String? = nil) throws -> ImportList {
    var args: [String: JSON] = ["all": .bool(all)]
    if let repo { args["repo"] = .string(repo) }
    return try call("importable", args, as: ImportList.self)
  }

  public func accounts() throws -> [AccountInfo] {
    try call("accounts", as: [AccountInfo].self)
  }

  public func useAccount(_ ref: String) throws -> [AccountInfo] {
    try call("account-use", ["account": .string(ref)], as: [AccountInfo].self)
  }

  /// With `stop`, exits the idle interactive claude that runs each session
  /// that one of these refs names before importing it.
  public func importSessions(_ refs: [String], name: String? = nil, stop: [String] = []) throws -> ImportResult {
    var args: [String: JSON] = ["refs": .array(refs.map(JSON.string))]
    if let name { args["name"] = .string(name) }
    if !stop.isEmpty { args["stop"] = .array(stop.map(JSON.string)) }
    return try call("import", args, as: ImportResult.self)
  }
}
