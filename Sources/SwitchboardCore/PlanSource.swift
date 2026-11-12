import Foundation

/// Where a plan document lives.
public struct PlanSource: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// A markdown file on this Mac, such as one in the notes repo.
    case file
    /// The body of a GitHub issue.
    case issue
    /// A markdown file on the head branch of a PR.
    case pr
    /// A claude.ai artifact, which only the group's chat can read or write.
    case artifact
  }

  public var kind: Kind
  /// owner/name of an issue or a PR.
  public var repo: String?
  public var number: Int?
  /// The absolute path of a file, or the path of a PR's file in its repo.
  public var path: String?
  /// The link of an artifact.
  public var url: String?

  public init(kind: Kind, repo: String? = nil, number: Int? = nil, path: String? = nil, url: String? = nil) {
    self.kind = kind
    self.repo = repo
    self.number = number
    self.path = path
    self.url = url
  }

  /// Reads an issue as `owner/name#N` or an issue URL, a PR as `owner/name#N`
  /// or a PR URL with the file's `path`, or else a local path, which is
  /// relative to `cwd`. An existing local file wins over the `owner/name#N` form.
  public init(parsing doc: String, path: String?, cwd: String = FileManager.default.currentDirectoryPath) throws {
    let text = doc.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { throw APIError("name a plan document") }
    let file = path?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["/"])
    if file?.isEmpty == true { throw APIError("--path needs a file in the PR") }
    if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
      if let artifact = PlanSource.artifact(url) {
        if file != nil { throw APIError("--path names a file in a PR, and \(text) is an artifact") }
        self = artifact
        return
      }
      let parts = url.path.split(separator: "/").map(String.init)
      guard url.host?.lowercased() == "github.com", parts.count >= 4, ["issues", "pull"].contains(parts[2]),
        let number = Int(parts[3]), number > 0
      else { throw APIError("\(text) is not a GitHub issue or PR") }
      self = try PlanSource.remote(
        repo: "\(parts[0])/\(parts[1])", number: number, path: file, pull: parts[2] == "pull")
      return
    }
    let local = ((text.expandingTilde as NSString).isAbsolutePath ? text.expandingTilde : "\(cwd)/\(text)")
    let standard = (local as NSString).standardizingPath
    if !FileManager.default.fileExists(atPath: standard), let ref = Wait.PullRequest(parsing: text),
      let repo = ref.repository
    {
      self = try PlanSource.remote(repo: repo, number: ref.number, path: file, pull: nil)
      return
    }
    if file != nil { throw APIError("--path names a file in a PR, and \(text) is a local file") }
    self.init(kind: .file, path: standard)
  }

  private static let artifactIdCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

  /// An artifact from a `https://claude.ai/artifact/<id>` or
  /// `https://claude.ai/code/artifact/<id>` link, without its query or fragment.
  /// The id may hold only ASCII letters, digits, `-`, and `_`. `url.path` is
  /// percent-decoded, and the URL goes into the text of the chat's turns, so
  /// an id with `%0A` would add lines to those turns.
  static func artifact(_ url: URL) -> PlanSource? {
    let parts = url.path.split(separator: "/").map(String.init)
    guard url.host?.lowercased() == "claude.ai", url.scheme?.lowercased() == "https", parts.count >= 2,
      [["artifact"], ["code", "artifact"]].contains(Array(parts.dropLast())),
      parts.last!.unicodeScalars.allSatisfy(artifactIdCharacters.contains)
    else { return nil }
    return PlanSource(kind: .artifact, url: "https://claude.ai/" + parts.joined(separator: "/"))
  }

  /// `pull` is nil for `owner/name#N`, which names an issue or a PR.
  private static func remote(repo: String, number: Int, path: String?, pull: Bool?) throws -> PlanSource {
    if let path {
      if pull == false { throw APIError("an issue holds no files. --path names a file in a PR") }
      return PlanSource(kind: .pr, repo: repo, number: number, path: path)
    }
    if pull == true { throw APIError("name the PR's plan file with --path") }
    return PlanSource(kind: .issue, repo: repo, number: number)
  }

  /// `owner/name#N` of an issue or a PR.
  public var ref: String { "\(repo ?? "")#\(number ?? 0)" }

  /// The file's path, or the URL of the issue or the PR.
  public var link: String {
    switch kind {
    case .file: path ?? ""
    case .issue: "https://github.com/\(repo ?? "")/issues/\(number ?? 0)"
    case .pr: "https://github.com/\(repo ?? "")/pull/\(number ?? 0)"
    case .artifact: url ?? ""
    }
  }

  /// The path, `owner/name#N`, or `owner/name#N:path`.
  public var text: String {
    switch kind {
    case .file: path ?? ""
    case .issue: ref
    case .pr: "\(ref):\(path ?? "")"
    case .artifact: url ?? ""
    }
  }
}
