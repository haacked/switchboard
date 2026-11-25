import Foundation

/// The `gitlab` object in config.json.
public struct GitLabSettings: Codable, Equatable, Sendable {
  /// Hosts that count as GitLab besides gitlab.com and any host whose name
  /// contains "gitlab", such as `git.example.com`.
  public var hosts: [String] = []
  /// The glab that `glab config get token` runs from. A name without a slash
  /// is looked up on PATH, then in Homebrew's and the system's bin folders.
  public var glab: String = "glab"

  public init() {}

  /// The hosts from `hosts`, lowercased.
  public var hostSet: Set<String> { Set(hosts.map { $0.lowercased() }) }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = GitLabSettings()
    hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? d.hosts
    glab = try c.decodeIfPresent(String.self, forKey: .glab) ?? d.glab
  }
}

/// A GitLab merge request, named by its page URL.
public enum GitLab {
  public struct Ref: Equatable, Sendable {
    public var host: String
    public var project: String
    public var number: Int

    public init(host: String, project: String, number: Int) {
      self.host = host
      self.project = project
      self.number = number
    }
  }

  /// A remote on gitlab.com, on a host whose name contains "gitlab", or on
  /// one of `extraHosts`. The project path keeps every `group/sub/name` part.
  public static func remote(remoteURL: String, extraHosts: Set<String> = []) -> (host: String, project: String)? {
    guard let (host, path) = GitHub.remoteParts(remoteURL), isHost(host, extraHosts: extraHosts) else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return (host, parts.joined(separator: "/"))
  }

  /// The project path of `remote(remoteURL:extraHosts:)`, or nil.
  public static func project(remoteURL: String, extraHosts: Set<String> = []) -> String? {
    remote(remoteURL: remoteURL, extraHosts: extraHosts)?.project
  }

  /// Whether `host` is a GitLab host. github.com never is, even when
  /// `extraHosts` names it.
  public static func isHost(_ host: String, extraHosts: Set<String> = []) -> Bool {
    let host = host.lowercased()
    if host == "github.com" || host == "ssh.github.com" { return false }
    if host == "gitlab.com" || host.contains("gitlab") { return true }
    return extraHosts.contains(host)
  }

  /// Whether `id` is a merge request page that `ref(_:)` reads.
  public static func isMR(_ id: String) -> Bool { ref(id) != nil }

  /// Reads an `http` or `https` merge request page, in any case, which may
  /// end in a further path such as `/diffs`, a query, or a fragment. The
  /// project path may hold subgroups. A host is accepted from the URL, so a
  /// self-hosted page doesn't need to be listed in `gitlab.hosts`.
  public static func ref(_ text: String) -> Ref? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host?.lowercased(), !host.isEmpty
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard let marker = parts.firstIndex(of: "-"), marker + 2 < parts.count, parts[marker + 1] == "merge_requests",
      let number = Int(parts[marker + 2]), number > 0, String(number) == parts[marker + 2]
    else { return nil }
    let project = parts[..<marker]
    guard project.count >= 2, project.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return Ref(host: host, project: project.joined(separator: "/"), number: number)
  }

  /// The merge request's page, which is also the id the poller stores.
  public static func page(host: String, project: String, number: Int) -> String {
    "https://\(host)/\(project)/-/merge_requests/\(number)"
  }

  /// The project path as a GitLab API project id: each slash is `%2F`.
  public static func pathID(_ project: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return project.addingPercentEncoding(withAllowedCharacters: allowed) ?? project
  }

  /// The merge request to keep from a list already ordered newest first. An
  /// open one wins. When `sourceProjectID` is set, a merge request from
  /// another source project is a different fork's and doesn't count.
  public static func choose(_ list: [JSON], sourceProjectID: Int?) -> JSON? {
    let mine = list.filter { mr in
      guard let sourceProjectID else { return true }
      return mr["source_project_id"]?.int == sourceProjectID
    }
    return mine.first { $0["state"]?.string == "opened" } ?? mine.first
  }

  /// The merge request as the poller stores it. `project` is the project the
  /// lookup asked, so the stored repo matches the branch key. `approvals` is
  /// the approvals endpoint, or nil when that read failed. A nil read leaves
  /// the review decision unread, so the next poll tries again.
  public static func pullRequest(mr: JSON, approvals: JSON?, host: String, project: String) -> PullRequest? {
    guard let number = mr["iid"]?.int, number > 0 else { return nil }
    let canonical = page(host: host, project: project, number: number)
    let review = review(of: approvals)
    return PullRequest(
      id: canonical, number: number, url: mr["web_url"]?.string ?? canonical, repo: project,
      title: mr["title"]?.string ?? "", state: state(of: mr),
      draft: mr["draft"]?.bool == true || mr["work_in_progress"]?.bool == true,
      head: mr["source_branch"]?.string ?? "", headSha: mr["sha"]?.string ?? "",
      base: mr["target_branch"]?.string ?? "", defaultBranch: nil, mergeable: mergeable(of: mr),
      reviewDecision: review.decision, verdicts: review.verdicts, labels: labels(of: mr), checks: checks(of: mr),
      mergedAt: mr["merged_at"]?.string, closedAt: mr["closed_at"]?.string,
      mergeCommit: mr["merge_commit_sha"]?.string,
      reviewDecisionRead: review.read, author: mr["author"]?["username"]?.string)
  }

  /// Whether GitLab can merge the branch. A conflict or a needed rebase is
  /// the conflicting state the board shows. A status GitLab is still
  /// computing is unknown, so the poller reads the merge request again soon.
  /// Anything else, including a review or a pipeline that still blocks the
  /// merge, is mergeable: those show through the review decision and the checks.
  public static func mergeable(of mr: JSON) -> Mergeable {
    switch mr["detailed_merge_status"]?.string {
    case "conflict", "need_rebase":
      return .conflicting
    case "unchecked", "checking", "preparing", "approvals_syncing", "checking_merge_request_status":
      return .unknown
    case nil:
      switch mr["merge_status"]?.string {
      case "can_be_merged": return .mergeable
      case "cannot_be_merged": return .conflicting
      default: return .unknown
      }
    default:
      return .mergeable
    }
  }

  /// The head pipeline as a GitHub check rollup. A skipped pipeline counts as
  /// passed, which is when GitLab lets the merge request merge. A canceled
  /// one is neither a pass nor a failure.
  public static func checks(of mr: JSON) -> String? {
    let pipeline = mr["head_pipeline"]
    guard let pipeline, pipeline != .null else { return nil }
    switch pipeline["status"]?.string {
    case "success", "skipped": return "SUCCESS"
    case "failed": return "FAILURE"
    case "created", "waiting_for_resource", "preparing", "pending", "running", "manual", "scheduled":
      return "PENDING"
    default: return nil
    }
  }

  static func state(of mr: JSON) -> PRState {
    switch mr["state"]?.string {
    case "merged": .merged
    case "closed": .closed
    default: .open
    }
  }

  static func labels(of mr: JSON) -> [String] {
    (mr["labels"]?.array ?? []).compactMap { $0["name"]?.string ?? $0.string }
  }

  /// The review decision from the approvals endpoint. No required approval
  /// and no approval leaves the decision empty and marked as read, which the
  /// board treats as no review needed. An approval that wasn't required still counts.
  static func review(of approvals: JSON?) -> (decision: ReviewDecision?, read: Bool?, verdicts: [Review]) {
    guard let approvals, approvals != .null else { return (nil, nil, []) }
    let required = approvals["approvals_required"]?.int ?? 0
    let users = (approvals["approved_by"]?.array ?? []).compactMap { item -> Review? in
      let name = item["user"]?["username"]?.string ?? item["username"]?.string
      guard let name, !name.isEmpty else { return nil }
      return Review(author: name, state: "APPROVED")
    }
    if approvals["approved"]?.bool == true || !users.isEmpty { return (.approved, true, users) }
    if required > 0 { return (.reviewRequired, true, []) }
    return (nil, true, [])
  }
}
