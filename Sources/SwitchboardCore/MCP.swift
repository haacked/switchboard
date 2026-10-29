import Foundation

/// A local MCP server that sbd runs once on 127.0.0.1 and passes to every
/// session, from `mcpServers` in config.json.
public struct MCPServer: Codable, Equatable, Sendable {
  public enum Transport: String, Codable, Sendable {
    /// Streamable HTTP.
    case http
    case sse
  }

  public var type: Transport
  public var command: String
  /// sbd replaces `{port}` in `command`, the arguments, and `env` with the
  /// server's port.
  public var args: [String]
  public var env: [String: String]
  /// A fixed port, or nil for one that sbd picks and keeps.
  public var port: Int?
  /// The URL path, or nil for /mcp over HTTP and /sse over SSE.
  public var path: String?

  public init(
    type: Transport, command: String, args: [String] = [], env: [String: String] = [:], port: Int? = nil,
    path: String? = nil
  ) {
    self.type = type
    self.command = command
    self.args = args
    self.env = env
    self.port = port
    self.path = path
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decode(Transport.self, forKey: .type)
    command = try c.decode(String.self, forKey: .command)
    args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    port = try c.decodeIfPresent(Int.self, forKey: .port)
    path = try c.decodeIfPresent(String.self, forKey: .path)
  }

  public func url(port: Int) -> String {
    "http://127.0.0.1:\(port)\(path ?? (type == .http ? "/mcp" : "/sse"))"
  }

  /// The shell command that runs the server on `port`, with each leading `~`
  /// expanded. It sorts the environment, so the same config always gives the
  /// same text.
  public func commandLine(port: Int) -> String {
    func fill(_ text: String) -> String {
      let filled = text.replacingOccurrences(of: "{port}", with: String(port))
      return filled.hasPrefix("~") ? filled.expandingTilde : filled
    }
    let env = self.env.sorted { $0.key < $1.key }.map { shellQuote("\($0.key)=\(fill($0.value))") }
    let words = (env.isEmpty ? [] : ["env"] + env) + ([fill(command)] + args.map(fill)).map(shellQuote)
    return "exec " + words.joined(separator: " ")
  }

  /// The reason, by name, for each server that sbd can't run. A name becomes
  /// a tmux session name and the prefix of claude's tool names. A server with
  /// no fixed port and no `{port}` can't learn which port to listen on. Two
  /// servers with the same fixed port would point sessions at whichever one
  /// listens. sbd runs only the first of them by name.
  public static func problems(_ servers: [String: MCPServer]) -> [String: String] {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    var problems: [String: String] = [:]
    var fixed: [Int: String] = [:]
    for (name, server) in servers.sorted(by: { $0.key < $1.key }) {
      if name.isEmpty || name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
        problems[name] = "its name may hold only letters, digits, _ and -"
      } else if let port = server.port, !(1...65535).contains(port) {
        problems[name] = "its port \(port) is not between 1 and 65535"
      } else if let port = server.port, let other = fixed[port] {
        problems[name] = "its port \(port) is also the port of \(other)"
      } else if server.port == nil
        && !([server.command] + server.args + server.env.values).contains(where: { $0.contains("{port}") })
      {
        problems[name] = "it has no port and no {port} in its command, args, or env"
      } else if let port = server.port {
        fixed[port] = name
      }
    }
    return problems
  }

  /// How long sbd waits before it starts a server again, after `exitsInARow`
  /// exits that each came less than a minute after their start. The first
  /// exit restarts at once. Each further one doubles the wait from 1 s up to
  /// 60 s.
  public static func restartDelayMs(exitsInARow: Int) -> Int64 {
    exitsInARow <= 1 ? 0 : min(60_000, 1000 << min(exitsInARow - 2, 6))
  }

  /// A port for each server: its fixed port, else its port in `previous`
  /// when `canKeep` allows it and no other server took it, else a port from
  /// `freePort` that no other server has. A server that `freePort` can't
  /// serve is left out.
  public static func assignPorts(
    _ servers: [String: MCPServer], previous: [String: Int], canKeep: (_ name: String, _ port: Int) -> Bool,
    freePort: () -> Int?
  ) -> [String: Int] {
    var ports = servers.compactMapValues(\.port)
    let names = servers.keys.sorted()
    for name in names where ports[name] == nil {
      if let port = previous[name], !ports.values.contains(port), canKeep(name, port) { ports[name] = port }
    }
    for name in names where ports[name] == nil {
      while let port = freePort() {
        if !ports.values.contains(port) {
          ports[name] = port
          break
        }
      }
    }
    return ports
  }

  /// The `--mcp-config` file's contents for servers on their ports.
  public static func claudeConfig(_ servers: [String: MCPServer], ports: [String: Int]) -> JSON {
    var entries: [String: JSON] = [:]
    for (name, server) in servers {
      if let port = ports[name] {
        entries[name] = ["type": .string(server.type.rawValue), "url": .string(server.url(port: port))]
      }
    }
    return ["mcpServers": .object(entries)]
  }

  /// The port of each server in a `--mcp-config` file that sbd wrote.
  public static func ports(inClaudeConfig config: JSON) -> [String: Int] {
    var ports: [String: Int] = [:]
    for (name, entry) in config["mcpServers"]?.object ?? [:] {
      if let url = entry["url"]?.string.flatMap(URLComponents.init(string:)), let port = url.port {
        ports[name] = port
      }
    }
    return ports
  }
}

/// What `sb mcp` shows for a shared MCP server.
public struct MCPServerStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    /// Its port accepts connections.
    case running
    /// Its process runs, and its port doesn't accept connections yet.
    case starting
    /// Its process exited, and sbd starts it again at `restartAt`.
    case exited
  }

  public var name: String
  public var type: MCPServer.Transport
  public var url: String
  public var state: State
  public var pid: Int?
  /// How many times sbd started it again after it exited.
  public var restarts: Int
  public var restartAt: Int64?
  /// How its last run ended, such as "status 3" or "signal kill".
  public var lastExit: String?
  /// The last lines that its last run printed.
  public var lastOutput: [String]?

  public init(
    name: String, type: MCPServer.Transport, url: String, state: State, pid: Int?, restarts: Int,
    restartAt: Int64?, lastExit: String?, lastOutput: [String]?
  ) {
    self.name = name
    self.type = type
    self.url = url
    self.state = state
    self.pid = pid
    self.restarts = restarts
    self.restartAt = restartAt
    self.lastExit = lastExit
    self.lastOutput = lastOutput
  }
}
