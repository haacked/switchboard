import Foundation

/// The rule for the machine that a new session runs on.
public enum SessionHost {
  /// The machine that a request to start a session came from.
  public enum Origin: Equatable, Sendable {
    case mac
    /// A request that arrived on the socket of the host with this name.
    case host(String)
  }

  /// The host name that a request gives for this Mac. config.json can't hold a host with this name.
  public static let local = "local"

  /// Whether a request's `host` names a remote host, so that a path in the request is a path on that host.
  public static func namesRemote(_ named: String?) -> Bool {
    let name = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !name.isEmpty && name != local
  }

  /// A folder that `sb` got from a host's `cli` request: as typed when it is absolute or starts with `~`, which
  /// the host resolves, and else joined to `cwd`, the folder on the host that the box's `sb` ran in. The join is
  /// lexical, because the path names a folder on the host and not on this Mac.
  public static func hostFolder(_ path: String, cwd: String) -> String {
    if path.hasPrefix("/") || path.hasPrefix("~") { return path }
    var parts: [Substring] = []
    for part in "\(cwd)/\(path)".split(separator: "/") where part != "." {
      if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
  }

  /// The host that a new session runs on, or nil for this Mac. `named` is the host that the request names, and
  /// `parent` is the host of the new session's parent, nil for no parent or a parent on this Mac. A named host
  /// wins over the parent's host, and `local` names this Mac. It throws for an empty name.
  ///
  /// A request from host h starts sessions only on h, so `named` is nil or h. The scope of h's requests refuses a
  /// parent off h before this runs, and `create` checks the parent again, so this doesn't read `parent` then.
  public static func choose(named: String?, parent: String?, origin: Origin) throws -> String? {
    switch origin {
    case .mac:
      guard let named else { return parent }
      guard !named.isEmpty else { throw APIError("--host needs a host name, or local for this Mac") }
      return named == local ? nil : named
    case .host(let host):
      guard named == nil || named == host else {
        throw APIError("a session on \(host) can start sessions only on \(host)")
      }
      return host
    }
  }
}
