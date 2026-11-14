import Foundation

/// Where a request came from. sbd sets it from the socket that the request arrived on, never from the request.
public enum RequestOrigin: Equatable, Sendable {
  /// sbd's own socket, `$SB_HOME/sbd.sock`, which only this Mac's user can reach.
  case mac
  /// The socket of the named remote host, `$SB_HOME/hosts/<host>/sbd.sock`, which any program on that host can
  /// reach through the forward.
  case remote(String)

  /// The origin of a request from a session on `host`, nil for this Mac.
  public init(host: String?) {
    self = host.map(RequestOrigin.remote) ?? .mac
  }
}

/// The rule for the machine that a new session runs on.
public enum SessionHost {
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
    return FileCall.normalized("\(cwd)/\(path)")
  }

  /// The host that a new session runs on, or nil for this Mac. `named` is the host that the request names, and
  /// `parent` is the host of the new session's parent, nil for no parent or a parent on this Mac. A named host
  /// wins over the parent's host, and `local` names this Mac. It throws for an empty name.
  ///
  /// A request from host h starts sessions only on h, so `named` is nil or h. The scope of h's requests refuses a
  /// parent off h before this runs, and `create` checks the parent again, so this doesn't read `parent` then.
  public static func choose(named: String?, parent: String?, origin: RequestOrigin) throws -> String? {
    switch origin {
    case .mac:
      guard let named else { return parent }
      guard !named.isEmpty else { throw APIError("--host needs a host name, or local for this Mac") }
      return named == local ? nil : named
    case .remote(let host):
      guard named == nil || named == host else {
        throw APIError("a session on \(host) can start sessions only on \(host)")
      }
      return host
    }
  }
}
