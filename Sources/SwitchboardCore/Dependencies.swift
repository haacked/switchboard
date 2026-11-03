import Foundation

/// A PR that a `Depends on` line in a PR body names.
public struct PRRef: Codable, Equatable, Hashable, Sendable {
  /// owner/name.
  public var repo: String
  public var number: Int
  /// True when the PR must be deployed, not only merged.
  public var deploy: Bool

  public init(repo: String, number: Int, deploy: Bool = false) {
    self.repo = repo
    self.number = number
    self.deploy = deploy
  }

  public func same(repo other: String, number n: Int) -> Bool {
    number == n && Dependencies.sameRepo(repo, other)
  }
}

/// A PR that a session's open PR waits on. Its fields follow the `depends`
/// objects of `~/.dotfiles/bin/claude-sessions`.
public struct Dependency: Codable, Equatable, Sendable {
  public enum Via: String, Codable, Sendable {
    /// The session's PR targets the branch that this PR merges from.
    case stack
    /// A `Depends on` line in the session's PR body names this PR.
    case body
  }

  public var via: Via
  public var repo: String
  public var number: Int
  /// The base branch of the session's PR, for a stack edge. Nothing in sbd
  /// reads it. It keeps the shape of `claude-sessions`' objects.
  public var base: String?
  /// True when the PR must be deployed, not only merged.
  public var deploy: Bool
  /// nil until the poller reads the PR.
  public var state: PRState?
  /// Whether the deploy comment shows the PR deployed in both prod regions.
  /// nil for an edge that needs no deploy, or whose PR has not merged.
  public var deployed: Bool?
  /// The session whose PR this is.
  public var session: String?

  public init(
    via: Via, repo: String, number: Int, base: String? = nil, deploy: Bool = false, state: PRState? = nil,
    deployed: Bool? = nil, session: String? = nil
  ) {
    self.via = via
    self.repo = repo
    self.number = number
    self.base = base
    self.deploy = deploy
    self.state = state
    self.deployed = deployed
    self.session = session
  }

  public var resolved: Bool { state == .merged && (!deploy || deployed == true) }
  public var closed: Bool { state == .closed }
  /// The PR still holds the session: it is open, unread, or not yet deployed.
  public var holds: Bool { !resolved && !closed }

  public func same(repo other: String, number n: Int) -> Bool {
    number == n && Dependencies.sameRepo(repo, other)
  }

  /// `#N` for a PR in `repo`, and `owner/name#N` for one in another repo.
  public func label(from repo: String) -> String {
    Wait.PullRequest(repository: Dependencies.sameRepo(self.repo, repo) ? nil : self.repo, number: number).text
  }
}

extension DeployComment {
  /// Whether the comment shows the PR deployed in both prod regions.
  public var deployedToProd: Bool { [.prodUS, .prodEU].allSatisfy { state(in: $0) == .deployed } }
}

public enum Dependencies {
  /// GitHub ignores the case of owner/name.
  public static func sameRepo(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

  /// A line that starts with `depends on`, after any markdown list, quote, or
  /// emphasis marks.
  static let line = try! NSRegularExpression(pattern: #"^[\s>*_-]*depends on\b"#, options: [.caseInsensitive])
  /// A PR as a URL, `owner/name#N`, or `#N`, as `claude-sessions`' `pr_refs`
  /// finds it. `Wait.PullRequest(parsing:)` reads each match.
  static let ref = try! NSRegularExpression(
    pattern: #"https?://github\.com/[\w.-]+/[\w.-]+/pull/[0-9]+|(?:[\w.-]+/[\w.-]+)?#[0-9]+"#)

  /// The PRs that the body's `Depends on` lines name, in order and without
  /// repeats. `#N` names a PR in `repo`. A line that mentions a deploy makes
  /// each of its PRs a deploy ref. A repeat keeps the first ref, and becomes
  /// a deploy ref when any of its lines is one.
  public static func refs(inBody body: String, repo: String) -> [PRRef] {
    guard body.range(of: "depends on", options: .caseInsensitive) != nil else { return [] }
    var refs: [PRRef] = []
    for raw in body.split(whereSeparator: \.isNewline) {
      let text = String(raw)
      let whole = NSRange(text.startIndex..., in: text)
      guard line.firstMatch(in: text, range: whole) != nil else { continue }
      let deploy = text.range(of: "deploy", options: .caseInsensitive) != nil
      for match in ref.matches(in: text, range: whole) {
        guard let range = Range(match.range, in: text), let pr = Wait.PullRequest(parsing: String(text[range])) else {
          continue
        }
        let found = PRRef(repo: pr.repository ?? repo, number: pr.number, deploy: deploy)
        if let i = refs.firstIndex(where: { $0.same(repo: found.repo, number: found.number) }) {
          refs[i].deploy = refs[i].deploy || deploy
        } else {
          refs.append(found)
        }
      }
    }
    return refs
  }
}
