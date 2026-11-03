import Foundation

/// Whether `sb cleanup` can remove a merged PR's worktree and branch.
public struct CleanupStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    /// Every check passed when the poller last counted the folder.
    case ready
    /// A check failed, and `reason` is its message.
    case blocked
    /// `sb cleanup` removed the worktree. `reason` is "kept <branch>" when
    /// the branch delete failed.
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
    "dist", "build", ".build", ".next", ".turbo", ".cache", "coverage", ".DS_Store", "DerivedData", ".hypothesis",
    ".parcel-cache",
  ]
  static let extensions: Set<String> = ["pyc", "pyo"]
  /// Folders whose ignored contents only a tool writes. ruff, pytest, and
  /// mypy put a `.gitignore` of `*` inside their caches, so git lists the
  /// files inside them and not the folder. flox, trunk, and husky keep tracked
  /// setup in their folders and write the ignored rest themselves. Generic
  /// names such as `build` stay out, because a user's ignored file can sit in
  /// a tracked folder with that name.
  static let toolFolders: Set<String> = [
    "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".flox", ".trunk",
    ".husky",
  ]

  /// Whether a path that `git status --ignored=matching` lists is build
  /// output: its last component is on the list or in `also`, or a folder
  /// above it is a tool's folder or in `also`.
  public static func contains(_ path: String, also: Set<String> = []) -> Bool {
    let parts = path.split(separator: "/").map(String.init)
    guard let name = parts.last else { return false }
    if names.contains(name) || also.contains(name) || extensions.contains((name as NSString).pathExtension) {
      return true
    }
    return parts.dropLast().contains { toolFolders.contains($0) || also.contains($0) }
  }
}
