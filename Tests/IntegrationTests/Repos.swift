import Foundation
import SwitchboardCore

/// Git repos for one test, each at <root>/<owner>/<name> unless placed elsewhere.
final class Repos {
  let root: String

  init() throws {
    var template = Array("/tmp/sbr.XXXXXX".utf8CString)
    guard let dir = mkdtemp(&template) else { throw TestError(description: "mkdtemp failed") }
    root = String(cString: dir)
  }

  deinit { try? FileManager.default.removeItem(atPath: root) }

  /// A repo whose origin is `remote`, by default https://github.com/<repository>.git.
  @discardableResult
  func make(_ repository: String, remote: String? = nil, at path: String? = nil) throws -> String {
    try Repos.create(path ?? "\(root)/\(repository)", origin: remote ?? "https://github.com/\(repository).git")
  }

  /// Makes a git repo at `dir` with one commit on main.
  @discardableResult
  static func create(_ dir: String, origin: String? = nil) throws -> String {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let commit = [
      "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m",
      "first",
    ]
    for args in [["init", "-q", "-b", "main"], commit] + (origin.map { [["remote", "add", "origin", $0]] } ?? []) {
      let r = try runCommand("/usr/bin/git", ["-C", dir] + args)
      guard r.status == 0 else { throw TestError(description: "git \(args): \(r.stderr)") }
    }
    return dir
  }
}
