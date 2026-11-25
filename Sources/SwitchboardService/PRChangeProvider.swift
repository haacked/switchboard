import Foundation
import SwitchboardCore

/// Whether a source of PR changes can report changes.
enum Availability: Equatable, Sendable {
  case available
  /// The provider's reason, and when it tries again in ms.
  case unavailable(reason: String, retryAt: Int64?)
  case off
}

/// What a provider says about itself in `sb sources`.
struct ProviderStatus: Sendable {
  var availability: Availability
  /// The provider's own counts, such as its subscriptions and open streams, by name.
  var counts: [String: Int] = [:]
}

/// A source of PR changes, such as GitHub Event Streams or the webhook relay. A provider reports that PRs changed
/// and when its coverage of PRs starts or stops. It never reads a PR, and it never resolves a wait.
protocol PRChangeProvider: AnyObject {
  var id: String { get }
  /// The kinds of change that the provider reports.
  var signals: ChangeSignals { get }
  /// Starts the provider. It calls `sink` from any queue.
  func start(sink: PRChangeSink)
  /// The PRs that sbd wants signals for, most important first. The provider subscribes and unsubscribes to match. A
  /// provider that covers whole repos ignores the list or uses it as a filter.
  func setInterest(_ prs: [PRRef])
  func stop()
  var status: ProviderStatus { get }
}

/// Where a provider sends what it reports. Each method may be called from any queue.
protocol PRChangeSink: AnyObject {
  func signal(_ s: PRSignal)
  func coverage(_ change: CoverageChange)
  func availability(_ provider: String, _ a: Availability)
}

/// What the hub asks the GitHub poller to do. `GitHubPoller` conforms. Each method runs on the poller's queue.
protocol PRReader: AnyObject {
  func requestRead(_ ids: some Sequence<String>, after: Int64, trigger: ReadTrigger)
  func readAtNextPoll(_ ids: some Sequence<String>, trigger: ReadTrigger)
}
