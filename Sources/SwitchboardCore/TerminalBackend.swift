import Foundation

/// The terminal that draws the app's Claude and shell panes.
public enum TerminalBackend: String, Sendable {
  case swiftTerm = "swiftterm"
  case ghostty

  public struct Choice: Equatable, Sendable {
    public var backend: TerminalBackend
    /// Why the choice differs from what `SB_TERMINAL` asked for.
    public var note: String?

    public init(backend: TerminalBackend, note: String?) {
      self.backend = backend
      self.note = note
    }
  }

  /// SwiftTerm unless `SB_TERMINAL=ghostty` asks for libghostty and this build has it.
  public static func choose(environment: [String: String], ghosttyAvailable: Bool) -> Choice {
    guard let name = environment["SB_TERMINAL"]?.lowercased(), !name.isEmpty else {
      return Choice(backend: .swiftTerm, note: nil)
    }
    switch TerminalBackend(rawValue: name) {
    case .ghostty:
      if ghosttyAvailable { return Choice(backend: .ghostty, note: nil) }
      return Choice(
        backend: .swiftTerm,
        note: "SB_TERMINAL=ghostty needs a build with libghostty. Run bin/build-ghostty, then SB_GHOSTTY=1 swift build."
      )
    case .swiftTerm:
      return Choice(backend: .swiftTerm, note: nil)
    case nil:
      return Choice(backend: .swiftTerm, note: "SB_TERMINAL=\(name) is not a terminal. Using swiftterm.")
    }
  }
}
