import Foundation

public enum HostKind: String, Codable, Sendable { case hogli, ssh }
public enum HostLayout: String, Codable, Sendable { case shared, perSession }

/// An entry of `hosts` in config.json that breaks a rule.
public struct InvalidHost: Equatable, Sendable {
  /// The entry's kind when its `kind` names one.
  public var kind: HostKind?
  public var problem: String
}

/// A remote machine from `hosts` in config.json.
public struct HostConfig: Codable, Equatable, Sendable {
  public var name: String
  public var kind: HostKind
  public var layout: HostLayout
  public var workspace: String?
  public var destination: String?
  public var region: String?
  public var repos: [String: String]
  public var worktreeRoot: String
  public var liveCap: Int?
  public var account: String?
  public var autoStart: Bool
  public var linkIdleSeconds: Int

  private static let regions = ["us-east-1", "eu-central-1"]

  /// The ssh destination of the host's one link: `destination` for an ssh host,
  /// `coder.<workspace>` for a shared hogli host, nil for a perSession host.
  public var sshDestination: String? {
    switch (kind, layout) {
    case (.ssh, _): return destination
    case (.hogli, .shared): return workspace.map { "coder.\($0)" }
    case (.hogli, .perSession): return nil
    }
  }

  private static func kind(of value: JSON) -> HostKind? {
    value["kind"]?.string.flatMap(HostKind.init(rawValue:))
  }

  /// The valid hosts and the invalid ones, by name. Pure.
  public static func parse(_ hosts: [String: JSON]) -> (valid: [String: HostConfig], invalid: [String: InvalidHost]) {
    var valid: [String: HostConfig] = [:]
    var invalid: [String: InvalidHost] = [:]
    // An invalid host has no link, so it does not hold its destination against a later host.
    var owners: [String: String] = [:]
    for name in hosts.keys.sorted() {
      let value = hosts[name] ?? .null
      do {
        let host = try HostConfig(name: name, value: value)
        if let destination = host.sshDestination {
          if let owner = owners[destination] {
            throw Problem("its destination \(destination) is also the destination of \(owner)")
          }
          owners[destination] = name
        }
        valid[name] = host
      } catch {
        invalid[name] = InvalidHost(kind: kind(of: value), problem: "\(error)")
      }
    }
    return (valid, invalid)
  }

  private struct Problem: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }

  /// The host that the value describes. It throws a `Problem` for the first of rules 1 to 11
  /// that the value breaks.
  private init(name: String, value: JSON) throws {
    guard Self.isName(name, first: Self.lowercaseAndDigits, rest: Self.lowercaseAndDigits + "_-"), name != "local"
    else {
      throw Problem("its name may hold only lowercase letters, digits, _ and -, at most 32, and can't be local")
    }
    guard let object = value.object else { throw Problem("its value must be an object") }
    guard let kind = Self.kind(of: value) else { throw Problem("its kind must be hogli or ssh") }

    func read<T>(_ key: String, _ reader: (JSON) -> T?, _ expected: String) throws -> T? {
      guard let value = object[key], value != .null else { return nil }
      guard let read = reader(value) else { throw Problem("its \(key) must be \(expected)") }
      return read
    }
    func string(_ key: String) throws -> String? { try read(key, \.string, "a string") }
    func int(_ key: String) throws -> Int? { try read(key, \.int, "a whole number") }
    func bool(_ key: String) throws -> Bool? { try read(key, \.bool, "true or false") }

    let layoutText = try string("layout")
    let workspace = try string("workspace")
    let destination = try string("destination")
    let region = try string("region")
    let worktreeRoot = try string("worktreeRoot")
    let account = try string("account")
    let liveCap = try int("liveCap")
    let linkIdleSeconds = try int("linkIdleSeconds")
    let autoStart = try bool("autoStart")
    var repos: [String: String] = [:]
    if let value = object["repos"], value != .null {
      guard let entries = value.object else { throw Problem("its repos must be an object") }
      for (repo, checkout) in entries {
        guard let path = checkout.string else { throw Problem("its repos value for \(repo) must be a string") }
        repos[repo] = path
      }
    }

    var layout = HostLayout.shared
    if let layoutText {
      guard let named = HostLayout(rawValue: layoutText) else {
        throw Problem("its layout must be shared or perSession")
      }
      layout = named
    }

    switch (kind, layout) {
    case (.ssh, _):
      guard let destination, !destination.isEmpty else { throw Problem("an ssh host needs a destination") }
      let unsafe = destination.unicodeScalars.contains {
        $0.properties.isWhitespace || $0.properties.generalCategory == .control
      }
      if destination.hasPrefix("-") || unsafe {
        throw Problem("its destination can't start with - or hold whitespace or a control character")
      }
      if layout == .perSession { throw Problem("an ssh host can't have the perSession layout") }
      if workspace != nil { throw Problem("an ssh host can't have a workspace") }
      if region != nil { throw Problem("an ssh host can't have a region") }
    case (.hogli, .shared):
      guard let workspace else { throw Problem("a hogli host with the shared layout needs a workspace") }
      guard Self.isName(workspace, first: Self.lettersAndDigits, rest: Self.lettersAndDigits + "-") else {
        throw Problem("its workspace may hold only letters, digits, and -, at most 32, and can't start with -")
      }
      if destination != nil { throw Problem("a hogli host can't have a destination") }
      if region != nil { throw Problem("only a hogli host with the perSession layout can have a region") }
    case (.hogli, .perSession):
      if workspace != nil { throw Problem("a hogli host with the perSession layout can't have a workspace") }
      if worktreeRoot != nil { throw Problem("a hogli host with the perSession layout can't have a worktreeRoot") }
      if destination != nil { throw Problem("a hogli host can't have a destination") }
      if let region, !Self.regions.contains(region) {
        throw Problem("its region must be \(Self.regions.joined(separator: " or "))")
      }
    }

    for repo in repos.keys.sorted() {
      let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
        throw Problem("its repos key \(repo) is not owner/name")
      }
      if repos[repo]?.isEmpty == true { throw Problem("its repos value for \(repo) is empty") }
    }
    if let liveCap, liveCap < 1 { throw Problem("its liveCap must be at least 1") }
    if let linkIdleSeconds, linkIdleSeconds < 1 { throw Problem("its linkIdleSeconds must be at least 1") }
    if account?.isEmpty == true { throw Problem("its account can't be empty") }

    self.name = name
    self.kind = kind
    self.layout = layout
    self.workspace = workspace
    self.destination = destination
    self.region = region
    self.repos = repos
    self.worktreeRoot = worktreeRoot ?? "~/worktrees"
    self.liveCap = liveCap
    self.account = account
    self.autoStart = autoStart ?? true
    self.linkIdleSeconds = linkIdleSeconds ?? 1800
  }

  private static let lowercaseAndDigits = "abcdefghijklmnopqrstuvwxyz0123456789"
  private static let lettersAndDigits = lowercaseAndDigits + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  /// Whether the text is 1 to 32 characters, the first from `first` and each from `rest`. It
  /// compares Unicode scalars, so a letter with a combining mark never passes as the letter.
  private static func isName(_ text: String, first: String, rest: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    guard let head = scalars.first, scalars.count <= 32 else { return false }
    return first.unicodeScalars.contains(head) && scalars.allSatisfy(rest.unicodeScalars.contains)
  }
}

public enum LinkState: String, Codable, Sendable { case disconnected, connecting, connected, unreachable }

/// One row of `sb host ls`. A host with no link has no `link`, `since`, or `failures`, and only
/// an invalid host has a `problem`.
public struct HostStatus: Codable, Equatable, Sendable {
  public var name: String
  public var kind: String?
  public var destination: String?
  public var link: LinkState?
  public var since: Int64?
  public var failures: Int?
  public var retryAt: Int64?
  public var error: String?
  public var problem: String?

  public init(
    name: String, kind: String? = nil, destination: String? = nil, link: LinkState? = nil, since: Int64? = nil,
    failures: Int? = nil, retryAt: Int64? = nil, error: String? = nil, problem: String? = nil
  ) {
    self.name = name
    self.kind = kind
    self.destination = destination
    self.link = link
    self.since = since
    self.failures = failures
    self.retryAt = retryAt
    self.error = error
    self.problem = problem
  }
}

/// How long to wait before the next try after `failuresInARow` failures. The first failure
/// retries at once. Each further one doubles the wait from 1 s up to 60 s.
public func retryDelayMs(failuresInARow: Int) -> Int64 {
  failuresInARow <= 1 ? 0 : min(60_000, 1000 << min(failuresInARow - 2, 6))
}
