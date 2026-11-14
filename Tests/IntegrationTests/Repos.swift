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

  /// Installs a post-checkout hook in the repo that holds each checkout, such
  /// as a new worktree's, while the returned file exists, or for at most 30 s.
  /// The hook creates `<file>.held` when it starts. The caller removes the
  /// file to let git finish.
  func holdCheckouts(in repo: String) throws -> String {
    let hold = "\(root)/checkout-hold"
    FileManager.default.createFile(atPath: hold, contents: nil)
    let hook = "\(repo)/.git/hooks/post-checkout"
    try
      "#!/bin/sh\n: > '\(hold).held'\ni=0\nwhile [ -e '\(hold)' ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done\n"
      .write(toFile: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    return hold
  }

  /// Makes a git repo at `dir` with one commit on main.
  @discardableResult
  static func create(_ dir: String, origin: String? = nil) throws -> String {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try git(dir, "init", "-q", "-b", "main")
    try commit(dir, "first")
    if let origin { try git(dir, "remote", "add", "origin", origin) }
    return dir
  }

  /// Runs git in `dir` and returns its trimmed output. It throws when git fails.
  @discardableResult
  static func git(_ dir: String, _ args: String...) throws -> String {
    try git(dir, args)
  }

  @discardableResult
  static func git(_ dir: String, _ args: [String]) throws -> String {
    let r = try runCommand("/usr/bin/git", ["-C", dir] + args)
    guard r.status == 0 else { throw TestError(description: "git \(args.joined(separator: " ")) failed: \(r.stderr)") }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Arguments that set a test identity and turn off signing for a git command that makes a commit.
  static let identity = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]

  /// Makes an empty commit in `dir` and returns its sha.
  @discardableResult
  static func commit(_ dir: String, _ message: String) throws -> String {
    try git(dir, identity + ["commit", "-q", "--allow-empty", "-m", message])
    return try git(dir, "rev-parse", "HEAD")
  }
}
