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
  /// Folders whose ignored contents only a tool writes. ruff, pytest, and
  /// mypy put a `.gitignore` of `*` inside their caches, so git lists the
  /// files inside them and not the folder. flox, trunk, and husky keep tracked
  /// setup in their folders and write the ignored rest themselves.
  static let toolFolders: Set<String> = [
    "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".flox", ".trunk",
    ".husky",
  ]
  /// Names that count only as the listed path itself. A user's ignored file
  /// can sit in a tracked folder with a generic name such as `build`.
  static let names: Set<String> = toolFolders.union([
    "target", "dist", "build", ".build", ".next", ".turbo", ".cache", "coverage", ".DS_Store", "DerivedData",
    ".hypothesis", ".parcel-cache",
  ])
  static let extensions: Set<String> = ["pyc", "pyo"]
  /// Folders that count only at the top of the worktree. A session's scratch notes live in `.notes/`,
  /// and a nested `.notes` folder may hold a user's own files.
  static let topLevelFolders: Set<String> = [".notes"]

  /// Whether a path that `git status --ignored=matching` lists is build
  /// output: its last component is on the list or in `also`, or a folder
  /// above it is a tool's folder or in `also`, or its first component is a top-level folder. A path that is only that name is a file, because git lists a folder with a trailing slash.
  public static func contains(_ path: String, also: Set<String> = []) -> Bool {
    let parts = path.split(separator: "/").map(String.init)
    guard let name = parts.last else { return false }
    if topLevelFolders.contains(parts[0]) && path != parts[0] { return true }
    if names.contains(name) || extensions.contains((name as NSString).pathExtension) { return true }
    return parts.contains(where: also.contains) || parts.dropLast().contains(where: toolFolders.contains)
  }
}
