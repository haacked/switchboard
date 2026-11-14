import Foundation
import SwitchboardCore

extension Service {
  /// Starts a session on a new branch in a new worktree of a repository, or
  /// adds it as a follow-up with `followup`. The repository is `owner/name`,
  /// a bare name, or a path to a checkout that starts with / or ~.
  /// It starts on the host that `host` names, else on its parent's host, and
  /// there finds the checkout in the host's `repos` or at a path on the host.
  /// `local` names this Mac. A follow-up starts on this Mac. A request from host h starts on h.
  func spawn(_ args: JSON, origin: RequestOrigin = .mac) throws -> SessionSummary {
    let spawn = try SpawnArgs(args)
    if let wait = spawn.wait, let parent = spawn.parent {
      _ = try queue.sync { try lookup(["session": .string(parent)]) }
      guard AttentionState(rawValue: wait) != nil else {
        throw APIError("wait is a state, one of \(AttentionState.allCases.map(\.rawValue).joined(separator: ", "))")
      }
    }

    let parentHost = queue.sync { self.host(ofParent: spawn.parent) }
    // A follow-up starts on this Mac, so it takes no host from its parent.
    let host = spawn.followup ? nil : try SessionHost.choose(named: spawn.host, parent: parentHost, origin: origin)
    if let host, spawn.account != nil { throw Self.noAccount(on: host) }
    let site: any SessionSite = try host.map { try remoteSite($0) } ?? mac
    try awaitSite(site)
    let repos = host.map { config.hosts[$0]?.repos ?? [:] } ?? config.repos
    let (checkout, named) = try site.scoped("the checkout of \(spawn.repository)") { scope in
      let found = try spawnCheckout(spawn.repository, repos: repos, at: scope.site)
      if branchOrFolderTaken(found.path, spawn.branch, at: scope.site) {
        throw APIError("branch \(spawn.branch) or its worktree folder exists for \(found.path). Name a new branch")
      }
      return found
    }

    guard spawn.followup else {
      let child = try startSession(
        NewSession(
          path: checkout, branch: spawn.branch, base: spawn.base, name: spawn.name, prompt: spawn.prompt,
          model: spawn.model, parent: spawn.parent, account: spawn.account, group: spawn.group,
          autoMode: spawn.autoMode, planMode: spawn.planMode, host: host), origin: origin)
      guard let wait = spawn.wait, let parent = child.parent else { return child }
      try queue.sync {
        _ = try waitRequest(
          "wait",
          [
            "session": .string(parent), "kind": .string(Wait.Kind.session.rawValue), "target": .string(child.id),
            "state": .string(wait), "by": .string(Author.claude.rawValue),
          ])
      }
      return queue.sync { summary(child.id) }
    }
    // A follow-up keeps only `owner/name`. `followup start` finds the checkout again from it.
    guard let repository = named ?? githubRepository(checkout, at: mac) else {
      throw APIError("\(checkout) has no remote on github.com, which a follow-up needs. Spawn it without --followup")
    }
    var add: [String: JSON] = [
      "prompt": .string(spawn.prompt), "repository": .string(repository), "branch": .string(spawn.branch),
    ]
    if let after = spawn.after { add["after"] = .string(after) }
    if let autoMode = spawn.autoMode { add["autoMode"] = .bool(autoMode) }
    if let planMode = spawn.planMode { add["planMode"] = .bool(planMode) }
    for (key, value) in [
      "title": spawn.name, "parent": spawn.parent, "model": spawn.model, "account": spawn.account,
      "group": spawn.group,
    ] {
      if let value { add[key] = .string(value) }
    }
    return try addFollowup(.object(add))
  }

  /// The top folder of the checkout that `ref` names, and the `owner/name`
  /// that `ref` names. A path names no `owner/name`. `repos` is the site's
  /// map from `owner/name` to a checkout, and paths resolve at the site.
  private func spawnCheckout(
    _ ref: String, repos: [String: String], at site: any SessionSite
  ) throws -> (path: String, repository: String?) {
    if ref.hasPrefix("/") || ref.hasPrefix("~") {
      let path = try expand(ref, at: site)
      guard site.machine.isFolder(path) else { throw APIError("no folder \(path)") }
      guard let top = try? gitOutput(path, ["rev-parse", "--show-toplevel"], at: site) else {
        throw APIError("\(path) isn't a git checkout")
      }
      return (top, nil)
    }
    let repository = Followup.isRepository(ref) ? ref : try repository(named: ref, repos: repos, at: site)
    guard let host = site.hostName else {
      return (try checkout(of: repository, hint: "Pass its folder as --repo"), repository)
    }
    guard let configured = Self.configuredCheckout(repository, in: repos) else {
      throw APIError(
        "the repos of \(host) in \(home.config) have no \(repository). Pass its folder on \(host) as --repo, or add it to those repos"
      )
    }
    let path = try expand(configured, at: site)
    guard site.machine.isFolder(path) else {
      throw APIError("the repos of \(host) set \(repository) to \(configured), which isn't a folder on \(host)")
    }
    guard hasRemote(path, for: repository, at: site) else {
      throw APIError("\(path) on \(host) has no remote on github.com for \(repository)")
    }
    return (try gitOutput(path, ["rev-parse", "--show-toplevel"], at: site), repository)
  }

  /// The checkout that `repos` sets for `repository`, whose key matches it without case.
  static func configuredCheckout(_ repository: String, in repos: [String: String]) -> String? {
    repos.first { Dependencies.sameRepo($0.key, repository) }?.value
  }

  /// The path with `~` resolved at the site. A host refuses `~name`, whose home sbd doesn't know.
  private func expand(_ path: String, at site: any SessionSite) throws -> String {
    guard let host = site.hostName else { return (path.expandingTilde as NSString).standardizingPath }
    return try remoteSite(host).expand(path)
  }

  /// The `owner/name` of the one repository called `name`: a key of
  /// `repos`, or, on this Mac, a <root>/<owner>/<name> folder under
  /// `repoRoots` with a github.com remote for owner/name.
  private func repository(named name: String, repos: [String: String], at site: any SessionSite) throws -> String {
    guard !name.contains("/"), name != ".", name != ".." else {
      throw APIError("\(name) isn't a repository. Use owner/name, a name, or a folder")
    }
    var found: [String: String] = [:]
    for key in repos.keys where key.split(separator: "/").last?.lowercased() == name.lowercased() {
      found[key.lowercased()] = key
    }
    let roots = site.hostName == nil ? config.repoRoots : []
    for root in roots.map({ ($0.expandingTilde as NSString).standardizingPath }) {
      for owner in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !owner.hasPrefix(".") {
        let repository = "\(owner)/\(name)"
        if found[repository.lowercased()] == nil, isDirectory("\(root)/\(repository)"),
          hasRemote("\(root)/\(repository)", for: repository, at: mac)
        {
          found[repository.lowercased()] = repository
        }
      }
    }
    switch found.count {
    case 1:
      return found.values.first!
    case 0:
      guard let host = site.hostName else {
        throw APIError(
          "can't find a repository named \(name) in repos or under \(config.repoRoots.joined(separator: ", ")). Use owner/name or its folder"
        )
      }
      throw APIError(
        "can't find a repository named \(name) in the repos of \(host) in \(home.config). Use owner/name or its folder on \(host)"
      )
    default:
      throw APIError("\(name) matches \(found.values.sorted().joined(separator: ", ")). Use owner/name")
    }
  }
}
