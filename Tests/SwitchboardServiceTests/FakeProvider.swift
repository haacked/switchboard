import Foundation
import SwitchboardCore

@testable import SwitchboardService

/// A PR on github.com.
func prRef(_ number: Int, repo: String = "acme/widgets") -> PRRef {
  PRRef(forge: "github.com", repo: repo, number: number)
}

/// An in-memory source of PR changes. Its test sends signals, coverage changes, and availability through the sink
/// that `start(sink:)` gave it. It keeps each interest list that the hub gave it.
final class FakeProvider: PRChangeProvider {
  /// The kinds of change that GitHub Event Streams reports.
  static let eventStreams: ChangeSignals = [.head, .checkSuites, .checkRuns, .reviews, .state]

  let id: String
  let signals: ChangeSignals
  private(set) var sink: (any PRChangeSink)?
  private(set) var starts = 0
  /// How many times `recheck()` ran.
  private(set) var rechecks = 0
  /// Each interest list that the hub gave the provider, oldest first.
  private(set) var interests: [[PRRef]] = []
  var availability: Availability = .available
  var counts: [String: Int] = [:]
  private var sent = 0

  init(id: String = "fake", signals: ChangeSignals = FakeProvider.eventStreams) {
    self.id = id
    self.signals = signals
  }

  /// The last interest list that the hub gave the provider, or nil before the first one.
  var interest: [PRRef]? { interests.last }

  func start(sink: any PRChangeSink) {
    self.sink = sink
    starts += 1
  }

  func setInterest(_ prs: [PRRef]) { interests.append(prs) }

  func stop() {}

  func recheck() { rechecks += 1 }

  var status: ProviderStatus { ProviderStatus(availability: availability, counts: counts) }

  /// Sends a signal. Each signal gets a new event id unless `id` names one.
  func emit(
    _ target: PRSignal.Target, kind: PRSignal.Kind = .checks, id: String? = nil, failed: Bool = false,
    at: Int64? = nil
  ) {
    sent += 1
    sink?.signal(
      PRSignal(provider: self.id, id: id ?? "\(self.id)-\(sent)", target: target, kind: kind, at: at, failed: failed))
  }

  func emit(_ change: CoverageChange) { sink?.coverage(change) }

  /// Sets the availability that `status` shows and reports it through the sink.
  func report(_ a: Availability) {
    availability = a
    sink?.availability(id, a)
  }
}
