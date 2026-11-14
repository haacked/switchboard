import Foundation

/// The rule for the machine that a new session runs on.
public enum SessionHost {
  /// The machine that a request to start a session came from.
  public enum Origin: Equatable, Sendable {
    case mac
  }

  /// The host name that a request gives for this Mac. config.json can't hold a host with this name.
  public static let local = "local"

  /// Whether a request's `host` names a remote host, so that a path in the request is a path on that host.
  public static func namesRemote(_ named: String?) -> Bool {
    let name = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !name.isEmpty && name != local
  }

  /// The host that a new session runs on, or nil for this Mac. `named` is the host that the request names, and
  /// `parent` is the host of the new session's parent, nil for no parent or a parent on this Mac. A named host
  /// wins over the parent's host, and `local` names this Mac. It throws for an empty name.
  public static func choose(named: String?, parent: String?, origin: Origin) throws -> String? {
    switch origin {
    case .mac:
      guard let named else { return parent }
      guard !named.isEmpty else { throw APIError("--host needs a host name, or local for this Mac") }
      return named == local ? nil : named
    }
  }
}
