import Foundation
import SwitchboardCore

extension Service {
  /// Starts a session on a new branch in a new worktree of a repository, or
  /// adds it as a follow-up with `followup`. The repository is `owner/name`,
  /// a bare name, or a path to a checkout that starts with / or ~.
  func spawn(_ args: JSON) throws -> SessionSummary {
    func text(_ key: String) -> String? {
      args[key]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let ref = text("repository") else { throw APIError("spawn needs a repository") }
    guard let branch = text("branch") else { throw APIError("spawn needs a branch") }
    guard let prompt = text("prompt") else { throw APIError("spawn needs a prompt") }
    let followup = args["followup"]?.bool == true
    let after = text("after")
    if after != nil, !followup { throw APIError("--after needs --followup, because a started session has no trigger") }
    if followup, text("base") != nil {
      throw APIError(
        "--base needs a started spawn, because a follow-up keeps no base. Pass --base to sb followup start")
    }

    let wait = text("wait")
    if let wait {
      if followup { throw APIError("wait needs a started spawn, because a follow-up has no state to reach") }
      guard let parent = text("parent") else { throw APIError("wait needs a calling session to resume") }
      _ = try queue.sync { try lookup(["session": .string(parent)]) }
      guard AttentionState(rawValue: wait) != nil else {
        throw APIError("wait is a state, one of \(AttentionState.allCases.map(\.rawValue).joined(separator: ", "))")
      }
    }

    let (checkout, named) = try spawnCheckout(ref)
    if branchOrFolderTaken(checkout, branch, at: mac) {
      throw APIError("branch \(branch) or its worktree folder exists for \(checkout). Name a new branch")
    }

    guard followup else {
      let child = try newSession(
        NewSession(
          path: checkout, branch: branch, base: text("base"), name: text("name"), prompt: prompt, model: text("model"),
          parent: text("parent"), account: text("account"), group: text("group"), autoMode: args["autoMode"]?.bool,
          planMode: args["planMode"]?.bool))
      guard let wait, let parent = child.parent else { return child }
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
    var add: [String: JSON] = ["prompt": .string(prompt), "repository": .string(repository), "branch": .string(branch)]
    if let after { add["after"] = .string(after) }
    for key in ["autoMode", "planMode"] {
      if let value = args[key] { add[key] = value }
    }
    for (from, to) in ["name": "title", "parent": "parent", "model": "model", "account": "account", "group": "group"] {
      if let value = text(from) { add[to] = .string(value) }
    }
    return try addFollowup(.object(add))
  }

  /// The top folder of the checkout that `ref` names, and the `owner/name`
  /// that `ref` names. A path names no `owner/name`.
  private func spawnCheckout(_ ref: String) throws -> (path: String, repository: String?) {
    if ref.hasPrefix("/") || ref.hasPrefix("~") {
      let path = (ref.expandingTilde as NSString).standardizingPath
      guard isDirectory(path) else { throw APIError("no folder \(path)") }
      guard let top = try? gitOutput(path, ["rev-parse", "--show-toplevel"], at: mac) else {
        throw APIError("\(path) isn't a git checkout")
      }
      return (top, nil)
    }
    let repository = Followup.isRepository(ref) ? ref : try repository(named: ref)
    return (try checkout(of: repository, hint: "Pass its folder as --repo"), repository)
  }

  /// The `owner/name` of the one repository called `name`: a key of the
  /// `repos` setting, or a <root>/<owner>/<name> folder under `repoRoots`
  /// with a github.com remote for owner/name.
  private func repository(named name: String) throws -> String {
    guard !name.contains("/"), name != ".", name != ".." else {
      throw APIError("\(name) isn't a repository. Use owner/name, a name, or a folder")
    }
    var found: [String: String] = [:]
    for key in config.repos.keys where key.split(separator: "/").last?.lowercased() == name.lowercased() {
      found[key.lowercased()] = key
    }
    for root in config.repoRoots.map({ ($0.expandingTilde as NSString).standardizingPath }) {
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
