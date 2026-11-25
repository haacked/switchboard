import Foundation
import SwitchboardCore

/// Looks up and reads GitLab merge requests. The token comes from `glab`, or
/// from `GITLAB_TOKEN` for the host that variable applies to. A failure of
/// one merge request is logged and skipped, so a GitLab problem doesn't drop
/// the GitHub reads in the same poll.
extension GitHubPoller {
  /// The node id of each key's merge request, or nil when the project has
  /// none. A key whose request failed is left out, so the next poll asks again.
  func lookUpGitLab(_ keys: [PRKey]) -> [PRKey: String?] {
    var found: [PRKey: String?] = [:]
    for key in keys {
      do {
        switch key {
        case .gitlabBranch(let host, let project, let branch, let source):
          found[key] = try gitlabBranchID(host: host, project: project, branch: branch, source: source)
        case .gitlabNumber(let host, let project, let number):
          found[key] = try gitlabNumberID(host: host, project: project, number: number)
        case .branch, .number:
          break
        }
      } catch {
        logLine("gitlab: \(error)")
      }
    }
    return found
  }

  /// Reads each merge request and stores it. Returns the ids GitLab reports
  /// gone. A merge request whose read fails in another way keeps its last read.
  func readGitLab(_ ids: [String], now: Int64) -> Set<String> {
    var gone: Set<String> = []
    for id in ids {
      guard let ref = GitLab.ref(id) else { continue }
      do {
        let (status, json) = try gitlabGET(
          ref.host, "projects/\(GitLab.pathID(ref.project))/merge_requests/\(ref.number)")
        if status == 404 {
          gone.insert(id)
          continue
        }
        guard status == 200, let json else {
          logLine("gitlab: \(ref.project)!\(ref.number) answered \(status) \(GitHub.message(json))")
          continue
        }
        let approvals = gitlabApprovals(ref)
        guard let pr = GitLab.pullRequest(mr: json, approvals: approvals, host: ref.host, project: ref.project) else {
          continue
        }
        store(pr, comments: [], polled: now)
      } catch {
        logLine("gitlab: \(error)")
      }
    }
    return gone
  }

  /// Merges the merge request when its head is still `pr.headSha`. GitLab
  /// refuses the merge otherwise. Returns by throwing GitLab's error.
  func mergeGitLab(_ pr: PullRequest) throws {
    guard let ref = GitLab.ref(pr.id) else { throw APIError("\(pr.url) is not a GitLab merge request") }
    let (status, json) = try gitlabSend(
      ref.host, "projects/\(GitLab.pathID(ref.project))/merge_requests/\(ref.number)/merge", method: "PUT",
      body: .object(["sha": .string(pr.headSha)]))
    guard status == 200 || status == 201 else {
      throw APIError("GitLab answered \(status) \(GitHub.message(json))")
    }
  }

  private func gitlabBranchID(host: String, project: String, branch: String, source: String) throws -> String? {
    let sourceID: Int?
    if source.lowercased() == project.lowercased() {
      sourceID = nil
    } else {
      sourceID = try gitlabProjectID(host: host, project: source)
      if sourceID == nil { return nil }
    }
    let opened = try gitlabMergeRequests(host: host, project: project, branch: branch, state: "opened")
    let list =
      opened.isEmpty
      ? try gitlabMergeRequests(host: host, project: project, branch: branch, state: "all") : opened
    guard let mr = GitLab.choose(list, sourceProjectID: sourceID), let number = mr["iid"]?.int else { return nil }
    return GitLab.page(host: host, project: project, number: number)
  }

  private func gitlabNumberID(host: String, project: String, number: Int) throws -> String? {
    let (status, _) = try gitlabGET(host, "projects/\(GitLab.pathID(project))/merge_requests/\(number)")
    if status == 404 { return nil }
    guard status == 200 else { throw APIError("GitLab \(host) \(project)!\(number) answered \(status)") }
    return GitLab.page(host: host, project: project, number: number)
  }

  private func gitlabMergeRequests(host: String, project: String, branch: String, state: String) throws -> [JSON] {
    let (status, json) = try gitlabGET(
      host, "projects/\(GitLab.pathID(project))/merge_requests",
      [
        "source_branch": branch, "state": state, "scope": "all", "order_by": "created_at", "sort": "desc",
        "per_page": "20",
      ])
    if status == 404 { return [] }
    guard status == 200, let list = json?.array else {
      throw APIError("GitLab \(host) \(project) merge requests answered \(status) \(GitHub.message(json))")
    }
    return list
  }

  /// The source project's id, or nil when GitLab has no such project. The id
  /// is cached for the life of this sbd.
  private func gitlabProjectID(host: String, project: String) throws -> Int? {
    let key = "\(host)\n\(project.lowercased())"
    if let id = gitlabProjectIDs[key] { return id }
    let (status, json) = try gitlabGET(host, "projects/\(GitLab.pathID(project))")
    if status == 404 { return nil }
    guard status == 200, let id = json?["id"]?.int else {
      throw APIError("GitLab \(host) projects/\(project) answered \(status) \(GitHub.message(json))")
    }
    gitlabProjectIDs[key] = id
    return id
  }

  /// The approvals object, or nil when the read failed. A 404 means the
  /// merge request needs no approval rules.
  private func gitlabApprovals(_ ref: GitLab.Ref) -> JSON? {
    do {
      let (status, json) = try gitlabGET(
        ref.host, "projects/\(GitLab.pathID(ref.project))/merge_requests/\(ref.number)/approvals")
      if status == 404 { return .object(["approvals_required": .number(0), "approved": .bool(false)]) }
      guard status == 200 else {
        logLine("gitlab: approvals for \(ref.project)!\(ref.number) answered \(status)")
        return nil
      }
      return json
    } catch {
      logLine("gitlab: approvals for \(ref.project)!\(ref.number): \(error)")
      return nil
    }
  }

  private func gitlabGET(_ host: String, _ path: String, _ query: [String: String] = [:]) throws -> (Int, JSON?) {
    try gitlabSend(host, path, method: "GET", query: query, body: nil)
  }

  private func gitlabSend(_ host: String, _ path: String, method: String, query: [String: String] = [:], body: JSON?)
    throws -> (Int, JSON?)
  {
    if gitlabHTTP.withLock({ $0.pausedUntil }) > nowMs() { throw APIError("paused after a GitLab rate limit") }
    guard let url = gitlabURL(host, path, query) else { throw APIError("bad GitLab url \(host) \(path)") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = Data(body.text.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let credential = try gitlabCredential(host)
    func attempt(_ privateToken: Bool) throws -> (Int, [String: String], Data) {
      var req = request
      if privateToken {
        req.setValue(credential.token, forHTTPHeaderField: "PRIVATE-TOKEN")
      } else {
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
      }
      return try transport(req)
    }
    var (status, headers, data) = try attempt(credential.privateToken)
    if status == 401 {
      let flipped = !credential.privateToken
      gitlabHTTP.withLock { $0.credentials[host] = nil }
      (status, headers, data) = try attempt(flipped)
      if status != 401 {
        gitlabHTTP.withLock {
          $0.credentials[host] = GitLabCredential(token: credential.token, privateToken: flipped)
        }
      }
    }
    if status == 429 {
      let retry = headers["retry-after"].flatMap(Double.init) ?? 60
      let until = nowMs() + Int64(retry * 1000)
      gitlabHTTP.withLock { $0.pausedUntil = max($0.pausedUntil, until) }
      throw APIError("GitLab rate limit")
    }
    return (status, JSON.parse(data))
  }

  private func gitlabURL(_ host: String, _ path: String, _ query: [String: String]) -> URL? {
    var text = "https://\(host)/api/v4/\(path)"
    if !query.isEmpty {
      let items = query.keys.sorted().map { key in
        let value =
          query[key]?.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
        return "\(key.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? key)=\(value)"
      }
      text += "?" + items.joined(separator: "&")
    }
    return URL(string: text)
  }

  /// Unreserved characters, so a branch name's slash is encoded and `%2F` in
  /// a project id is left to the path, which is already encoded.
  private var queryAllowed: CharacterSet {
    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
  }

  private func gitlabCredential(_ host: String) throws -> GitLabCredential {
    if let cached = gitlabHTTP.withLock({ $0.credentials[host] }) { return cached }
    guard let token = gitlabToken(host) else {
      throw APIError("no GitLab token for \(host); run `glab auth login`")
    }
    let credential = GitLabCredential(token: token, privateToken: false)
    gitlabHTTP.withLock { $0.credentials[host] = credential }
    return credential
  }

  /// `glab config get token` for the host, else `GITLAB_TOKEN` when that
  /// variable applies to the host. glab's own lookup reads the environment
  /// first, then the global config that `glab auth login` writes.
  private func gitlabToken(_ host: String) -> String? {
    if let glab = findExecutable(gitlab.glab),
      let result = try? runCommand(glab, ["config", "get", "token", "--host", host]), result.status == 0
    {
      let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      if !token.isEmpty, !token.contains(where: \.isWhitespace) { return token }
    } else if findExecutable(gitlab.glab) == nil {
      let warn = gitlabHTTP.withLock { state -> Bool in
        if state.missingCLI { return false }
        state.missingCLI = true
        return true
      }
      if warn {
        logLine(
          "gitlab: can't find \(gitlab.glab); merge requests aren't read until glab is installed and signed in")
      }
    }
    return gitlabTokenFromEnvironment(host)
  }

  /// `GITLAB_TOKEN` applies to gitlab.com, or to the host `GITLAB_HOST` names.
  private func gitlabTokenFromEnvironment(_ host: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    let named = env["GITLAB_HOST"] ?? env["GITLAB_URI"] ?? env["GL_HOST"]
    let applies = named.map { gitlabHost($0) == host } ?? (host == "gitlab.com")
    guard applies else { return nil }
    for key in ["GITLAB_TOKEN", "GITLAB_ACCESS_TOKEN", "OAUTH_TOKEN"] {
      let token = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !token.isEmpty, !token.contains(where: \.isWhitespace) { return token }
    }
    return nil
  }

  /// The host of a GitLab address, which may be a bare hostname or a URL.
  private func gitlabHost(_ text: String) -> String {
    if let host = URL(string: text)?.host?.lowercased(), text.contains("://") { return host }
    return text.lowercased().split(separator: "/").first.map(String.init) ?? text.lowercased()
  }
}
