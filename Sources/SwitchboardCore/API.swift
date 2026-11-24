import Foundation
import os

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

/// `Client.call` throws it when it can't connect to sbd's socket, or when
/// sbd goes away before it answers, as when launchd restarts it.
public struct SbdUnreachable: Error, CustomStringConvertible {
  public let description: String
}

/// Runs `body` and throws its error as `SbdUnreachable`.
private func unreachable<T>(_ body: () throws -> T) throws -> T {
  do { return try body() } catch { throw SbdUnreachable(description: "\(error)") }
}

/// Whether `key` names the item by an id prefix or its whole name.
public func refMatches(_ key: String, _ item: (id: String, name: String)) -> Bool {
  item.id.hasPrefix(key) || item.name == key
}

/// The id that `key` names: an id, a unique id prefix, or a unique name.
public func resolveRef(_ key: String, _ noun: String, _ items: [(id: String, name: String)]) throws -> String {
  if items.contains(where: { $0.id == key }) { return key }
  let matches = items.filter { refMatches(key, $0) }
  guard matches.count == 1 else {
    throw APIError(matches.isEmpty ? "no \(noun) \(key)" : "\(key) matches \(matches.count) \(noun)s")
  }
  return matches[0].id
}

/// Arguments of `new`.
public struct NewSession: Codable, Sendable {
  /// The folder to run in. With `branch` or `worktree`, the repo to make a worktree of.
  public var path: String
  public var branch: String?
  /// The commit that a new branch starts from, such as origin/main.
  public var base: String?
  public var name: String?
  /// Makes a worktree even without a `branch`. The branch is then
  /// `Config.branchPrefix` and a slug of `name`, with a random suffix when that branch exists.
  public var worktree: Bool?
  public var prompt: String?
  public var model: String?
  /// The session that starts this one. An id that sbd doesn't know is ignored.
  public var parent: String?
  /// The Claude account, by name or folder. Without it, the session uses its
  /// parent's account, else the active account.
  public var account: String?
  /// The group to join, by id, unique id prefix, or unique name. Without it,
  /// the session joins its parent's group.
  public var group: String?
  /// Whether claude starts in auto mode. Without it, `Config.autoMode` decides.
  public var autoMode: Bool?
  /// Whether claude starts in plan mode. It wins over `autoMode` until the plan is approved.
  public var planMode: Bool?
  /// Whether claude starts in manual mode, whatever `autoMode`, `claudeArgs`, and Claude's settings say. It holds
  /// until claude reports another mode.
  public var manualMode: Bool?
  /// The remote host to run on, by its name in config.json, or `local` for this Mac. With a remote host, `path` is
  /// a folder on that host, absolute or starting with `~`, which the host resolves. A request from this Mac with
  /// no host and a parent on a host fails. sbd maps `local` to nil, so no record holds it.
  public var host: String?
  /// The issue that the session works on, as `sb issue` reads it. It links the session to an issue in another
  /// repo, or one that the branch name doesn't number.
  public var issue: IssueRef?

  public init(
    path: String, branch: String? = nil, base: String? = nil, name: String? = nil, worktree: Bool? = nil,
    prompt: String? = nil, model: String? = nil, parent: String? = nil, account: String? = nil, group: String? = nil,
    autoMode: Bool? = nil, planMode: Bool? = nil, manualMode: Bool? = nil, host: String? = nil,
    issue: IssueRef? = nil
  ) {
    self.path = path
    self.branch = branch
    self.base = base
    self.name = name
    self.worktree = worktree
    self.prompt = prompt
    self.model = model
    self.parent = parent
    self.account = account
    self.group = group
    self.autoMode = autoMode
    self.planMode = planMode
    self.manualMode = manualMode
    self.host = host
    self.issue = issue
  }
}

extension NewSession {
  public static func randomSuffix() -> String { String(UUID().uuidString.lowercased().prefix(4)) }

  /// A branch name for a worktree that the user didn't name: `prefix` and the
  /// slug of `name`, or "session" when the slug is empty. A name for which
  /// `exists` is true gets a random suffix, redrawn until `exists` is false.
  public static func freeAutoBranch(
    prefix: String, name: String?, exists: (String) -> Bool,
    suffix: () -> String = randomSuffix
  ) -> String {
    let slug = Followup.slug(name ?? "", max: 40)
    let stem = prefix + (slug.isEmpty ? "session" : slug)
    var branch = stem
    while exists(branch) { branch = "\(stem)-\(suffix())" }
    return branch
  }
}

/// What `account-move` did, or with `dryRun` would do, to the sessions that are
/// not on the account.
public struct AccountMove: Codable, Equatable, Sendable {
  public struct Blocked: Codable, Equatable, Sendable {
    public var session: String
    public var name: String
    public var reason: String

    public init(session: String, name: String, reason: String) {
      self.session = session
      self.name = name
      self.reason = reason
    }
  }

  /// The folder of the account that the sessions move to.
  public var account: String
  /// The sessions that moved, or with `dryRun` that would move.
  public var moved: [String]
  /// The sessions that stay on their account, and why.
  public var blocked: [Blocked]
  /// For each moved session whose MCP server list names servers that the
  /// account doesn't have, those servers' names, sorted. Nil when no session drops one.
  public var mcpDropped: [String: [String]]?

  public init(
    account: String, moved: [String] = [], blocked: [Blocked] = [], mcpDropped: [String: [String]]? = nil
  ) {
    self.account = account
    self.moved = moved
    self.blocked = blocked
    self.mcpDropped = mcpDropped
  }
}

extension AccountMove {
  /// What a move means for the sessions that move, for the prompt that offers it.
  public static let consequences =
    resumeConsequences + " A session whose claude is running stays on its account until you stop it."

  /// What a move means for a session that moves, without the note on running sessions.
  public static let resumeConsequences = """
    A moved session resumes its conversation under the new account, with that account's settings, \
    MCP servers, and permissions. Its transcript is copied, and the old copy stays. Its next message \
    may write the whole conversation to the prompt cache again, which uses quota.
    """
}

/// One account, as `accounts` reports it.
public struct AccountInfo: Codable, Equatable, Sendable, Identifiable {
  public var name: String
  public var folder: String
  /// True for the account that new sessions without a parent use.
  public var active: Bool
  /// How many sessions run under the account.
  public var sessions: Int
  /// The agent that the account's sessions run. An sbd that lists only Claude accounts leaves it out.
  public var agent: Agent
  public var id: String { folder }

  public init(name: String, folder: String, active: Bool, sessions: Int, agent: Agent = .claude) {
    self.name = name
    self.folder = folder
    self.active = active
    self.sessions = sessions
    self.agent = agent
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    folder = try c.decode(String.self, forKey: .folder)
    active = try c.decode(Bool.self, forKey: .active)
    sessions = try c.decode(Int.self, forKey: .sessions)
    agent = try c.decodeIfPresent(Agent.self, forKey: .agent) ?? .claude
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

/// Who wrote a message that sbd sends to a session. Its `sent` event records it as `by`.
public enum MessageAuthor: String, Codable, Sendable {
  /// The user, from a terminal or the app.
  case you
  /// A Claude Code, inside a session or outside Switchboard.
  case claude
  /// sbd on its own, such as a wait's outcome.
  case sbd

  /// The author of a message that `author` asked sbd to send. Nil means that sbd sends it on its own.
  public init(_ author: Author?) {
    switch author {
    case .you: self = .you
    case .claude: self = .claude
    case nil: self = .sbd
    }
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

  /// The field of a `sent` event with delivery `pasted` that says sbd
  /// records `delivered` once the paste succeeds. sbd recorded no
  /// `delivered` for a direct paste before it added this field.
  public static let awaitsDeliveredKey = "awaits_delivered"

  /// The delivery that a `sent` or `decisions_submitted` event records.
  public init?(of event: Event) {
    guard let raw = event.data["delivery"]?.string else { return nil }
    self.init(rawValue: raw)
  }

  /// Whether the `sent` event's message waits for a `delivered` event. A
  /// queued message always does. A direct paste does only when its event
  /// carries `awaitsDeliveredKey`, so a log from an older sbd never pastes
  /// its direct messages again.
  public static func awaitsDelivered(_ sent: Event) -> Bool {
    switch Delivery(of: sent) {
    case .queued: return true
    case .pasted: return sent.data[awaitsDeliveredKey]?.bool == true
    case .resumed, nil: return false
    }
  }
}

/// Cancels a `Client.call` from another thread. `cancel()` shuts down the
/// call's socket, which wakes the call's blocked read and makes sbd's side
/// read the connection as closed. A `close` from another thread wakes neither.
public final class CallCancel: Sendable {
  private struct State {
    var fd: Int32?
    var cancelled = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var isCancelled: Bool { state.withLock { $0.cancelled } }

  public func cancel() {
    state.withLock { s in
      s.cancelled = true
      if let fd = s.fd { shutdown(fd, SHUT_RDWR) }
    }
  }

  func attach(_ fd: Int32) {
    state.withLock { s in
      s.fd = fd
      if s.cancelled { shutdown(fd, SHUT_RDWR) }
    }
  }

  func detach() { state.withLock { $0.fd = nil } }
}

/// Sends requests to sbd. Each call opens a new connection, sends one
/// request, and reads one response.
public final class Client: Sendable {
  public let home: Home

  public init(home: Home = Home()) {
    self.home = home
  }

  /// Sends one request and returns its result. When `cancel` is cancelled,
  /// the call throws `CancellationError`, and sbd sees the connection close.
  public func call(
    _ op: String, _ args: [String: JSON] = [:], timeout: TimeInterval = 30, cancel: CallCancel? = nil
  ) throws -> JSON {
    if cancel?.isCancelled == true { throw CancellationError() }
    let fd = try unreachable { try UnixSocket.connect(path: home.socket, timeout: timeout) }
    cancel?.attach(fd)
    defer {
      cancel?.detach()
      close(fd)
    }
    let read = Result {
      let line = try JSONCoding.encode(Request(op: op, args: .object(args))) + "\n"
      try unreachable { try UnixSocket.write(fd, Data(line.utf8)) }
      var reader = UnixSocket.LineReader(fd: fd)
      return try reader.next()
    }
    // A shutdown from `cancel` makes the read fail or end early, so a cancelled call reports only the cancel.
    if cancel?.isCancelled == true { throw CancellationError() }
    guard let reply = try read.get() else { throw SbdUnreachable(description: "sbd closed the connection") }
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

  /// Opens the session, which resumes a stopped claude, and returns its terminals.
  public func open(_ id: String) throws -> Terminals {
    try call("open", ["session": .string(id), "terminals": true], as: Terminals.self)
  }

  public func importable(all: Bool = false, repo: String? = nil) throws -> ImportList {
    var args: [String: JSON] = ["all": .bool(all)]
    if let repo { args["repo"] = .string(repo) }
    return try call("importable", args, as: ImportList.self)
  }

  public func accounts() throws -> [AccountInfo] {
    try call("accounts", as: [AccountInfo].self)
  }

  /// Each account's last usage reading, or with `refresh` a new reading of
  /// every account.
  public func usage(refresh: Bool = false) throws -> [AccountUsage] {
    let args: [String: JSON] = refresh ? ["refresh": .bool(true)] : [:]
    return try call("usage", args, as: [AccountUsage].self, timeout: refresh ? 90 : 30)
  }

  public func useAccount(_ ref: String) throws -> [AccountInfo] {
    try call("account-use", ["account": .string(ref)], as: [AccountInfo].self)
  }

  public func moveSessions(to ref: String, dryRun: Bool = false) throws -> AccountMove {
    try call("account-move", ["account": .string(ref), "dryRun": .bool(dryRun)], as: AccountMove.self)
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
