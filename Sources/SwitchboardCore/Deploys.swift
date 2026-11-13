import Foundation

/// An environment that PostHog deploys to.
public enum DeployEnvironment: String, CaseIterable, Codable, Sendable {
  case dev
  case prodUS = "prod-us"
  case prodEU = "prod-eu"

  /// The environments that a deploy wait names. `prod` names both prod regions.
  public static func named(_ name: String) -> [DeployEnvironment]? {
    name == "prod" ? [.prodUS, .prodEU] : DeployEnvironment(rawValue: name).map { [$0] }
  }
}

/// How far a PR's change got in one environment. The deploy comment and a
/// named service's state file, compare result, and charts run all map to
/// these states.
public enum DeployState: String, Codable, Sendable {
  /// No deploy that carries the change has started.
  case pending
  /// A deploy that carries the change started, and no sync job has reported
  /// that it finished.
  case deploying
  case deployed
  /// The sync of the deploy that carries the change failed.
  case failed
  /// The merge commit isn't on the branch that the service deploys from.
  case offBranch = "off-branch"
  /// The state file doesn't say which commit the environment runs.
  case unknown

  /// A named service's state in one environment. `ancestry` compares the
  /// commit that the environment runs with the PR's merge commit. `sync` is
  /// the environment's state in the charts run that deploys that commit, or
  /// nil when no such run or job exists. A cancelled or skipped sync stays
  /// `deploying`, because ArgoCD still syncs the commit that the state file
  /// names.
  public init(ancestry: DeployedAncestry, sync: ChartsDeployJobs.State?) {
    switch (ancestry, sync) {
    case (.notYet, _): self = .pending
    case (.diverged, _): self = .offBranch
    case (.contains, .succeeded): self = .deployed
    case (.contains, .failed): self = .failed
    case (.contains, _): self = .deploying
    }
  }
}

/// The "Deploy status" comment that deployment-status-posthog[bot] keeps on a
/// merged PostHog/posthog PR. PostHog/charts writes it with
/// scripts/notify-pr-deployed.sh after the main posthog app syncs in an
/// environment. It names every PR in the deployed commit range, so it says
/// nothing about a service that deploys on its own.
public struct DeployComment: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case deployed
    case pending
    /// The bot created the comment at a prod deploy, so it never saw dev.
    case unknown
    /// A status that the parser doesn't know.
    case unrecognized(String)
  }

  /// The comment's first line. The bot finds its own comment by it.
  public static let marker = "<!-- deploy-notify-bot -->"

  /// The status that each environment's row of the table shows.
  public var rows: [DeployEnvironment: Status]

  public static func parse(_ body: String) -> DeployComment? {
    guard body.hasPrefix(marker) else { return nil }
    var rows: [DeployEnvironment: Status] = [:]
    for line in body.split(whereSeparator: \.isNewline) {
      // | **dev** | :white_check_mark: Deployed | 2026-10-23 22:20 UTC | [Run](<url>) |
      let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard cells.count >= 5,
        let environment = DeployEnvironment(rawValue: cells[1].replacingOccurrences(of: "*", with: ""))
      else { continue }
      rows[environment] =
        switch cells[2] {
        case ":white_check_mark: Deployed": .deployed
        case ":hourglass_flowing_sand: Pending": .pending
        case ":grey_question: Unknown": .unknown
        default: .unrecognized(cells[2])
        }
    }
    return DeployComment(rows: rows)
  }

  /// A dev row of Unknown counts as deployed once a prod row says Deployed,
  /// because charts deploys prod only after dev succeeds in the same run. A
  /// failed deploy leaves its row Pending, so the comment never reports a
  /// failure.
  public func state(in environment: DeployEnvironment) -> DeployState {
    switch rows[environment] {
    case .deployed: .deployed
    case .unknown where environment == .dev:
      [.prodUS, .prodEU].contains { state(in: $0) == .deployed } ? .deployed : .pending
    default: .pending
    }
  }
}

/// What PostHog/charts `state/<service>.yaml` says each stage runs. One prod
/// stage covers both prod regions. The file changes when a deploy starts, and
/// the ArgoCD sync finishes 3 to 60 minutes later (see ChartsDeployJobs).
public struct ServiceDeployState: Equatable, Sendable {
  /// The repository whose commits build the service's image.
  public var repository: String?
  /// The source commit of the image that each stage runs, or nil when the
  /// file doesn't say.
  public var devCommit: String?
  public var prodCommit: String?
  /// True when a person promotes the image to prod with promote-to-prod.yml,
  /// which starts no sync job.
  public var requiresProdApproval: Bool

  public static func parse(service: String, yaml: String) -> ServiceDeployState? {
    let scalars = YAMLScalars.read(yaml)
    let root = "state.\(service)."
    guard scalars.keys.contains(where: { $0.hasPrefix(root) }) else { return nil }
    func value(_ path: String) -> String? { scalars[root + path] }
    // image.<stage> and deploy_info.<stage> can disagree, because
    // promote-to-prod.yml and senders' value merges write an image alone. CI
    // writes image.sha and deploy_info.commit together for each build. A stage
    // that runs that build's digest runs its commit.
    let build = (image: value("image.sha"), commit: value("deploy_info.commit.sha").flatMap(fullCommit))
    func stageCommit(_ stage: String) -> String? {
      guard let image = value("image.\(stage)") else { return nil }
      if let commit = namedCommit(image) { return commit }
      guard let stageDigest = digest(image), let buildImage = build.image, stageDigest == digest(buildImage) else {
        return nil
      }
      return namedCommit(buildImage) ?? build.commit
    }
    return ServiceDeployState(
      repository: value("deploy_info.repository"), devCommit: stageCommit("dev"),
      prodCommit: stageCommit("prod"), requiresProdApproval: value("require_prod_approval")?.lowercased() == "true")
  }

  public func commit(for environment: DeployEnvironment) -> String? {
    environment == .dev ? devCommit : prodCommit
  }

  /// The commit that an image reference names, as `<sha>@sha256:<digest>`,
  /// `<sha>`, or `sha-<sha>`. A `sha256:<digest>` reference names none.
  private static func namedCommit(_ image: String) -> String? {
    image.firstMatch(of: #/^(?:sha-)?(?<sha>[0-9a-f]{40})(?:@|$)/#).map { String($0.sha) }
  }

  private static func digest(_ image: String) -> Substring? {
    image.firstMatch(of: #/sha256:[0-9a-f]{64}/#)?.output
  }

  private static func fullCommit(_ sha: String) -> String? {
    sha.wholeMatch(of: #/[0-9a-f]{40}/#) != nil ? sha : nil
  }
}

/// Whether a deployed commit includes a PR's merge commit, from the status
/// that GitHub's compare API returns for `compare/<deployed>...<merge>`. In
/// that order, a deployed commit that includes the merge returns about 10 KB.
/// The other order lists every file changed since the merge, about 1 MB.
public enum DeployedAncestry: Equatable, Sendable {
  case contains
  /// The merge commit is newer than the deployed commit.
  case notYet
  /// Neither commit includes the other. The PR merged into a branch that
  /// the service doesn't deploy from.
  case diverged

  /// The GitHub API path whose `status` this type reads. Swapping the two
  /// commits swaps `contains` and `notYet`.
  public static func comparePath(repository: String, deployed: String, merge: String) -> String {
    "repos/\(repository)/compare/\(deployed)...\(merge)"
  }

  public init?(compareStatus: String) {
    switch compareStatus {
    case "behind", "identical": self = .contains
    case "ahead": self = .notYet
    case "diverged": self = .diverged
    default: return nil
    }
  }
}

/// A PostHog/charts commit that starts a deploy, with the first line
/// "deploy <app> from <owner>/<repo>@<sha> by <user>". The state-deploy.yml
/// run on that commit deploys the app.
public struct ChartsDeployCommit: Equatable, Sendable {
  public var app: String
  public var repository: String
  public var commit: String

  public init(app: String, repository: String, commit: String) {
    self.app = app
    self.repository = repository
    self.commit = commit
  }

  public init?(message: String) {
    let firstLine = message.prefix { !$0.isNewline }
    guard
      let m = firstLine.wholeMatch(
        of: #/deploy (?<app>[a-z0-9][a-z0-9-]*) from (?<repo>[\w.-]+/[\w.-]+)@(?<sha>[0-9a-f]{40})(?: by .*)?/#)
    else { return nil }
    self.init(app: String(m.app), repository: String(m.repo), commit: String(m.sha))
  }
}

/// How far a PostHog/charts state-deploy.yml run got with one app in each
/// environment, from `GET /repos/PostHog/charts/actions/runs/<id>/jobs`.
public enum ChartsDeployJobs {
  public enum State: Equatable, Sendable {
    case waiting
    case running
    case succeeded
    case failed
    case cancelled
    case skipped
  }

  /// Each environment that has an ArgoCD sync job for `app`. A run that
  /// stopped before an environment's sync has no entry for it, and neither
  /// does prod for an app that needs prod approval. Dev also waits for the
  /// posthog app's deployment check. Later jobs, such as "Compute combined
  /// result", don't count, because a lost runner can fail them after the sync
  /// succeeded.
  public static func states(_ jobs: JSON, app: String) -> [DeployEnvironment: State] {
    let list = jobs["jobs"]?.array ?? []
    func job(_ prefix: String) -> State? {
      list.first { $0["name"]?.string?.hasPrefix(prefix) == true }.map(state)
    }
    let syncs: [DeployEnvironment: String] = [
      .dev: "Dev: Deploy with ArgoCD (\(app)) / Dev: ArgoCD Sync",
      .prodUS: "Prod: Deploy with ArgoCD (\(app)) / Prod US: ArgoCD Sync",
      .prodEU: "Prod: Deploy with ArgoCD (\(app)) / Prod EU: ArgoCD Sync",
    ]
    var states = syncs.compactMapValues(job)
    if states[.dev] == .succeeded, let check = job("Dev: Deploy with ArgoCD (\(app)) / Dev: Check Posthog Deployment") {
      switch check {
      case .succeeded, .skipped: break
      case .waiting, .running: states[.dev] = .running
      case .failed, .cancelled: states[.dev] = check
      }
    }
    return states
  }

  private static func state(_ job: JSON) -> State {
    switch (job["status"]?.string, job["conclusion"]?.string) {
    case ("completed", "success"): .succeeded
    case ("completed", "cancelled"): .cancelled
    case ("completed", "skipped"): .skipped
    case ("completed", _): .failed
    case ("in_progress", _): .running
    default: .waiting
    }
  }
}
