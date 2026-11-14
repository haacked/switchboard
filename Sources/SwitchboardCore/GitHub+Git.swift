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
    var branches: Set<String> = []
    for line in reflog.split(separator: "\n") {
      guard let tab = line.firstIndex(of: "\t"), let move = switchEntry(line[line.index(after: tab)...]) else {
        continue
      }
      branches.insert(move.from)
      branches.insert(move.to)
    }
    return branches
  }

  /// The two branches of a reflog message that moved HEAD from one branch to
  /// another: a checkout or a rename of the checked-out branch.
  static func switchEntry(_ message: Substring) -> (from: String, to: String)? {
    let heads = "refs/heads/"
    if message.hasPrefix("checkout: moving from ") {
      let names = message.dropFirst("checkout: moving from ".count).split(separator: " ")
      guard names.count == 3, names[1] == "to" else { return nil }
      return (String(names[0]), String(names[2]))
    }
    if message.hasPrefix("Branch: renamed ") {
      let names = message.dropFirst("Branch: renamed ".count).split(separator: " ")
      guard names.count == 3, names[1] == "to", names[0].hasPrefix(heads), names[2].hasPrefix(heads) else { return nil }
      return (String(names[0].dropFirst(heads.count)), String(names[2].dropFirst(heads.count)))
    }
    return nil
  }

  /// Whether the PR belongs to the session's earlier work in this folder: it
  /// is in the branch's repo, its head is another branch, and the folder had
  /// that head checked out before.
  public static func isEarlierWork(_ pr: PullRequest, repo: String, branch: String, checkedOut: Set<String>) -> Bool {
    pr.repo.lowercased() == repo.lowercased() && pr.head != branch && checkedOut.contains(pr.head)
  }

  /// Whether a linked or recorded PR counts as the session's while its
  /// branch has no PR of its own.
  public enum EarlierStanding: Equatable, Sendable {
    /// The PR counts: it is not earlier work, or the folder made its head
    /// commit on the current branch.
    case current
    /// The PR is open earlier work. It does not count now, and a later head
    /// that the folder made brings it back.
    case hidden
    /// The PR is merged or closed earlier work, and it stops counting for good.
    case dropped
  }

  /// `made` is what `commitsSinceSwitch` gives for the folder's branch.
  public static func earlierStanding(
    _ pr: PullRequest, repo: String, branch: String, checkedOut: Set<String>, made: Set<String>?
  ) -> EarlierStanding {
    guard isEarlierWork(pr, repo: repo, branch: branch, checkedOut: checkedOut) else { return .current }
    if !pr.headSha.isEmpty, made?.contains(pr.headSha) == true { return .current }
    return pr.state == .open ? .hidden : .dropped
  }

  /// Whether a reflog message records a new commit. A reset, a checkout, a
  /// fast-forward, and a rebase's start and finish only move HEAD to a commit
  /// that already exists.
  static func makesCommit(_ message: Substring) -> Bool {
    if ["commit", "cherry-pick", "revert"].contains(where: { message.hasPrefix($0) }) { return true }
    if message.hasPrefix("rebase") || message.hasPrefix("pull --rebase") {
      return !["(start)", "(finish)", "(abort)"].contains(where: { message.contains($0) })
    }
    if message.hasPrefix("merge ") || message.hasPrefix("pull:") || message.hasPrefix("pull ") {
      return !message.hasSuffix("Fast-forward")
    }
    return false
  }

  /// The commits that a HEAD reflog shows the folder made after the last
  /// entry that moved HEAD to `branch`: a checkout or a rename. The commit
  /// that the switch itself moved to is not one of them. nil when no entry
  /// moved HEAD to `branch`.
  public static func commitsSinceSwitch(reflog: String, to branch: String) -> Set<String>? {
    var made: Set<String>?
    for line in reflog.split(separator: "\n") {
      guard let tab = line.firstIndex(of: "\t") else { continue }
      let message = line[line.index(after: tab)...]
      if switchEntry(message)?.to == branch {
        made = []
        continue
      }
      guard made != nil, makesCommit(message) else { continue }
      let fields = line[..<tab].split(separator: " ")
      if fields.count >= 2 { made?.insert(String(fields[1])) }
    }
    return made
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
