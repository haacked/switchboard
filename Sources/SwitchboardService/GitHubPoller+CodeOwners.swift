import Foundation
import SwitchboardCore

/// Whether each session's open PR needs a code owner review. The poller
/// reads a base branch's config, a PR's changed files, and the teams of each
/// approval, and keeps each read for as long as it can't change.
/// `plans/codeowner-shield.md` in the notes repo describes the rules.
extension GitHubPoller {
  struct CodeOwnerReads {
    struct ConfigKey: Hashable {
      var repo: String
      var base: String
    }

    struct FilesKey: Hashable {
      var prId: String
      var head: String
      var base: String
    }

    struct TeamsKey: Hashable {
      var prId: String
      var author: String
      var submittedAt: String?
    }

    /// Each base branch's config, and when the poller read it. A failed read
    /// keeps the last one.
    var configs: [ConfigKey: (config: CodeOwnersConfig, read: Int64)] = [:]
    /// A head and a base fix a PR's diff, so the poller reads a key's files once.
    var files: [FilesKey: (paths: [String], total: Int)] = [:]
    /// The teams that each verdict was on behalf of, as `org/team`.
    var teams: [TeamsKey: [String]] = [:]
  }

  /// Reads the configs that are due, the changed files that no read holds,
  /// and the teams of approvals that no read holds, for the open PRs that
  /// sessions name. A failed read leaves its key unread and moves on to the
  /// next key. Returns the first failure.
  func readCodeOwners(all: Bool, now: Int64, stats: inout Stats) -> String? {
    var failure: String?
    let open = Set(tracked.values.compactMap(\.prId)).sorted().compactMap { prs[$0]?.pr }.filter { $0.state == .open }
    var seen: Set<CodeOwnerReads.ConfigKey> = []
    for key in open.map(configKey) where seen.insert(key).inserted {
      guard all || GitHub.elapsed(since: codeOwners.configs[key]?.read, settings.idleMs, now: now) else { continue }
      do {
        let response = try request(GitHub.codeOwnersConfigQuery, configVariables(key), stats: &stats)
        codeOwners.configs[key] = (try GitHub.parseCodeOwnersConfig(response), now)
      } catch {
        failure = failure ?? "code owners of \(key.repo) \(key.base): \(error)"
      }
    }
    let unread = open.filter {
      guard case .on? = codeOwners.configs[configKey($0)]?.config else { return false }
      return codeOwners.files[filesKey($0)] == nil
    }
    for chunk in GitHub.chunks(unread.map(\.id)) {
      do {
        let response = try request(GitHub.filesQuery, idsVariable(chunk), stats: &stats)
        let nodes = response["data"]?["nodes"]?.array ?? []
        for (i, id) in chunk.enumerated() {
          do {
            try readFiles(id, first: i < nodes.count ? nodes[i] : .null, response, stats: &stats)
          } catch {
            failure = failure ?? "\(error)"
          }
        }
      } catch {
        failure = failure ?? "changed files: \(error)"
      }
    }
    let approved = open.filter { pr in
      requirement(pr) != nil && pr.verdicts.contains { $0.state == "APPROVED" && teams(pr.id, $0) == nil }
    }
    for chunk in GitHub.chunks(approved.map(\.id)) {
      do {
        let response = try request(GitHub.approvalTeamsQuery, idsVariable(chunk), stats: &stats)
        let nodes = response["data"]?["nodes"]?.array ?? []
        for (i, id) in chunk.enumerated() {
          guard i < nodes.count, nodes[i] != .null else {
            failure = failure ?? "GitHub failed to read the approvals of \(id): \(GitHub.message(response))"
            continue
          }
          for review in GitHub.parseApprovalTeams(nodes[i]) {
            let key = CodeOwnerReads.TeamsKey(prId: id, author: review.author, submittedAt: review.submittedAt)
            codeOwners.teams[key] = review.teams
          }
        }
      } catch {
        failure = failure ?? "approvals: \(error)"
      }
    }
    return failure
  }

  /// Keeps a PR's changed files under the head and base that their first
  /// page answered, after reading the later pages. A page with another head
  /// or base means a push or a retarget between two pages, and the poller
  /// keeps none of the pages.
  private func readFiles(_ id: String, first node: JSON, _ response: JSON, stats: inout Stats) throws {
    guard let head = node["headRefOid"]?.string, let base = node["baseRefName"]?.string,
      var page = GitHub.parseFiles(node)
    else { throw APIError("GitHub failed to read the changed files of \(id): \(GitHub.message(response))") }
    var paths = page.paths
    // Each page holds up to 100 files, so 10 pages reach `CodeOwners.maxFiles`.
    var pages = 1
    while let next = page.next, page.total <= CodeOwners.maxFiles, pages < CodeOwners.maxFiles / 100 {
      let response = try request(GitHub.filesPageQuery, ["id": .string(id), "after": .string(next)], stats: &stats)
      guard let node = response["data"]?["node"], let read = GitHub.parseFiles(node) else {
        throw APIError("GitHub failed to read the changed files of \(id): \(GitHub.message(response))")
      }
      guard node["headRefOid"]?.string == head, node["baseRefName"]?.string == base else { return }
      paths += read.paths
      page = read
      pages += 1
    }
    codeOwners.files[CodeOwnerReads.FilesKey(prId: id, head: head, base: base)] = (paths, page.total)
  }

  /// Sets each PR's code owner requirement and its verdicts' teams from the
  /// reads. A PR that no session names, or that isn't open, gets none. So
  /// does a PR with an approval whose teams no read holds, because that
  /// approval could be the one that a group waits for.
  func applyCodeOwners() {
    let named = Set(tracked.values.compactMap(\.prId))
    for id in prs.keys {
      var pr = prs[id]!.pr
      for i in pr.verdicts.indices { pr.verdicts[i].teams = teams(id, pr.verdicts[i]) }
      let unread = pr.verdicts.contains { $0.state == "APPROVED" && $0.teams == nil }
      pr.codeOwners = named.contains(id) && pr.state == .open && !unread ? requirement(pr) : nil
      prs[id]!.pr = pr
    }
  }

  /// Keeps only the reads of the PRs in `prs` at their current head and base.
  func pruneCodeOwners() {
    let read = prs.values.map(\.pr)
    let configs = Set(read.map(configKey))
    let files = Set(read.map(filesKey))
    let teams = Set(
      read.flatMap { pr in
        pr.verdicts.map { CodeOwnerReads.TeamsKey(prId: pr.id, author: $0.author, submittedAt: $0.submittedAt) }
      })
    codeOwners.configs = codeOwners.configs.filter { configs.contains($0.key) }
    codeOwners.files = codeOwners.files.filter { files.contains($0.key) }
    codeOwners.teams = codeOwners.teams.filter { teams.contains($0.key) }
  }

  private func requirement(_ pr: PullRequest) -> CodeOwnerRequirement? {
    guard let config = codeOwners.configs[configKey(pr)]?.config, let files = codeOwners.files[filesKey(pr)] else {
      return nil
    }
    return CodeOwners.requirement(config, paths: files.paths, total: files.total)
  }

  private func teams(_ prId: String, _ verdict: Review) -> [String]? {
    codeOwners.teams[CodeOwnerReads.TeamsKey(prId: prId, author: verdict.author, submittedAt: verdict.submittedAt)]
  }

  private func configKey(_ pr: PullRequest) -> CodeOwnerReads.ConfigKey {
    CodeOwnerReads.ConfigKey(repo: pr.repo, base: pr.base)
  }

  private func filesKey(_ pr: PullRequest) -> CodeOwnerReads.FilesKey {
    CodeOwnerReads.FilesKey(prId: pr.id, head: pr.headSha, base: pr.base)
  }

  private func configVariables(_ key: CodeOwnerReads.ConfigKey) -> JSON {
    let parts = key.repo.split(separator: "/", maxSplits: 1).map(String.init)
    return [
      "owner": .string(parts.first ?? ""), "name": .string(parts.count > 1 ? parts[1] : ""), "ref": .string(key.base),
      "github": .string("\(key.base):.github/CODEOWNERS"), "root": .string("\(key.base):CODEOWNERS"),
      "docs": .string("\(key.base):docs/CODEOWNERS"),
    ]
  }
}
