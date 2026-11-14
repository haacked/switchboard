import Foundation

/// A file that holds `on` or `off` for a setting that a command switches, such as `sb autocontinue`. A missing
/// file means off.
public struct SwitchFile: Sendable {
  public let path: String
  /// The setting's name in the log line that a change writes.
  public let label: String

  public init(_ path: String, label: String) {
    self.path = path
    self.label = label
  }

  public var isOn: Bool {
    (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
  }

  /// Saves the request's `enabled` and returns it, or returns nil when the request doesn't name one.
  public func apply(_ args: JSON) throws -> Bool? {
    guard let enabled = args["enabled"] else { return nil }
    guard let on = enabled.bool else { throw APIError("enabled is true or false") }
    try (on ? "on\n" : "off\n").write(toFile: path, atomically: true, encoding: .utf8)
    logLine("\(label) is \(on ? "on" : "off")")
    return on
  }
}
