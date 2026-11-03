import Foundation

extension DeployComment {
  /// The login of the bot that writes the comment. Only a GitHub App's login
  /// ends in [bot], so no person can pass for it.
  public static let author = "deployment-status-posthog[bot]"
}

/// One environment's progress for a deploy wait that names a service.
public struct EnvironmentDeploy: Equatable, Sendable {
  public var state: DeployState
  /// The html_url of the PostHog/charts state-deploy.yml run, when the poller found it.
  public var run: String?

  public init(state: DeployState, run: String? = nil) {
    self.state = state
    self.run = run
  }
}

extension ServiceDeployState {
  /// Whether a charts sync job says when the service finished deploying to
  /// `environment`. A manual promotion to prod, for a service that requires
  /// prod approval, starts no sync job.
  public func needsSync(in environment: DeployEnvironment) -> Bool {
    environment == .dev || !requiresProdApproval
  }

  /// Whether the service builds from `repository`. A state file that names no
  /// repository builds from any.
  public func builds(from repository: String) -> Bool {
    self.repository.map { Wait.sameRepository($0, repository) } ?? true
  }
}

extension DeployState {
  /// The state of `service` in `environment`. An environment with no sync job
  /// counts as deployed once its commit contains the merge.
  public static func of(
    _ service: ServiceDeployState, in environment: DeployEnvironment, ancestry: DeployedAncestry,
    sync: ChartsDeployJobs.State?
  ) -> DeployState {
    if ancestry == .contains, !service.needsSync(in: environment) { return .deployed }
    return DeployState(ancestry: ancestry, sync: sync)
  }
}

extension Wait {
  public static let posthogRepository = "PostHog/posthog"
  public static let chartsRepository = "PostHog/charts"

  /// The environments that a deploy wait names.
  public var deployEnvironments: [DeployEnvironment] { DeployEnvironment.named(environment ?? "prod") ?? [] }

  /// What happened, when a deploy wait can resolve from the PR and its
  /// comments, or nil while it stays open. A merged PR of a wait that names a
  /// service returns nil, because `serviceDeployResolution` decides it.
  ///
  /// The deploy comment covers only the main posthog app. It decides a
  /// PostHog/posthog PR. Nothing that sbd reads shows a PostHog/charts PR or a
  /// PR in another repository deploy. Those resolve when they merge.
  public func deployResolution(of pr: SwitchboardCore.PullRequest, comments: [PRComment]) -> String? {
    switch pr.state {
    case .open: return nil
    case .closed: return "it closed without merging"
    case .merged: break
    }
    if service != nil { return nil }
    if Wait.sameRepository(pr.repo, Wait.posthogRepository) {
      let comment = comments.lazy.filter { $0.author == DeployComment.author }
        .compactMap { $0.body.flatMap(DeployComment.parse) }.last
      guard let comment, deployEnvironments.allSatisfy({ comment.state(in: $0) == .deployed }) else { return nil }
      return deployedOutcome
    }
    if Wait.sameRepository(pr.repo, Wait.chartsRepository) {
      return "it merged, and Switchboard can't read ArgoCD to see it deploy"
    }
    return "it merged, and Switchboard has no deploy signal for \(pr.repo)"
  }

  /// What happened, when a deploy wait that names a service can resolve, or
  /// nil while it stays open. `state` is the parsed state file, or nil when
  /// PostHog/charts has no state file for the service. `environments` holds
  /// each environment that the poller could decide. A missing entry keeps the
  /// wait open.
  public func serviceDeployResolution(
    _ state: ServiceDeployState?, pr: SwitchboardCore.PullRequest,
    environments: [DeployEnvironment: EnvironmentDeploy]
  ) -> String? {
    let name = service ?? ""
    guard let state else { return "\(Wait.chartsRepository) has no state/\(name).yaml" }
    if !state.builds(from: pr.repo), let repository = state.repository {
      return "\(name) deploys from \(repository), not \(pr.repo)"
    }
    let named = deployEnvironments
    if let failed = named.first(where: { environments[$0]?.state == .failed }) {
      return "the deploy to \(failed.rawValue) failed" + (environments[failed]?.run.map { ": \($0)" } ?? "")
    }
    if named.contains(where: { environments[$0]?.state == .offBranch }) {
      return "it merged into \(pr.base), which \(name) doesn't deploy from"
    }
    return named.allSatisfy({ environments[$0]?.state == .deployed }) ? deployedOutcome : nil
  }

  private var deployedOutcome: String {
    "it deployed to " + deployEnvironments.map(\.rawValue).joined(separator: " and ")
  }

  public static func sameRepository(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
}
