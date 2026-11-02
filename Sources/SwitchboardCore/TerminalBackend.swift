import Foundation

/// The terminal that draws the app's Claude and shell panes.
public enum TerminalBackend: String, Sendable {
  case swiftTerm = "swiftterm"
  case ghostty

  public struct Choice: Equatable, Sendable {
    public var backend: TerminalBackend
    /// Why the choice is not the terminal that the default or `SB_TERMINAL` names.
    public var note: String?

    public init(backend: TerminalBackend, note: String?) {
      self.backend = backend
      self.note = note
    }
  }

  private static let missingGhostty =
    "This build has no libghostty. Run bin/build-ghostty, then SB_GHOSTTY=1 swift build. Using swiftterm."

  /// libghostty unless `SB_TERMINAL=swiftterm` asks for SwiftTerm or this build lacks libghostty.
  public static func choose(environment: [String: String], ghosttyAvailable: Bool) -> Choice {
    let preferred =
      ghosttyAvailable ? Choice(backend: .ghostty, note: nil) : Choice(backend: .swiftTerm, note: missingGhostty)
    guard let name = environment["SB_TERMINAL"]?.lowercased(), !name.isEmpty else { return preferred }
    switch TerminalBackend(rawValue: name) {
    case .ghostty:
      return preferred
    case .swiftTerm:
      return Choice(backend: .swiftTerm, note: nil)
    case nil:
      return Choice(
        backend: preferred.backend, note: "SB_TERMINAL=\(name) is not a terminal. Using \(preferred.backend.rawValue).")
    }
  }
}
