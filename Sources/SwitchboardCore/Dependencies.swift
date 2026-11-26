import Foundation

/// A PR that a `Depends on` line in a PR body names.
public struct DependencyRef: Codable, Equatable, Hashable, Sendable {
  /// owner/name.
  public var repo: String
  public var number: Int
  /// True when the PR must be deployed, not only merged.
  public var deploy: Bool
  /// The PostHog/charts service whose state file shows the deploy, for a
  /// deploy ref whose line names one.
  public var service: String?
  /// The environments that the deploy must reach, for a deploy ref whose
  /// line names them. nil means both prod regions.
  public var environments: [DeployEnvironment]?

  public init(
    repo: String, number: Int, deploy: Bool = false, service: String? = nil, environments: [DeployEnvironment]? = nil
  ) {
    self.repo = repo
    self.number = number
    self.deploy = deploy
    self.service = service
    self.environments = environments
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
  /// Whether the PR reached every environment in `deployEnvironments`. nil
  /// for an edge that needs no deploy, or whose PR has not merged.
  public var deployed: Bool?
  /// The session whose PR this is.
  public var session: String?
  /// The PostHog/charts service whose state file decides the deploy.
  public var service: String?
  /// The environments that the deploy must reach. nil means both prod regions.
  public var environments: [DeployEnvironment]?
  /// Why the deploy can't resolve as the `Depends on` line names it, such as
  /// a service that deploys from another repository. The edge still holds.
  public var problem: String?

  public init(
    via: Via, repo: String, number: Int, base: String? = nil, deploy: Bool = false, state: PRState? = nil,
    deployed: Bool? = nil, session: String? = nil, service: String? = nil, environments: [DeployEnvironment]? = nil,
    problem: String? = nil
  ) {
    self.via = via
    self.repo = repo
    self.number = number
    self.base = base
    self.deploy = deploy
    self.state = state
    self.deployed = deployed
    self.session = session
    self.service = service
    self.environments = environments
    self.problem = problem
  }

  /// The edge that a body ref makes.
  public init(ref: DependencyRef, session: String? = nil) {
    self.init(
      via: .body, repo: ref.repo, number: ref.number, deploy: ref.deploy, session: session, service: ref.service,
      environments: ref.environments)
  }

  public var deployEnvironments: [DeployEnvironment] { environments ?? DeployEnvironment.prod }

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

  /// "waits on #N" while the PR is open, and "waits on the deploy of #N" once
  /// it merged. A line that named the environments names them too.
  func waitLine(from repo: String) -> String {
    guard state == .merged else { return "waits on \(label(from: repo))" }
    return "waits on the deploy of \(label(from: repo))\(environmentsSuffix)"
  }

  /// "prod" for both prod regions by default, and otherwise each environment,
  /// as "dev, prod-us, and prod-eu".
  public var environmentsText: String { environments.map { englishList($0.map(\.rawValue)) } ?? "prod" }

  /// " to <environments>" when the `Depends on` line named them, and empty otherwise.
  public var environmentsSuffix: String { environments == nil ? "" : " to \(environmentsText)" }
}

extension DeployComment {
  public func deployed(to environments: [DeployEnvironment]) -> Bool {
    environments.allSatisfy { state(in: $0) == .deployed }
  }
}

public enum Dependencies {
  /// GitHub ignores the case of owner/name.
  public static func sameRepo(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

  /// A line that starts with `depends on`, after any markdown list, quote, or
  /// emphasis marks.
  static let dependsOnLine = try! NSRegularExpression(pattern: #"^[\s>*_-]*depends on\b"#, options: [.caseInsensitive])
  /// A PR as a URL, `owner/name#N`, or `#N`, as `claude-sessions`' `pr_refs`
  /// finds it. `Wait.PullRequest(parsing:)` reads each match.
  static let prRef = try! NSRegularExpression(
    pattern: #"https?://github\.com/[\w.-]+/[\w.-]+/pull/[0-9]+|(?:[\w.-]+/[\w.-]+)?#[0-9]+"#)

  /// `service: <name>` on a deploy line. The name ends on a letter, digit, or
  /// underscore, so a period that ends the sentence is not part of it.
  static let serviceName = try! NSRegularExpression(
    pattern: #"\bservice:\s*([A-Za-z0-9](?:[\w.-]*[A-Za-z0-9_])?)"#, options: [.caseInsensitive])
  /// `deploy… to <environments>` on a deploy line. The list runs over
  /// environment names, punctuation, and `and`, `or`, `then`, or `both`, and
  /// ends at the first other word.
  static let environmentList = try! NSRegularExpression(
    pattern: #"\bdeploy\w*\s+to\b((?:\W|\b(?:and|or|then|both)\b|"# + environmentNames + ")*)",
    options: [.caseInsensitive])
  static let environmentName = try! NSRegularExpression(pattern: environmentNames, options: [.caseInsensitive])
  private static let environmentNames = #"\b(?:prod-us|prod-eu|prod|dev)\b"#

  /// The PRs that the body's `Depends on` lines name, in order and without
  /// repeats. `#N` names a PR in `repo`. A line that mentions a deploy makes
  /// each of its PRs a deploy ref, with the line's `service:` and `deploy…
  /// to` environments. A repeat keeps the first ref and its first service,
  /// takes the union of the environments, and becomes a deploy ref when any
  /// of its lines is one.
  public static func refs(inBody body: String, repo: String) -> [DependencyRef] {
    guard body.range(of: "depends on", options: .caseInsensitive) != nil else { return [] }
    var refs: [DependencyRef] = []
    for raw in body.split(whereSeparator: \.isNewline) {
      let text = String(raw)
      let whole = NSRange(text.startIndex..., in: text)
      guard dependsOnLine.firstMatch(in: text, range: whole) != nil else { continue }
      let deploy = text.range(of: "deploy", options: .caseInsensitive) != nil
      let service = deploy ? capture(serviceName, in: text) : nil
      let environments = deploy ? capture(environmentList, in: text).flatMap(environments(in:)) : nil
      for match in prRef.matches(in: text, range: whole) {
        guard let range = Range(match.range, in: text), let pr = Wait.PullRequest(parsing: String(text[range])) else {
          continue
        }
        let found = DependencyRef(
          repo: pr.repository ?? repo, number: pr.number, deploy: deploy, service: service, environments: environments)
        if let i = refs.firstIndex(where: { $0.same(repo: found.repo, number: found.number) }) {
          if deploy {
            refs[i].service = refs[i].service ?? service
            refs[i].environments = refs[i].deploy ? union(refs[i].environments, environments) : environments
            refs[i].deploy = true
          }
        } else {
          refs.append(found)
        }
      }
    }
    return refs
  }

  private static func capture(_ regex: NSRegularExpression, in text: String) -> String? {
    guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  /// The environments of a list that `environmentList` matched, or nil when
  /// it names none.
  private static func environments(in list: String) -> [DeployEnvironment]? {
    let names = environmentName.matches(in: list, range: NSRange(list.startIndex..., in: list)).compactMap {
      Range($0.range, in: list).map { list[$0].lowercased() }
    }
    let found = names.flatMap { DeployEnvironment.named($0) ?? [] }
    return found.isEmpty ? nil : DeployEnvironment.ordered(found)
  }

  /// Both lists' environments. A nil list means both prod regions, so a union
  /// with nil names them too.
  private static func union(_ a: [DeployEnvironment]?, _ b: [DeployEnvironment]?) -> [DeployEnvironment]? {
    if a == nil, b == nil { return nil }
    return DeployEnvironment.ordered((a ?? DeployEnvironment.prod) + (b ?? DeployEnvironment.prod))
  }
}
