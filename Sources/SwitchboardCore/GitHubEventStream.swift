import Foundation

/// The events of a GitHub Event Streams subscription on one PR.
public enum GitHubEventStream {
  /// The id of the source of PR changes that reads Event Streams.
  public static let provider = "github-events"

  /// Every event type that GitHub sends for a PR, sorted as GitHub lists them. sbd subscribes to all of them, so a
  /// PR has one subscription.
  public static let eventTypes = [
    "com.github.pull_request.check_suite.status.changed.v1",
    "com.github.pull_request.head.changed.v1",
    "com.github.pull_request.merge_conflict.v1",
    "com.github.pull_request.review.submitted.v1",
    "com.github.pull_request.state.changed.v1",
  ]

  /// The SSE event name of the last event of a stream.
  public static let endEvent = "github.stream.end"

  /// The check suite conclusions that report a failure.
  static let failedConclusions: Set<String> = [
    "failure", "timed_out", "cancelled", "action_required", "startup_failure",
  ]

  public enum Message: Equatable, Sendable {
    case signal(PRSignal)
    /// GitHub ended the stream. `reconnect` asks the client to open the same subscription again, and
    /// `subscription_ended` says the subscription is gone.
    case end(outcome: String, reason: String?)
    /// An event whose data isn't a JSON object.
    case ignored
  }

  /// Decodes one event of the stream of `pr`'s subscription. The event never says which PR it is about, so the
  /// signal's target is the subscription's PR. An unknown type still asks for a read.
  public static func decode(_ event: SSEEvent, pr: PRRef) -> Message {
    guard let json = JSON.parse(event.data), json.object != nil else { return .ignored }
    if event.event == endEvent {
      return .end(outcome: json["outcome"]?.string ?? "", reason: json["reason"]?.string)
    }
    let type = json["type"]?.string ?? event.event ?? ""
    let conclusion = json["data"]?["conclusion"]?.string
    let kind: PRSignal.Kind =
      switch type {
      case "com.github.pull_request.check_suite.status.changed.v1": .checks
      case "com.github.pull_request.review.submitted.v1": .review
      case "com.github.pull_request.state.changed.v1": .state
      case "com.github.pull_request.head.changed.v1": .head
      case "com.github.pull_request.merge_conflict.v1": .conflict
      default: .other
      }
    let id = json["id"]?.string ?? event.id ?? "\(type) \(json["time"]?.string ?? "")"
    return .signal(
      PRSignal(
        provider: provider, id: id, target: .pr(pr), kind: kind, at: json["time"]?.string.flatMap(milliseconds),
        failed: kind == .checks && conclusion.map(failedConclusions.contains) == true))
  }

  private static let whole = ISO8601DateFormatter()

  /// The time in ms of a timestamp such as 2026-11-24T22:52:19.563896417Z. GitHub sends nanoseconds, which
  /// `ISO8601DateFormatter` doesn't read, so the fraction is cut to ms.
  static func milliseconds(_ text: String) -> Int64? {
    guard let match = text.wholeMatch(of: #/(.+?)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)/#),
      let date = whole.date(from: "\(match.1)\(match.3)")
    else { return nil }
    let fraction = match.2.map { String($0.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) } ?? "0"
    return Int64(date.timeIntervalSince1970) * 1000 + (Int64(fraction) ?? 0)
  }
}
