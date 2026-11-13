import Foundation
import SwitchboardCore

extension Service {
  /// Starts a session on a new branch in a new worktree of a repository, or
  /// adds it as a follow-up with `followup`. The repository is `owner/name`,
  /// a bare name, or a path to a checkout that starts with / or ~.
  func spawn(_ args: JSON) throws -> SessionSummary {
    let spawn = try SpawnArgs(args)
    if let wait = spawn.wait, let parent = spawn.parent {
      _ = try queue.sync { try lookup(["session": .string(parent)]) }
      guard AttentionState(rawValue: wait) != nil else {
        throw APIError("wait is a state, one of \(AttentionState.allCases.map(\.rawValue).joined(separator: ", "))")
      }
    }

    let (checkout, named) = try spawnCheckout(spawn.repository, repos: config.repos, at: mac)
    if branchOrFolderTaken(checkout, spawn.branch, at: mac) {
      throw APIError("branch \(spawn.branch) or its worktree folder exists for \(checkout). Name a new branch")
    }

    guard spawn.followup else {
      let child = try newSession(
        NewSession(
          path: checkout, branch: spawn.branch, base: spawn.base, name: spawn.name, prompt: spawn.prompt,
          model: spawn.model, parent: spawn.parent, account: spawn.account, group: spawn.group,
          autoMode: spawn.autoMode))
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
  /// map from `owner/name` to a checkout.
  private func spawnCheckout(
    _ ref: String, repos: [String: String], at site: any SessionSite
  ) throws -> (path: String, repository: String?) {
    if ref.hasPrefix("/") || ref.hasPrefix("~") {
      let path = (ref.expandingTilde as NSString).standardizingPath
      guard isDirectory(path) else { throw APIError("no folder \(path)") }
      guard let top = try? gitOutput(path, ["rev-parse", "--show-toplevel"], at: site) else {
        throw APIError("\(path) isn't a git checkout")
      }
      return (top, nil)
    }
    let repository = Followup.isRepository(ref) ? ref : try repository(named: ref, repos: repos, at: site)
    return (try checkout(of: repository, hint: "Pass its folder as --repo"), repository)
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
          hasRemote("\(root)/\(repository)", for: repository)
        {
          found[repository.lowercased()] = repository
        }
      }
    }
    switch found.count {
    case 1:
      return found.values.first!
    case 0:
      throw APIError(
        "can't find a repository named \(name) in repos or under \(config.repoRoots.joined(separator: ", ")). Use owner/name or its folder"
      )
    default:
      throw APIError("\(name) matches \(found.values.sorted().joined(separator: ", ")). Use owner/name")
    }
  }
}
