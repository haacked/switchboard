import Foundation

extension GitHub {
  /// Splits `owner/name`. A repo without a slash has an empty name.
  public static func ownerAndName(_ repo: String) -> (owner: String, name: String) {
    let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
    return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
  }

  /// GitHub's SSH host for port 443 counts as github.com.
  static let githubHosts: Set<String> = ["github.com", "ssh.github.com"]

  /// owner/name for a GitHub remote URL in the https, ssh, or scp form, or
  /// nil for any other host. As in git, an address with a slash before its
  /// first colon is a local path, not the scp form.
  public static func repo(remoteURL: String) -> String? {
    let authority: Substring
    var path: Substring
    if let scheme = remoteURL.range(of: "://") {
      let rest = remoteURL[scheme.upperBound...]
      let slash = rest.firstIndex(of: "/") ?? rest.endIndex
      authority = rest[..<slash]
      path = rest[slash...]
    } else if let colon = remoteURL.firstIndex(of: ":"), !remoteURL[..<colon].contains("/") {
      authority = remoteURL[..<colon]
      path = remoteURL[remoteURL.index(after: colon)...]
    } else {
      return nil
    }
    var host = authority.split(separator: "@").last ?? ""
    if let port = host.firstIndex(of: ":") { host = host[..<port] }
    guard githubHosts.contains(host.lowercased()) else { return nil }
    path = path.drop { $0 == "/" }
    if path.hasSuffix("/") { path = path.dropLast() }
    if path.hasSuffix(".git") { path = path.dropLast(4) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return parts.joined(separator: "/")
  }

  /// The branch that a HEAD file names, or nil for a detached HEAD. A
  /// remote's HEAD file names a branch under refs/remotes/<remote>/.
  public static func branch(head: String, under refs: String = "refs/heads/") -> String? {
    let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("ref: \(refs)") else { return nil }
    return String(text.dropFirst("ref: \(refs)".count))
  }

  /// The branches that a HEAD reflog shows the folder had checked out: both
  /// sides of each checkout, and both names of each rename of the
  /// checked-out branch. git writes one "checkout: moving from <a> to <b>"
  /// line for each checkout or switch. A detach shows as `HEAD`, and a
  /// checkout from a detached HEAD shows as a commit id. `git branch -m` on
  /// the checked-out branch writes "Branch: renamed refs/heads/<a> to
  /// refs/heads/<b>".
  public static func checkedOutBranches(reflog: String) -> Set<String> {
    let checkout = "\tcheckout: moving from "
    let renamed = "\tBranch: renamed "
    let heads = "refs/heads/"
    var branches: Set<String> = []
    for line in reflog.split(separator: "\n") {
      if let range = line.range(of: checkout) {
        let names = line[range.upperBound...].split(separator: " ")
        guard names.count == 3, names[1] == "to" else { continue }
        branches.insert(String(names[0]))
        branches.insert(String(names[2]))
      } else if let range = line.range(of: renamed) {
        let names = line[range.upperBound...].split(separator: " ")
        guard names.count == 3, names[1] == "to", names[0].hasPrefix(heads), names[2].hasPrefix(heads) else { continue }
        branches.insert(String(names[0].dropFirst(heads.count)))
        branches.insert(String(names[2].dropFirst(heads.count)))
      }
    }
    return branches
  }

  /// The values of `git config --get-regexp` output, by key.
  public static func gitConfig(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      values[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return values
  }

  /// The name that `branch`'s `merge` config gives its upstream branch,
  /// without `refs/heads/`, or nil when the config names none.
  public static func upstreamName(of branch: String, config: [String: String]) -> String? {
    let heads = "refs/heads/"
    return config["branch.\(branch).merge"].map { String($0.dropFirst($0.hasPrefix(heads) ? heads.count : 0)) }
  }

  /// The key of the branch's PR, as `git pr` finds it: the PR from the
  /// branch's upstream name in gh's base repo, whose head repository belongs
  /// to the owner of the branch's push remote. `config` holds the git config
  /// values by key, and `remoteHead` gives a remote's default branch. nil
  /// when the push remote isn't on GitHub, or when the branch is the push
  /// remote's default branch.
  public static func branchKey(branch: String, config: [String: String], remoteHead: (String) -> String?) -> PRKey? {
    let b = "branch.\(branch)"
    var push = config["\(b).pushremote"] ?? config["remote.pushdefault"] ?? config["\(b).remote"] ?? "origin"
    var upstream = upstreamName(of: branch, config: config) ?? branch
    // "." means that the branch tracks a local branch.
    if push == "." {
      push = "origin"
      upstream = branch
    }
    guard let head = config["remote.\(push).url"].flatMap(repo(remoteURL:)), remoteHead(push) != upstream else {
      return nil
    }
    // gh asks the remote that `gh repo set-default` marked, then upstream,
    // then origin. A branch pushed to a fork has its PR in that repo.
    let remotes = config.keys.compactMap { key -> String? in
      guard key.hasPrefix("remote."), key.hasSuffix(".url") else { return nil }
      return String(key.dropFirst("remote.".count).dropLast(".url".count))
    }
    let base =
      remotes.first { config["remote.\($0).gh-resolved"] == "base" }
      ?? ["upstream", "origin"].first(where: remotes.contains)
    let baseRepo = base.flatMap { config["remote.\($0).url"] }.flatMap(repo(remoteURL:)) ?? head
    return .branch(repo: baseRepo, branch: upstream, owner: String(head.split(separator: "/")[0]))
  }
}
