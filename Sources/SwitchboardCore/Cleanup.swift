import Foundation

/// Whether `sb cleanup` can remove a merged PR's worktree and branch.
public struct CleanupStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    /// Every check passed when the poller last counted the folder.
    case ready
    /// A check failed, and `reason` is its message.
    case blocked
    /// `sb cleanup` removed the worktree.
    case removed
  }

  public var state: State
  public var reason: String?

  public init(state: State, reason: String? = nil) {
    self.state = state
    self.reason = reason
  }

  /// The status that a `worktree` event's `cleanup` value records. The value
  /// is null when every check passed, or the message of the check that failed.
  public init(blocker: String?) {
    self.init(state: blocker == nil ? .ready : .blocked, reason: blocker)
  }
}

/// The ignored paths that `git worktree remove` may delete, because a build
/// or a package manager makes them again.
public enum BuildOutput {
  static let names: Set<String> = [
    "node_modules", ".venv", "venv", "target", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "dist", "build", ".build", ".next", ".turbo", ".cache", "coverage", ".DS_Store", "DerivedData",
  ]
  static let extensions: Set<String> = ["pyc", "pyo"]

  /// Whether a path that `git status --ignored=matching` lists is build
  /// output, judged by its last component.
  public static func contains(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return names.contains(name) || extensions.contains((name as NSString).pathExtension)
  }
}
